const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const scope_mod = @import("scope.zig");

// ============================================================
// Typed HIR (High-level Intermediate Representation)
//
// A typed, desugared representation after type checking.
// Every expression carries its resolved type.
// Dispatch is resolved to specific function groups.
// Match compilation converts patterns to decision trees.
// ============================================================

pub const TypeId = types_mod.TypeId;
pub const Ownership = types_mod.Ownership;

pub const ValueMode = enum {
    share,
    move,
    borrow,
};

// ============================================================
// HIR Program
// ============================================================

pub const Program = struct {
    structs: []const Struct,
    top_functions: []const FunctionGroup,
    protocols: []const ProtocolInfo = &.{},
    impls: []const ImplInfo = &.{},
};

pub const ProtocolInfo = struct {
    name: ast.StringId,
    type_params: []const ast.StringId = &.{},
    function_names: []const ast.StringId,
    function_arities: []const u32,
};

pub const ImplInfo = struct {
    protocol_name: ast.StringId,
    protocol_type_args: []const TypeId = &.{},
    target_struct: ast.StringId,
    target_type_pattern: TypeId = types_mod.TypeStore.UNKNOWN,
    impl_scope_id: scope_mod.ScopeId,
    function_group_ids: []const u32,
};

pub const Struct = struct {
    name: ast.StructName,
    scope_id: scope_mod.ScopeId,
    functions: []const FunctionGroup,
    types: []const TypeDef,
};

// ============================================================
// HIR Function Group (with fallback chain)
// ============================================================

pub const FunctionGroup = struct {
    id: u32,
    scope_id: scope_mod.ScopeId,
    name: ast.StringId,
    arity: u32,
    debug_span: ast.SourceSpan = .{ .start = 0, .end = 0 },
    is_local: bool = false,
    captures: []const Capture = &.{},
    clauses: []const Clause,
    fallback_parent: ?u32, // ID of the outer scope's function group
};

pub const Capture = struct {
    name: ast.StringId,
    type_id: TypeId,
    ownership: Ownership,
};

pub const Clause = struct {
    params: []const TypedParam,
    return_type: TypeId,
    debug_span: ast.SourceSpan = .{ .start = 0, .end = 0 },
    decision: *const Decision, // compiled match decision
    body: *const Block,
    refinement: ?*const Expr,
    tuple_bindings: []const TupleBinding,
    struct_bindings: []const StructBinding = &.{},
    list_bindings: []const ListBinding = &.{},
    cons_tail_bindings: []const ConsTailBinding = &.{},
    binary_bindings: []const BinaryBinding = &.{},
    map_bindings: []const MapBinding = &.{},
};

pub const TupleBinding = struct {
    name: ast.StringId,
    param_index: u32,
    element_index: u32,
    local_index: u32,
};

pub const StructBinding = struct {
    name: ast.StringId,
    param_index: u32,
    field_name: ast.StringId,
    local_index: u32,
    /// Struct nominal type that owns the field. Plumbed through so the
    /// IR builder can resolve the field's source-level type and storage
    /// strategy (`FieldStorage.indirect` for self-referential fields).
    struct_type: ast.StringId,
};

pub const MapBinding = struct {
    name: ast.StringId,
    param_index: u32,
    key_expr: *const Expr,
    local_index: u32,
};

pub const ListBinding = struct {
    name: ast.StringId,
    param_index: u32,
    element_index: u32,
    local_index: u32,
};

/// Binding for a cons pattern tail: [_ | tail] binds the remaining list.
pub const ConsTailBinding = struct {
    name: ast.StringId,
    param_index: u32,
    start_index: u32,
    local_index: u32,
};

pub const BinaryBinding = struct {
    name: ast.StringId,
    param_index: u32,
    segment_index: u32,
    local_index: u32,
    segment: BinaryMatchSegment,
};

pub const TypedParam = struct {
    name: ?ast.StringId,
    type_id: TypeId,
    ownership: Ownership = .shared,
    pattern: ?*const MatchPattern,
    default: ?*const Expr = null,
};

// ============================================================
// HIR Type definitions
// ============================================================

pub const TypeDef = struct {
    name: ast.StringId,
    type_id: TypeId,
    kind: TypeDefKind,
};

pub const TypeDefKind = enum {
    alias,
    opaque_type,
    struct_type,
};

// ============================================================
// HIR Expressions (typed)
// ============================================================

pub const Expr = struct {
    kind: ExprKind,
    type_id: TypeId,
    span: ast.SourceSpan,
    /// Macro-expansion provenance carried over from the AST node's
    /// `NodeMeta.expansion` (null for source-level nodes — the common
    /// case). Diagnostic-only: lowering uses it solely to attribute a
    /// macro-expanded node's DWARF line entry to the user's macro call
    /// site (Phase 2.f GP2) instead of the macro template body, so a
    /// crash-report frame inside expanded code points at user source.
    expansion: ?*const ast.ExpansionInfo = null,

    /// The span to attribute this expr to in user-facing debug output
    /// (DWARF line entries / backtraces). Resolves through any macro
    /// expansion to the outermost user call site; otherwise the expr's
    /// own span. Mirrors `ast.NodeMeta.debugSpan`.
    pub fn debugSpan(self: Expr) ast.SourceSpan {
        const info = self.expansion orelse return self.span;
        return info.outermostCallSite();
    }
};

pub const ExprKind = union(enum) {
    // Literals
    int_lit: i64,
    float_lit: f64,
    string_lit: ast.StringId,
    atom_lit: ast.StringId,
    bool_lit: bool,
    nil_lit,

    // References
    local_get: u32, // local variable index
    param_get: u32, // parameter index
    capture_get: u32,

    // Compound
    tuple_init: []const *const Expr,
    list_init: []const *const Expr,
    list_cons: ListConsHir,
    map_init: []const MapEntry,
    struct_init: StructInit,

    // Operations
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,
    field_get: FieldGetExpr,
    /// Tuple element extraction by zero-based positional index.
    tuple_index_get: TupleIndexGetExpr,
    /// List element extraction by zero-based positional index.
    list_index_get: ListIndexGetExpr,
    /// First element of a non-empty list (head).
    list_head_get: ListHeadGetExpr,
    /// All-but-first elements of a list (tail), preserving the list type.
    list_tail_get: ListTailGetExpr,
    /// Map value lookup by key expression.
    map_value_get: MapValueGetExpr,

    // Control flow
    branch: BranchExpr,
    match: MatchExpr,
    case: CaseData,
    block: Block,

    // Error handling
    panic: *const Expr,
    unwrap: *const Expr, // optional force-unwrap (expr!)
    /// Phase 3.b — a PROPAGATING `raise` in a function carrying the `raises`
    /// effect that is NOT lexically inside a `try` body. Lowers to: stash the
    /// boxed `Error` existential into the thread-local side-channel
    /// (`Kernel.recoverable_raise`), then `return error.ZapRaise` from the
    /// (error-union-returning) enclosing function. The `error.ZapRaise` tag
    /// is the cross-function control signal Zig propagates (building the
    /// error return trace); the boxed payload rides the side-channel and is
    /// recovered by the nearest dynamically-enclosing `try`/`rescue` (or, if
    /// none, surfaces at top level via the unhandled-error abort). Distinct
    /// from the Phase 3.a recoverable raise (`try_scope_depth > 0`), which
    /// only stashes and falls through to the SAME function's landing pad, and
    /// from the Phase 2 `do_raise` abort used by non-raising-row functions.
    ret_raise: RetRaiseHir,

    // Union
    union_init: UnionInitExpr,
    error_pipe: ErrorPipeHir,
    /// The realized `?` propagation operator (`value?`). Lowered to a
    /// comptime-safe `union_switch` over `value`'s `Result(T, E)`: the
    /// `Ok(v)` prong yields `v` to the expression's `dest`; the `Error(e)`
    /// prong re-wraps `Result(T, E).Error(e)` and `ret`-terminates,
    /// early-returning the enclosing function. `union_switch` is the
    /// realized form of the design's `TryProject` node — no separate IR op
    /// is needed. Surface Zap has no `return`, so this early-return arm
    /// cannot exist in surface/desugar AST and is synthesized here in HIR
    /// where a `ret` terminator is legal.
    try_project: TryProjectHir,

    /// The `try { body } rescue { pat -> … } after { … }` recoverable-error
    /// handler (Phase 3.a). Lowered in the IR builder by reusing the
    /// error-union/handler machinery: the `body` runs with a dynamic
    /// handler scope active, so a `raise` inside it (or in a callee whose
    /// raised error reaches here) is caught here instead of aborting. The
    /// `arms` are the rescue handler — a pattern-match (`case`) on the
    /// raised `Error` value. `after` is finally-semantics: it runs on every
    /// edge (normal completion, rescued, re-raise) via the `defer_stack`.
    try_rescue: TryRescueHir,

    // Special
    closure_create: ClosureCreate,
    never,
};

/// Phase 3.b — payload for a propagating `raise` (`ret_raise`). Carries the
/// pre-built `Kernel.recoverable_raise(<box>)` call (which stashes the boxed
/// `Error` existential into the thread-local side-channel) as a lowered HIR
/// expression. The IR lowers this to: evaluate the stash call, then a
/// `ret_raise` terminator that emits `return error.ZapRaise`.
pub const RetRaiseHir = struct {
    /// The lowered `Kernel.recoverable_raise(<box>)` call (the side-channel
    /// stash). Evaluated for its effect before the error-return.
    stash_call: *const Expr,
};

pub const TryRescueHir = struct {
    /// The `try` body, lowered as a block. Its `raise` sites are
    /// recoverable (they unwind to `arms`).
    body: *const Block,
    /// The rescue handler arms — a pattern-match on the raised `Error`
    /// value. Reuses `CaseArm` so struct-pattern / type-binding / wildcard
    /// rescue clauses lower identically to `case` arms.
    arms: []const CaseArm,
    /// Local that holds the raised `Error` value the arms match against.
    /// The IR lowering binds the result of `take_raise_call` to this local
    /// in the handler branch before dispatching to `arms`.
    error_local: u32,
    /// Pre-built `Kernel.raise_occurred()` call (lowered HIR). The IR tests
    /// this after the body to choose the handler branch vs the body value.
    raise_occurred_call: *const Expr,
    /// Pre-built `Kernel.take_recoverable_raise()` call (lowered HIR). The
    /// IR binds its result to `error_local` at the head of the handler
    /// branch (reads + clears the runtime raise side-channel).
    take_raise_call: *const Expr,
    /// The optional `after` cleanup block (finally-semantics).
    after_block: ?*const Block,
    /// The joined result type of the whole `try`/`rescue` expression — the
    /// peer type of the body's success value and every rescue arm's result
    /// (computed by `buildTryRescue` the same way the type checker's
    /// `.try_rescue` arm does). The IR lowering uses this to coerce the
    /// normal-completion (else) branch of the landing-pad `if` so it shares
    /// the rescue arms' Sema peer type even when the body unconditionally
    /// raises (its tail value is then a `Never`-stamped recoverable raise,
    /// which would otherwise type as `void` and clash with the arms).
    result_type_id: types_mod.TypeId,
    /// Per-arm runtime type discriminator (Phase 3.a, #185). One entry per
    /// `arms` clause, in source order, so the IR's `lowerRescueDispatch`
    /// knows which concrete error type each arm matches against the raised
    /// `Error` box. Without this the arms lower as a plain `case` whose
    /// type-binding patterns are wildcard-equivalent — the bug where
    /// multi-clause `rescue` always takes the first arm regardless of the
    /// boxed error's real runtime type. The final arm is always a catch-all
    /// (`buildTryRescue` synthesizes a re-raise catch-all when the user
    /// omitted one) so the dispatch is total: an unmatched type re-raises
    /// rather than being silently swallowed.
    arm_discriminators: []const RescueDiscriminator,
};

/// How a single `rescue` arm matches the raised `Error` box at runtime
/// (Phase 3.a, #185). Computed by `buildTryRescue` from the clause's
/// pattern + optional `:: Type` annotation; consumed by the IR's
/// `lowerRescueDispatch` to decide whether to gate the arm behind a
/// `protocol_box_vtable_eq` runtime type test.
pub const RescueDiscriminator = union(enum) {
    /// `_`, a bare binding `e`, or `e :: <Protocol>` (the protocol the box
    /// already carries) — matches any boxed error without a runtime test.
    /// The bound variable, if any, stays the boxed `Error` existential.
    catch_all,
    /// `e :: ConcreteError` or `%ConcreteError{...}` — matches only when the
    /// box's runtime concrete type is `target_type_name`. `needs_unbox` is
    /// true for a struct-pattern clause (its fields must be read off the
    /// downcast concrete value via `protocol_box_unbox`); a pure
    /// type-binding clause keeps the binding as the box (no unbox), so a
    /// `raise e` / `Error.method(e)` in the body still sees an `Error`.
    concrete: struct {
        target_type_name: []const u8,
        needs_unbox: bool,
    },
};

pub const UnionInitExpr = struct {
    union_type_id: types_mod.TypeId,
    variant_name: ast.StringId,
    value: *const Expr,
};

/// Payload for `ExprKind.try_project` — the realized `?` operator.
pub const TryProjectHir = struct {
    /// The `Result(T, E)`-typed operand the `?` is applied to. Its
    /// `type_id` is the concrete `Result` type (a `.tagged_union` or an
    /// `.applied` instantiation of one).
    operand: *const Expr,
    /// The concrete `Result(T, E)` union type id (canonicalized to the
    /// `.tagged_union`/`.applied` form) used to emit the `union_init`
    /// `Error` re-wrap on the early-return arm.
    result_type_id: types_mod.TypeId,
    /// Interned name of the `Ok` variant (the prong that yields the
    /// unwrapped value).
    ok_variant_name: ast.StringId,
    /// Interned name of the `Error` variant (the prong that early-returns).
    error_variant_name: ast.StringId,
};

pub const ErrorPipeHir = struct {
    /// The chain steps: first is the base call, rest are pipe steps.
    /// Each step except the first takes the previous step's Ok value as first arg.
    steps: []const ErrorPipeStep,
    /// The error handler — called when a pipe step can't match its input.
    /// References `err_local` for the failing input value.
    handler: *const Expr,
    /// Local index that the IR will populate with the failing pipe value
    /// before lowering `handler`. The HIR builder allocates this so that
    /// `__err` references inside the handler resolve to the same local.
    /// `null` indicates no `__err` allocation (function-style handler), in
    /// which case the failing value is passed to the handler function as
    /// its first call argument by the IR-level lowering.
    err_local: ?u32 = null,
};

pub const ErrorPipeStep = struct {
    /// The HIR expression for this step. For step 0, it's the base call.
    /// For step N > 0, it's a call expression where the first arg should be
    /// substituted with the previous step's result piped as first arg.
    expr: *const Expr,
    /// Whether this step calls a multi-clause function (has __try variant).
    /// When true, the ~> catch basin can intercept unmatched values.
    is_dispatched: bool = false,
};

pub const BinaryExpr = struct {
    op: ast.BinaryOp.Op,
    lhs: *const Expr,
    rhs: *const Expr,
};

pub const UnaryExpr = struct {
    op: ast.UnaryOp.Op,
    operand: *const Expr,
};

pub const CallExpr = struct {
    target: CallTarget,
    args: []const CallArg,
};

pub const CallArg = struct {
    expr: *const Expr,
    mode: ValueMode = .share,
    expected_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN,
};

pub const NamedCall = struct {
    struct_name: ?[]const u8,
    name: []const u8,
    clause_index: ?u32 = null,
};

pub const CallTarget = union(enum) {
    direct: DirectCall,
    named: NamedCall,
    closure: *const Expr,
    dispatch: DispatchCall,
    builtin: []const u8,
};

pub const DirectCall = struct {
    function_group_id: u32,
    clause_index: ?u32 = null,
};

pub const DispatchCall = struct {
    function_group_id: u32,
};

pub const FieldGetExpr = struct {
    object: *const Expr,
    field: ast.StringId,
};

pub const TupleIndexGetExpr = struct {
    object: *const Expr,
    index: u32,
};

pub const ListIndexGetExpr = struct {
    list: *const Expr,
    index: u32,
};

pub const ListHeadGetExpr = struct {
    list: *const Expr,
};

pub const ListTailGetExpr = struct {
    list: *const Expr,
    start_index: u32 = 1,
};

pub const MapValueGetExpr = struct {
    map: *const Expr,
    key: *const Expr,
};

pub const BranchExpr = struct {
    condition: *const Expr,
    then_block: *const Block,
    else_block: ?*const Block,
};

pub const MatchExpr = struct {
    scrutinee: *const Expr,
    decision: *const Decision,
};

pub const CaseData = struct {
    scrutinee: *const Expr,
    arms: []const CaseArm,
};

pub const CaseArm = struct {
    pattern: ?*const MatchPattern,
    guard: ?*const Expr,
    body: *const Block,
    bindings: []const CaseBinding,
};

pub const CaseBinding = struct {
    name: ast.StringId,
    local_index: u32,
    kind: CaseBindKind,
    element_index: u32, // only used for binary_element
};

pub const CaseBindKind = enum {
    scrutinee, // bind the whole scrutinee value (top-level `name -> body`)
    extracted, // bind extracted by a decision tree .bind node (tuple/list/struct/map/list_cons element)
    binary_element, // bind a segment extracted from binary data
};

pub const AssignmentBinding = struct {
    name: ast.StringId,
    local_index: u32,
    type_id: types_mod.TypeId = types_mod.TypeStore.UNKNOWN,
};

pub const ListConsHir = struct {
    head: *const Expr,
    tail: *const Expr,
};

pub const MapEntry = struct {
    key: *const Expr,
    value: *const Expr,
};

pub const StructInit = struct {
    type_id: TypeId,
    fields: []const StructFieldInit,
};

pub const StructFieldInit = struct {
    name: ast.StringId,
    value: *const Expr,
};

pub const ClosureCreate = struct {
    function_group_id: u32,
    captures: []const CaptureValue,
};

pub const CaptureValue = struct {
    expr: *const Expr,
    ownership: Ownership,
};

// ============================================================
// HIR Block
// ============================================================

pub const Block = struct {
    stmts: []const Stmt,
    result_type: TypeId,
};

pub const Stmt = union(enum) {
    expr: *const Expr,
    local_set: LocalSet,
    function_group: *const FunctionGroup,
    /// `defer <expr>` / `errdefer <expr>` (Phase 2.d). Recorded in
    /// statement order; the IR builder pushes it onto the enclosing
    /// block's LIFO cleanup stack rather than emitting it inline, and
    /// re-lowers it at each scope-exit edge.
    defer_stmt: DeferStmt,
};

/// HIR form of a `defer`/`errdefer` statement (Phase 2.d). Carries the
/// lowered cleanup expression and which value-return paths it runs on.
pub const DeferStmt = struct {
    kind: ast.DeferKind,
    expr: *const Expr,
};

pub const LocalSet = struct {
    index: u32,
    value: *const Expr,
    /// Zap source identifier of the binding, when the assignment is
    /// `name = expr` (the `.bind` pattern). Null for destructured
    /// bindings (`{a,b} = pair`, `[h|t] = lst`, …) whose intermediate
    /// `local_set`s hold synthetic extractor values that have no
    /// user-visible name. Read by the IR builder to emit a
    /// `.dbg_var` IR instruction so DWARF records the Zap identifier
    /// for this slot.
    name: ?ast.StringId = null,
};

// ============================================================
// Match compilation — Decision trees (spec §17)
//
// Patterns compile to a decision tree of tests and branches.
// Each leaf is either a success (with bindings) or a failure
// that triggers the next fallback.
// ============================================================

pub const Decision = union(enum) {
    /// Pattern match succeeded — execute body with bindings
    success: SuccessLeaf,
    /// Pattern match failed — try fallback
    failure,
    /// Test a value and branch
    guard: GuardNode,
    /// Switch on tag/literal
    switch_tag: SwitchNode,
    /// Switch on literal value
    switch_literal: SwitchLiteralNode,
    /// Check tuple arity
    check_tuple: CheckTupleNode,
    /// Check list length
    check_list: CheckListNode,
    /// Check list cons (non-empty list with head/tail extraction)
    check_list_cons: CheckListConsNode,
    /// Check binary data (length + segment extraction)
    check_binary: CheckBinaryNode,
    /// Bind a variable and continue
    bind: BindNode,
    /// Extract named struct fields and continue. Statically-typed structs
    /// always match the layout (the type checker rejected anything else),
    /// so no runtime tag check is needed; this just plumbs each requested
    /// field into the success subtree as a fresh scrutinee.
    extract_struct: ExtractStructNode,
    /// Extract map values for named keys and continue. Each key is verified
    /// to exist; missing keys route to `failure`.
    extract_map: ExtractMapNode,
    /// Switch on a tagged-union variant's active tag, optionally
    /// extracting the variant's payload into a fresh scrutinee for
    /// the matched case's sub-decision tree.
    switch_variant: SwitchVariantNode,
};

pub const SuccessLeaf = struct {
    bindings: []const Binding,
    body_index: u32,
};

pub const Binding = struct {
    name: ast.StringId,
    local_index: u32,
};

pub const GuardNode = struct {
    condition: *const Expr,
    success: *const Decision,
    failure: *const Decision,
};

pub const SwitchNode = struct {
    scrutinee: *const Expr,
    cases: []const SwitchCase,
    default: *const Decision,
};

pub const SwitchCase = struct {
    tag: ast.StringId,
    bindings: []const Binding,
    next: *const Decision,
};

pub const SwitchLiteralNode = struct {
    scrutinee: *const Expr,
    cases: []const LiteralCase,
    default: *const Decision,
};

/// Decision-tree node for a tagged-union variant switch. The IR
/// layer reads `scrutinee` to recover the runtime tagged-union
/// value, emits `std.meta.activeTag(scrutinee) == .VariantName`
/// comparisons per case, and (when `has_payload` is true on the
/// matched case) extracts the payload via `scrutinee.VariantName`
/// and binds it to `payload_scrutinee_id` for the case's
/// sub-decision tree.
pub const SwitchVariantNode = struct {
    scrutinee: *const Expr,
    /// Receiver type's declaration name (`Option`, `Result`). The
    /// per-instantiation mangled name is recovered downstream from
    /// the scrutinee's HIR type — `receiver_name` is purely a
    /// diagnostic aid.
    receiver_name: ast.StringId,
    cases: []const SwitchVariantCase,
    default: *const Decision,
};

pub const SwitchVariantCase = struct {
    variant_name: ast.StringId,
    has_payload: bool,
    /// Fresh scrutinee id allocated by the pattern-matrix compiler
    /// for the payload sub-tree to reference. Meaningful only when
    /// `has_payload` is true.
    payload_scrutinee_id: u32,
    next: *const Decision,
};

pub const LiteralCase = struct {
    value: LiteralValue,
    next: *const Decision,
};

pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    string: ast.StringId,
    atom: ast.StringId,
    bool_val: bool,
    nil,
};

pub const ExtractStructNode = struct {
    scrutinee: *const Expr,
    fields: []const StructFieldExtraction,
    success: *const Decision,
    failure: *const Decision,
};

pub const StructFieldExtraction = struct {
    field_name: ast.StringId,
    scrutinee_id: u32,
};

pub const ExtractMapNode = struct {
    scrutinee: *const Expr,
    keys: []const MapKeyExtraction,
    success: *const Decision,
    failure: *const Decision,
};

pub const MapKeyExtraction = struct {
    /// Key expression (literal or computed) evaluated at runtime.
    key: *const Expr,
    /// Scrutinee ID assigned to the looked-up value.
    scrutinee_id: u32,
};

pub const CheckTupleNode = struct {
    scrutinee: *const Expr,
    expected_arity: u32,
    /// Scrutinee IDs assigned to each tuple element by the pattern compiler.
    /// element_scrutinee_ids[i] is the ID for element i, used to populate
    /// the scrutinee_map in IR lowering. This avoids the fragile heuristic
    /// of walking the decision tree to discover IDs (which breaks with wildcards).
    element_scrutinee_ids: []const u32,
    success: *const Decision,
    failure: *const Decision,
};

pub const CheckListNode = struct {
    scrutinee: *const Expr,
    expected_length: u32,
    /// Scrutinee IDs assigned to each list element by the pattern compiler.
    /// `element_scrutinee_ids[i]` is the ID for element i, used to populate
    /// the scrutinee_map in IR lowering. Stored explicitly because the
    /// fragile `findParamGetIdInDecision` heuristic cannot distinguish list
    /// elements from inner tuple/tag-extracted elements when patterns
    /// decompose multiple list slots (e.g. `[{a, b}, {c, d}]`).
    element_scrutinee_ids: []const u32,
    success: *const Decision,
    failure: *const Decision,
};

pub const CheckListConsNode = struct {
    scrutinee: *const Expr,
    /// Number of head elements extracted (typically 1 for [h | t])
    head_count: u32,
    /// Scrutinee IDs for extracted heads and tail
    head_scrutinee_ids: []const u32,
    tail_scrutinee_id: u32,
    success: *const Decision,
    failure: *const Decision,
};

pub const CheckBinaryNode = struct {
    scrutinee: *const Expr,
    min_byte_size: u32,
    segments: []const BinaryMatchSegment,
    success: *const Decision,
    failure: *const Decision,
};

pub const BindNode = struct {
    name: ast.StringId,
    local_index: u32,
    source: *const Expr,
    next: *const Decision,
};

// ============================================================
// Match pattern (intermediate representation)
// ============================================================

pub const MatchPattern = union(enum) {
    wildcard,
    bind: ast.StringId,
    literal: LiteralValue,
    tuple: []const *const MatchPattern,
    list: []const *const MatchPattern,
    list_cons: ListConsMatch,
    pin: ast.StringId,
    struct_match: StructMatch,
    map_match: MapMatch,
    binary_match: BinaryMatchData,
    tagged_variant_match: TaggedVariantMatch,
};

/// HIR-level match-pattern for a tagged-union variant arm.
///
/// `receiver_name` is the receiver's declaration name (`Option`,
/// `Result`); `variant_name` is the variant tag (`Some`, `None`,
/// `Ok`, `Err`). For variants that carry a payload the inner
/// `payload` pattern is the destructuring shape — typically a
/// `bind` for a fresh local, `wildcard` for `_`, or any other
/// nested compound pattern. Nullary variants leave `payload` as
/// `null`. The IR layer translates this into an active-tag check
/// followed by payload extraction via `scrutinee.VariantName`,
/// matching the runtime layout produced by `union_init`.
pub const TaggedVariantMatch = struct {
    receiver_name: ast.StringId,
    variant_name: ast.StringId,
    payload: ?*const MatchPattern,
};

pub const BinaryMatchData = struct {
    segments: []const BinaryMatchSegment,
};

pub const BinaryMatchSegment = struct {
    pattern: ?*const MatchPattern,
    type_spec: ast.BinarySegmentType,
    endianness: ast.Endianness,
    size: ?ast.BinarySegmentSize,
    string_literal: ?ast.StringId,
};

pub const ListConsMatch = struct {
    heads: []const *const MatchPattern,
    tail: *const MatchPattern,
};

pub const StructMatch = struct {
    type_name: ast.StringId,
    field_bindings: []const StructFieldBind,
};

pub const StructFieldBind = struct {
    field_name: ast.StringId,
    pattern: *const MatchPattern,
};

pub const MapMatch = struct {
    field_bindings: []const MapFieldBind,
};

pub const MapFieldBind = struct {
    key: *const ast.Expr,
    pattern: *const MatchPattern,
};

pub const PatternRow = struct {
    patterns: []const ?*const MatchPattern,
    body_index: u32,
    guard: ?*const Expr,
};

pub const PatternMatrix = struct {
    rows: []const PatternRow,
    column_count: u32,
};

// ============================================================
// Pattern matrix compilation — Wadler algorithm
//
// Compiles a matrix of patterns into a Decision tree.
// ============================================================

/// Maps bind names to their scrutinee IDs for variable unification (pin patterns).
pub const BoundScrutinees = std.AutoHashMap(ast.StringId, u32);

pub fn compilePatternMatrix(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
) anyerror!*const Decision {
    var empty_bound: BoundScrutinees = BoundScrutinees.init(allocator);
    return compilePatternMatrixWithBindings(allocator, matrix, scrutinee_ids, next_id, &empty_bound);
}

fn compilePatternMatrixWithBindings(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Base case: no rows → failure
    if (matrix.rows.len == 0) {
        const d = try allocator.create(Decision);
        d.* = .failure;
        return d;
    }

    // Base case: no columns → first row's body (success)
    if (matrix.column_count == 0) {
        const row = matrix.rows[0];
        const d = try allocator.create(Decision);
        if (row.guard) |guard_expr| {
            // Recurse for remaining rows on guard failure
            const success = try allocator.create(Decision);
            success.* = .{ .success = .{ .bindings = &.{}, .body_index = row.body_index } };
            const remaining_rows = try allocator.alloc(PatternRow, matrix.rows.len - 1);
            @memcpy(remaining_rows, matrix.rows[1..]);
            const failure = try compilePatternMatrix(allocator, .{
                .rows = remaining_rows,
                .column_count = 0,
            }, scrutinee_ids, next_id);
            d.* = .{ .guard = .{
                .condition = guard_expr,
                .success = success,
                .failure = failure,
            } };
        } else {
            d.* = .{ .success = .{ .bindings = &.{}, .body_index = row.body_index } };
        }
        return d;
    }

    // Classify column 0
    const col0_class = classifyColumn(matrix);

    switch (col0_class) {
        .all_wildcard => {
            // Variable Rule: strip column 0, recurse.
            // Record any bind in column 0 so pins in later columns can reference it.
            if (matrix.rows.len > 0 and matrix.rows[0].patterns.len > 0) {
                const pat = matrix.rows[0].patterns[0];
                if (pat != null and pat.?.* == .bind and scrutinee_ids.len > 0) {
                    bound_scrutinees.put(pat.?.bind, scrutinee_ids[0]) catch {};
                }
            }
            return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
        },
        .all_constructor, .mixture => {
            return compileConstructorColumn(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
        },
    }
}

const ColumnClass = enum { all_wildcard, all_constructor, mixture };

fn classifyColumn(matrix: PatternMatrix) ColumnClass {
    var has_constructor = false;
    var has_wildcard = false;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) {
            has_wildcard = true;
            continue;
        }
        const pat = row.patterns[0];
        if (pat == null) {
            has_wildcard = true;
        } else {
            switch (pat.?.*) {
                .wildcard, .bind => has_wildcard = true,
                // Pin (variable unification) acts as a constructor — it
                // constrains which values match via an equality guard.
                .pin => has_constructor = true,
                else => has_constructor = true,
            }
        }
    }
    if (has_constructor and has_wildcard) return .mixture;
    if (has_constructor) return .all_constructor;
    return .all_wildcard;
}

fn isWildcardPattern(pat: ?*const MatchPattern) bool {
    if (pat == null) return true;
    return switch (pat.?.*) {
        .wildcard, .bind => true,
        else => false,
    };
}

fn stripColumnAndRecurse(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect bindings from column 0 for first matching row
    // Then strip column 0 and recurse
    var new_rows = try allocator.alloc(PatternRow, matrix.rows.len);
    for (matrix.rows, 0..) |row, i| {
        const new_pats = if (row.patterns.len > 1)
            row.patterns[1..]
        else
            @as([]const ?*const MatchPattern, &.{});
        new_rows[i] = .{
            .patterns = new_pats,
            .body_index = row.body_index,
            .guard = row.guard,
        };
    }

    const new_scrutinees = if (scrutinee_ids.len > 1)
        scrutinee_ids[1..]
    else
        @as([]const u32, &.{});

    // Check if column 0 first row has a bind pattern that needs to be recorded
    const first_pat = if (matrix.rows[0].patterns.len > 0) matrix.rows[0].patterns[0] else null;
    const sub_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = new_rows,
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    if (first_pat != null and first_pat.?.* == .bind) {
        // Emit a bind node
        const scrutinee_expr = try allocator.create(Expr);
        scrutinee_expr.* = .{
            .kind = .{ .param_get = scrutinee_ids[0] },
            .type_id = types_mod.TypeStore.UNKNOWN,
            .span = .{ .start = 0, .end = 0 },
        };
        const d = try allocator.create(Decision);
        d.* = .{
            .bind = .{
                .name = first_pat.?.bind,
                .local_index = 0, // resolved during IR lowering
                .source = scrutinee_expr,
                .next = sub_decision,
            },
        };
        return d;
    }

    return sub_decision;
}

fn compileConstructorColumn(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct constructors
    const scrutinee_id = scrutinee_ids[0];

    // Determine constructor type from first non-wildcard pattern
    var first_constructor: ?*const MatchPattern = null;
    for (matrix.rows) |row| {
        if (row.patterns.len > 0 and !isWildcardPattern(row.patterns[0])) {
            first_constructor = row.patterns[0].?;
            break;
        }
    }

    if (first_constructor == null) {
        // All wildcards - use variable rule
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    const scrutinee_expr = try allocator.create(Expr);
    scrutinee_expr.* = .{
        .kind = .{ .param_get = scrutinee_id },
        .type_id = types_mod.TypeStore.UNKNOWN,
        .span = .{ .start = 0, .end = 0 },
    };

    // Check if any row has a list_cons pattern — if so, prefer compileListConsCheck
    // because it handles both cons and empty patterns correctly.
    var has_list_cons = false;
    for (matrix.rows) |row| {
        if (row.patterns.len > 0 and !isWildcardPattern(row.patterns[0])) {
            if (row.patterns[0].?.* == .list_cons) {
                has_list_cons = true;
                break;
            }
        }
    }

    if (has_list_cons) {
        return compileListConsCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
    }

    switch (first_constructor.?.*) {
        .literal => |lit| {
            switch (lit) {
                .atom => {
                    // Atom literals -> switch_tag
                    return compileAtomSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
                },
                else => {
                    // Int/float/string/bool/nil literals -> switch_literal
                    return compileLiteralSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
                },
            }
        },
        .tuple => {
            // Tuple constructors -> check_tuple
            return compileTupleCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .list => {
            // List constructors -> check_list (same structure as check_tuple but for slices)
            return compileListCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .list_cons => {
            // List cons patterns -> check_list_cons (non-empty check + head/tail extraction)
            return compileListConsCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .binary_match => {
            // Binary constructors -> check_binary
            return compileBinaryCheck(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .pin => {
            // Pin (variable unification) -> guard with equality check
            return compilePinGuard(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .struct_match => {
            return compileStructFields(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .map_match => {
            return compileMapFields(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        .tagged_variant_match => {
            return compileTaggedVariantSwitch(allocator, matrix, scrutinee_ids, scrutinee_expr, next_id, bound_scrutinees);
        },
        else => {
            // Fallback: treat as variable rule
            return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
        },
    }
}

/// Compile a column where the first pattern is `tagged_variant_match`.
///
/// Strategy:
///   1. Collect the distinct variant names across rows.
///   2. For each variant, build a sub-matrix containing only the
///      rows that match (or wildcard) that variant. The first
///      column of each row is rewritten: the variant pattern's
///      payload (or wildcard if the variant had no payload pattern)
///      replaces it, so the recursive call sees the payload's shape.
///      A fresh scrutinee id is allocated for the payload extraction.
///   3. Build a default sub-matrix containing only the wildcard rows
///      (for the no-match-any-variant fallthrough; statically
///      exhaustive matches make this unreachable).
///   4. Emit a `Decision.switch_variant` with one case per variant
///      tag plus a `default` decision tree.
///
/// The resulting decision tree is consumed by IR's
/// `lowerDecisionTreeForCase`, which emits `activeTag` checks and
/// `scrutinee.VariantName` payload extraction.
fn compileTaggedVariantSwitch(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct variant names from rows that match the
    // tagged-variant constructor. Wildcard rows fan out across every
    // variant slot, exactly like .struct_match's union-of-fields
    // collection.
    var variant_names: std.ArrayList(ast.StringId) = .empty;
    var has_payload_per_variant: std.ArrayList(bool) = .empty;
    var receiver_name: ?ast.StringId = null;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .tagged_variant_match) continue;
        const tvm = pat.?.tagged_variant_match;
        if (receiver_name == null) receiver_name = tvm.receiver_name;
        var found_index: ?usize = null;
        for (variant_names.items, 0..) |existing, i| {
            if (existing == tvm.variant_name) {
                found_index = i;
                break;
            }
        }
        if (found_index == null) {
            try variant_names.append(allocator, tvm.variant_name);
            try has_payload_per_variant.append(allocator, tvm.payload != null);
        } else if (tvm.payload != null) {
            has_payload_per_variant.items[found_index.?] = true;
        }
    }

    if (variant_names.items.len == 0) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Pre-allocate one fresh payload scrutinee id per variant so
    // multiple rows for the same variant share it.
    var variant_payload_ids: std.ArrayList(u32) = .empty;
    for (variant_names.items, 0..) |_, i| {
        if (has_payload_per_variant.items[i]) {
            const sid = next_id.*;
            next_id.* += 1;
            try variant_payload_ids.append(allocator, sid);
        } else {
            try variant_payload_ids.append(allocator, std.math.maxInt(u32));
        }
    }

    // Build the per-variant sub-matrices. Each variant's sub-matrix
    // contains: the payload pattern (if any) prepended to the rest
    // of the row's columns. Wildcard rows broadcast to every
    // variant — their payload column becomes wildcard.
    var case_decisions: std.ArrayList(SwitchVariantCase) = .empty;
    for (variant_names.items, 0..) |variant_name, vi| {
        const has_payload = has_payload_per_variant.items[vi];
        const payload_sid = variant_payload_ids.items[vi];

        var sub_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const head = row.patterns[0];
            const tail = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            if (isWildcardPattern(head)) {
                // Wildcard rows match every variant; expand to a
                // wildcard payload (if the variant carries one) plus
                // the tail unchanged.
                var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
                if (has_payload) try new_pats.append(allocator, null);
                try new_pats.appendSlice(allocator, tail);
                try sub_rows.append(allocator, .{
                    .patterns = try new_pats.toOwnedSlice(allocator),
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
                continue;
            }
            if (head.?.* != .tagged_variant_match) continue;
            const tvm = head.?.tagged_variant_match;
            if (tvm.variant_name != variant_name) continue;
            var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
            if (has_payload) {
                try new_pats.append(allocator, tvm.payload);
            }
            try new_pats.appendSlice(allocator, tail);
            try sub_rows.append(allocator, .{
                .patterns = try new_pats.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }

        var sub_scrutinees: std.ArrayList(u32) = .empty;
        if (has_payload) try sub_scrutinees.append(allocator, payload_sid);
        try sub_scrutinees.appendSlice(allocator, remaining_scrutinees);

        const sub_column_count: u32 = @intCast((if (has_payload) @as(u32, 1) else @as(u32, 0)) + @as(u32, @intCast(remaining_scrutinees.len)));

        const sub_decision = try compilePatternMatrixWithBindings(
            allocator,
            .{
                .rows = try sub_rows.toOwnedSlice(allocator),
                .column_count = sub_column_count,
            },
            try sub_scrutinees.toOwnedSlice(allocator),
            next_id,
            bound_scrutinees,
        );
        try case_decisions.append(allocator, .{
            .variant_name = variant_name,
            .has_payload = has_payload,
            .payload_scrutinee_id = if (has_payload) payload_sid else 0,
            .next = sub_decision,
        });
    }

    // Default: only the wildcard rows survive (no variant constructor).
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        if (!isWildcardPattern(row.patterns[0])) continue;
        const tail = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        try default_rows.append(allocator, .{
            .patterns = tail,
            .body_index = row.body_index,
            .guard = row.guard,
        });
    }
    const default_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try default_rows.toOwnedSlice(allocator),
            .column_count = @intCast(remaining_scrutinees.len),
        },
        remaining_scrutinees,
        next_id,
        bound_scrutinees,
    );

    const d = try allocator.create(Decision);
    d.* = .{
        .switch_variant = .{
            .scrutinee = scrutinee_expr,
            .receiver_name = receiver_name.?,
            .cases = try case_decisions.toOwnedSlice(allocator),
            .default = default_decision,
        },
    };
    return d;
}

/// Compile a column where the first pattern is `struct_match`. Collects the
/// union of all field names referenced across rows, extracts each field into
/// a fresh scrutinee, and rewrites each row with one column per extracted
/// field — falling through to the generic matrix compiler so nested patterns
/// (literals, sub-binds, nested compounds) keep being handled correctly.
fn compileStructFields(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    var field_names: std.ArrayList(ast.StringId) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .struct_match) continue;
        for (pat.?.struct_match.field_bindings) |fb| {
            var found = false;
            for (field_names.items) |existing| {
                if (existing == fb.field_name) {
                    found = true;
                    break;
                }
            }
            if (!found) try field_names.append(allocator, fb.field_name);
        }
    }

    if (field_names.items.len == 0) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    var extractions: std.ArrayList(StructFieldExtraction) = .empty;
    var field_scrutinee_ids: std.ArrayList(u32) = .empty;
    for (field_names.items) |fname| {
        const sid = next_id.*;
        next_id.* += 1;
        try extractions.append(allocator, .{ .field_name = fname, .scrutinee_id = sid });
        try field_scrutinee_ids.append(allocator, sid);
    }

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    var combined_ids: std.ArrayList(u32) = .empty;
    try combined_ids.appendSlice(allocator, field_scrutinee_ids.items);
    try combined_ids.appendSlice(allocator, remaining_scrutinees);

    var success_rows: std.ArrayList(PatternRow) = .empty;
    var failure_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const head = row.patterns[0];
        const tail = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        if (isWildcardPattern(head)) {
            // Wildcard matches every constructor — broadcast to wildcards
            // for each extracted field.
            var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
            for (field_names.items) |_| {
                try new_pats.append(allocator, null);
            }
            try new_pats.appendSlice(allocator, tail);
            try success_rows.append(allocator, .{
                .patterns = try new_pats.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
            try failure_rows.append(allocator, .{
                .patterns = tail,
                .body_index = row.body_index,
                .guard = row.guard,
            });
            continue;
        }
        if (head.?.* != .struct_match) continue;
        const sm = head.?.struct_match;
        var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
        for (field_names.items) |fname| {
            var matched: ?*const MatchPattern = null;
            for (sm.field_bindings) |fb| {
                if (fb.field_name == fname) {
                    matched = fb.pattern;
                    break;
                }
            }
            try new_pats.append(allocator, matched);
        }
        try new_pats.appendSlice(allocator, tail);
        try success_rows.append(allocator, .{
            .patterns = try new_pats.toOwnedSlice(allocator),
            .body_index = row.body_index,
            .guard = row.guard,
        });
    }

    const success_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = @as(u32, @intCast(field_names.items.len)) + (matrix.column_count - 1),
        },
        try combined_ids.toOwnedSlice(allocator),
        next_id,
        bound_scrutinees,
    );
    const failure_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try failure_rows.toOwnedSlice(allocator),
            .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
        },
        remaining_scrutinees,
        next_id,
        bound_scrutinees,
    );

    const node = try allocator.create(Decision);
    node.* = .{ .extract_struct = .{
        .scrutinee = scrutinee_expr,
        .fields = try extractions.toOwnedSlice(allocator),
        .success = success_decision,
        .failure = failure_decision,
    } };
    return node;
}

/// Compile a column where the first pattern is `map_match`. The shape mirrors
/// `compileStructFields` but indexes by key expression rather than field name.
fn compileMapFields(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct keys by AST pointer identity (parser de-duplicates
    // literal keys — a coarser equivalence check would need an interpreter).
    var keys: std.ArrayList(*const ast.Expr) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .map_match) continue;
        for (pat.?.map_match.field_bindings) |fb| {
            var found = false;
            for (keys.items) |existing| {
                if (existing == fb.key) {
                    found = true;
                    break;
                }
            }
            if (!found) try keys.append(allocator, fb.key);
        }
    }

    if (keys.items.len == 0) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    var extractions: std.ArrayList(MapKeyExtraction) = .empty;
    var key_scrutinee_ids: std.ArrayList(u32) = .empty;
    for (keys.items) |key_expr| {
        const sid = next_id.*;
        next_id.* += 1;
        // key_expr_hir built lazily — the IR converts the AST key inline;
        // here we just want a placeholder Expr so the Decision can
        // reference the key for its own diagnostics.
        const placeholder = try allocator.create(Expr);
        placeholder.* = .{
            .kind = .nil_lit,
            .type_id = types_mod.TypeStore.UNKNOWN,
            .span = key_expr.getMeta().span,
        };
        try extractions.append(allocator, .{ .key = placeholder, .scrutinee_id = sid });
        try key_scrutinee_ids.append(allocator, sid);
    }

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    var combined_ids: std.ArrayList(u32) = .empty;
    try combined_ids.appendSlice(allocator, key_scrutinee_ids.items);
    try combined_ids.appendSlice(allocator, remaining_scrutinees);

    var success_rows: std.ArrayList(PatternRow) = .empty;
    var failure_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const head = row.patterns[0];
        const tail = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        if (isWildcardPattern(head)) {
            var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
            for (keys.items) |_| try new_pats.append(allocator, null);
            try new_pats.appendSlice(allocator, tail);
            try success_rows.append(allocator, .{
                .patterns = try new_pats.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
            try failure_rows.append(allocator, .{
                .patterns = tail,
                .body_index = row.body_index,
                .guard = row.guard,
            });
            continue;
        }
        if (head.?.* != .map_match) continue;
        const mm = head.?.map_match;
        var new_pats: std.ArrayList(?*const MatchPattern) = .empty;
        for (keys.items) |k| {
            var matched: ?*const MatchPattern = null;
            for (mm.field_bindings) |fb| {
                if (fb.key == k) {
                    matched = fb.pattern;
                    break;
                }
            }
            try new_pats.append(allocator, matched);
        }
        try new_pats.appendSlice(allocator, tail);
        try success_rows.append(allocator, .{
            .patterns = try new_pats.toOwnedSlice(allocator),
            .body_index = row.body_index,
            .guard = row.guard,
        });
    }

    const success_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = @as(u32, @intCast(keys.items.len)) + (matrix.column_count - 1),
        },
        try combined_ids.toOwnedSlice(allocator),
        next_id,
        bound_scrutinees,
    );
    const failure_decision = try compilePatternMatrixWithBindings(
        allocator,
        .{
            .rows = try failure_rows.toOwnedSlice(allocator),
            .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
        },
        remaining_scrutinees,
        next_id,
        bound_scrutinees,
    );

    const node = try allocator.create(Decision);
    node.* = .{ .extract_map = .{
        .scrutinee = scrutinee_expr,
        .keys = try extractions.toOwnedSlice(allocator),
        .success = success_decision,
        .failure = failure_decision,
    } };
    return node;
}

fn compileLiteralSwitch(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct literal values
    const DistinctLit = struct {
        value: LiteralValue,
    };
    var distinct: std.ArrayList(DistinctLit) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* == .literal) {
            const lit = pat.?.literal;
            var found = false;
            for (distinct.items) |d| {
                if (literalEquals(d.value, lit)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try distinct.append(allocator, .{ .value = lit });
            }
        }
    }

    // For each distinct value, collect matching+wildcard rows, strip column, recurse
    var cases: std.ArrayList(LiteralCase) = .empty;
    for (distinct.items) |dv| {
        var sub_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];
            if (isWildcardPattern(pat)) {
                // Wildcard rows match every constructor
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            } else if (pat.?.* == .literal and literalEquals(pat.?.literal, dv.value)) {
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            }
        }

        const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
        const sub_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try sub_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, new_scrutinees, next_id, bound_scrutinees);

        try cases.append(allocator, .{
            .value = dv.value,
            .next = sub_decision,
        });
    }

    // Default: wildcard-only rows
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try default_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    const default_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .switch_literal = .{
        .scrutinee = scrutinee_expr,
        .cases = try cases.toOwnedSlice(allocator),
        .default = default_decision,
    } };
    return d;
}

fn compileAtomSwitch(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect distinct atom values
    var distinct_atoms: std.ArrayList(ast.StringId) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* == .literal and pat.?.literal == .atom) {
            const atom_id = pat.?.literal.atom;
            var found = false;
            for (distinct_atoms.items) |existing| {
                if (existing == atom_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try distinct_atoms.append(allocator, atom_id);
            }
        }
    }

    var switch_cases: std.ArrayList(SwitchCase) = .empty;
    for (distinct_atoms.items) |atom_id| {
        var sub_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];
            if (isWildcardPattern(pat)) {
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            } else if (pat.?.* == .literal and pat.?.literal == .atom and pat.?.literal.atom == atom_id) {
                const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
                try sub_rows.append(allocator, .{
                    .patterns = new_pats,
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            }
        }

        const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
        const sub_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try sub_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, new_scrutinees, next_id, bound_scrutinees);

        try switch_cases.append(allocator, .{
            .tag = atom_id,
            .bindings = &.{},
            .next = sub_decision,
        });
    }

    // Default
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try default_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }
    const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    const default_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .switch_tag = .{
        .scrutinee = scrutinee_expr,
        .cases = try switch_cases.toOwnedSlice(allocator),
        .default = default_decision,
    } };
    return d;
}

/// Compile a pin pattern (variable unification) into a guard node.
/// `fn foo(x, [x | rest])` — the pin on the second `x` becomes a guard
/// checking that the scrutinee equals the binding from the earlier column.
fn compilePinGuard(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Find the pin name from the first non-wildcard row
    var pin_name: ?ast.StringId = null;
    for (matrix.rows) |row| {
        if (row.patterns.len > 0 and !isWildcardPattern(row.patterns[0])) {
            if (row.patterns[0].?.* == .pin) {
                pin_name = row.patterns[0].?.pin;
                break;
            }
        }
    }
    if (pin_name == null) {
        return stripColumnAndRecurse(allocator, matrix, scrutinee_ids, next_id, bound_scrutinees);
    }

    // Build a guard expression: scrutinee == pinned_variable
    // The pinned variable is a param_get referencing the earlier binding's scrutinee.
    // We look up the scrutinee ID from bound_scrutinees which was recorded when the
    // original bind was processed.
    const bound_id = bound_scrutinees.get(pin_name.?) orelse 0;
    const pin_var_expr = try allocator.create(Expr);
    pin_var_expr.* = .{
        .kind = .{ .param_get = bound_id },
        .type_id = types_mod.TypeStore.UNKNOWN,
        .span = .{ .start = 0, .end = 0 },
    };

    const guard_condition = try allocator.create(Expr);
    guard_condition.* = .{
        .kind = .{ .binary = .{
            .op = .equal,
            .lhs = scrutinee_expr,
            .rhs = pin_var_expr,
        } },
        .type_id = types_mod.TypeStore.UNKNOWN,
        .span = .{ .start = 0, .end = 0 },
    };

    // Matching rows: rows with pin or wildcard in column 0
    var match_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat) or (pat != null and pat.?.* == .pin)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try match_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    // Default rows: only wildcards
    var default_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        if (isWildcardPattern(row.patterns[0])) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try default_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const new_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    const success = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try match_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const failure = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try default_rows.toOwnedSlice(allocator),
        .column_count = matrix.column_count - 1,
    }, new_scrutinees, next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .guard = .{
        .condition = guard_condition,
        .success = success,
        .failure = failure,
    } };
    return d;
}

fn compileTupleCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect unique arities from tuple patterns
    var arities: std.ArrayList(u32) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .tuple) {
            const arity: u32 = @intCast(pat.?.tuple.len);
            var found = false;
            for (arities.items) |a| {
                if (a == arity) {
                    found = true;
                    break;
                }
            }
            if (!found) try arities.append(allocator, arity);
        }
    }

    // Sort arities ascending so we test smallest first
    std.sort.pdq(u32, arities.items, {}, std.sort.asc(u32));

    // Build wildcard-only failure base
    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    var current_failure: *const Decision = undefined;
    if (wildcard_rows.items.len > 0) {
        current_failure = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try wildcard_rows.toOwnedSlice(allocator),
            .column_count = matrix.column_count - 1,
        }, remaining_scrutinees, next_id, bound_scrutinees);
    } else {
        const f = try allocator.create(Decision);
        f.* = .failure;
        current_failure = f;
    }

    // If all patterns have the same arity (or there's only one), use single check_tuple
    // Otherwise, chain check_tuple nodes from largest arity to smallest
    var i = arities.items.len;
    while (i > 0) {
        i -= 1;
        const arity = arities.items[i];

        // Build success rows for this specific arity
        var success_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];

            var new_cols: std.ArrayList(?*const MatchPattern) = .empty;
            if (!isWildcardPattern(pat) and pat.?.* == .tuple) {
                const pat_arity: u32 = @intCast(pat.?.tuple.len);
                if (pat_arity != arity) continue; // Only include patterns with this arity

                for (pat.?.tuple) |sub_pat| {
                    try new_cols.append(allocator, sub_pat);
                }
            } else if (isWildcardPattern(pat)) {
                // Wildcard matches any tuple — expand to this arity's worth of wildcards
                var j: u32 = 0;
                while (j < arity) : (j += 1) {
                    const wc = try allocator.create(MatchPattern);
                    wc.* = .wildcard;
                    try new_cols.append(allocator, wc);
                }
            } else {
                continue;
            }

            // Append remaining columns
            if (row.patterns.len > 1) {
                for (row.patterns[1..]) |p| {
                    try new_cols.append(allocator, p);
                }
            }

            try success_rows.append(allocator, .{
                .patterns = try new_cols.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }

        // Build new scrutinee IDs for this arity's elements.
        // Save element IDs separately for the CheckTupleNode so IR lowering
        // can map element positions to scrutinee locals directly.
        var element_ids: std.ArrayList(u32) = .empty;
        var new_scrutinee_list: std.ArrayList(u32) = .empty;
        var j: u32 = 0;
        while (j < arity) : (j += 1) {
            try element_ids.append(allocator, next_id.*);
            try new_scrutinee_list.append(allocator, next_id.*);
            next_id.* += 1;
        }
        if (scrutinee_ids.len > 1) {
            for (scrutinee_ids[1..]) |sid| {
                try new_scrutinee_list.append(allocator, sid);
            }
        }

        const new_col_count = arity + (matrix.column_count - 1);
        const success_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = new_col_count,
        }, try new_scrutinee_list.toOwnedSlice(allocator), next_id, bound_scrutinees);

        const d = try allocator.create(Decision);
        d.* = .{ .check_tuple = .{
            .scrutinee = scrutinee_expr,
            .expected_arity = arity,
            .element_scrutinee_ids = try element_ids.toOwnedSlice(allocator),
            .success = success_decision,
            .failure = current_failure,
        } };
        current_failure = d;
    }

    return current_failure;
}

fn compileListCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    // Collect unique lengths from list patterns
    var lengths: std.ArrayList(u32) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .list) {
            const length: u32 = @intCast(pat.?.list.len);
            var found = false;
            for (lengths.items) |l| {
                if (l == length) {
                    found = true;
                    break;
                }
            }
            if (!found) try lengths.append(allocator, length);
        }
    }

    std.sort.pdq(u32, lengths.items, {}, std.sort.asc(u32));

    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Build wildcard failure base
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        if (isWildcardPattern(row.patterns[0])) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{ .patterns = new_pats, .body_index = row.body_index, .guard = row.guard });
        }
    }
    var current_failure = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try wildcard_rows.toOwnedSlice(allocator),
        .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
    }, remaining_scrutinees, next_id, bound_scrutinees);

    // For each unique length, build a check_list node
    var i: usize = lengths.items.len;
    while (i > 0) {
        i -= 1;
        const length = lengths.items[i];

        // Allocate new scrutinee IDs for list elements. Save them in a
        // separate slice that the CheckListNode owns so IR lowering can map
        // list element positions to scrutinee locals directly without
        // relying on `findParamGetIdInDecision` heuristics.
        var element_ids: std.ArrayList(u32) = .empty;
        var new_scrutinee_list: std.ArrayList(u32) = .empty;
        for (0..length) |_| {
            try element_ids.append(allocator, next_id.*);
            try new_scrutinee_list.append(allocator, next_id.*);
            next_id.* += 1;
        }
        for (remaining_scrutinees) |s| {
            try new_scrutinee_list.append(allocator, s);
        }

        const new_col_count = length + (matrix.column_count - 1);

        // Build rows: expand list elements for matching rows, pass wildcards through
        var success_rows: std.ArrayList(PatternRow) = .empty;
        for (matrix.rows) |row| {
            if (row.patterns.len == 0) continue;
            const pat = row.patterns[0];
            const rest_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});

            if (!isWildcardPattern(pat) and pat.?.* == .list and pat.?.list.len == length) {
                // Matching list — expand elements into columns
                var expanded: std.ArrayList(?*const MatchPattern) = .empty;
                for (pat.?.list) |elem| {
                    try expanded.append(allocator, elem);
                }
                for (rest_pats) |rp| {
                    try expanded.append(allocator, rp);
                }
                try success_rows.append(allocator, .{
                    .patterns = try expanded.toOwnedSlice(allocator),
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            } else if (isWildcardPattern(pat)) {
                // Wildcards match any length — expand as N wildcards
                var expanded: std.ArrayList(?*const MatchPattern) = .empty;
                for (0..length) |_| {
                    try expanded.append(allocator, null);
                }
                for (rest_pats) |rp| {
                    try expanded.append(allocator, rp);
                }
                try success_rows.append(allocator, .{
                    .patterns = try expanded.toOwnedSlice(allocator),
                    .body_index = row.body_index,
                    .guard = row.guard,
                });
            }
        }

        const success_decision = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = new_col_count,
        }, try new_scrutinee_list.toOwnedSlice(allocator), next_id, bound_scrutinees);

        const d = try allocator.create(Decision);
        d.* = .{ .check_list = .{
            .scrutinee = scrutinee_expr,
            .expected_length = length,
            .element_scrutinee_ids = try element_ids.toOwnedSlice(allocator),
            .success = success_decision,
            .failure = current_failure,
        } };
        current_failure = d;
    }

    return current_failure;
}

fn compileListConsCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Build wildcard/empty failure base (rows with wildcard or [] patterns)
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat) or (pat != null and pat.?.* == .list and pat.?.list.len == 0)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{ .patterns = new_pats, .body_index = row.body_index, .guard = row.guard });
        }
    }
    const failure = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try wildcard_rows.toOwnedSlice(allocator),
        .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
    }, remaining_scrutinees, next_id, bound_scrutinees);

    // For cons patterns, extract heads and tail into new scrutinee columns.
    // Determine head_count from the first cons pattern.
    var head_count: u32 = 1;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (!isWildcardPattern(pat) and pat.?.* == .list_cons) {
            head_count = @intCast(pat.?.list_cons.heads.len);
            break;
        }
    }

    // Allocate scrutinee IDs for head elements and tail
    var head_ids: std.ArrayList(u32) = .empty;
    for (0..head_count) |_| {
        try head_ids.append(allocator, next_id.*);
        next_id.* += 1;
    }
    const tail_id = next_id.*;
    next_id.* += 1;

    // Build success rows: expand [h | t] into h, t columns
    var new_scrutinee_list: std.ArrayList(u32) = .empty;
    for (head_ids.items) |hid| try new_scrutinee_list.append(allocator, hid);
    try new_scrutinee_list.append(allocator, tail_id);
    for (remaining_scrutinees) |s| try new_scrutinee_list.append(allocator, s);

    const new_col_count = head_count + 1 + (matrix.column_count - 1);

    var success_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        const rest_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});

        if (!isWildcardPattern(pat) and pat.?.* == .list_cons) {
            // Expand [h1, h2, ... | t] into h1, h2, ..., t columns
            var expanded: std.ArrayList(?*const MatchPattern) = .empty;
            for (pat.?.list_cons.heads) |head| {
                try expanded.append(allocator, head);
            }
            try expanded.append(allocator, pat.?.list_cons.tail);
            for (rest_pats) |rp| try expanded.append(allocator, rp);
            try success_rows.append(allocator, .{
                .patterns = try expanded.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        } else if (isWildcardPattern(pat)) {
            // Wildcards match cons too — expand as N+1 wildcards
            var expanded: std.ArrayList(?*const MatchPattern) = .empty;
            for (0..(head_count + 1)) |_| {
                try expanded.append(allocator, null);
            }
            for (rest_pats) |rp| try expanded.append(allocator, rp);
            try success_rows.append(allocator, .{
                .patterns = try expanded.toOwnedSlice(allocator),
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const success_decision = try compilePatternMatrixWithBindings(allocator, .{
        .rows = try success_rows.toOwnedSlice(allocator),
        .column_count = new_col_count,
    }, try new_scrutinee_list.toOwnedSlice(allocator), next_id, bound_scrutinees);

    const d = try allocator.create(Decision);
    d.* = .{ .check_list_cons = .{
        .scrutinee = scrutinee_expr,
        .head_count = head_count,
        .head_scrutinee_ids = try head_ids.toOwnedSlice(allocator),
        .tail_scrutinee_id = tail_id,
        .success = success_decision,
        .failure = failure,
    } };
    return d;
}

fn compileBinaryCheck(
    allocator: std.mem.Allocator,
    matrix: PatternMatrix,
    scrutinee_ids: []const u32,
    scrutinee_expr: *const Expr,
    next_id: *u32,
    bound_scrutinees: *BoundScrutinees,
) anyerror!*const Decision {
    const remaining_scrutinees = if (scrutinee_ids.len > 1) scrutinee_ids[1..] else @as([]const u32, &.{});

    // Wildcard rows form the terminal failure: when no binary pattern
    // matches, fall through to wildcard-only matrix (which may itself
    // contain further constructors on remaining columns).
    var wildcard_rows: std.ArrayList(PatternRow) = .empty;
    for (matrix.rows) |row| {
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) {
            const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try wildcard_rows.append(allocator, .{
                .patterns = new_pats,
                .body_index = row.body_index,
                .guard = row.guard,
            });
        }
    }

    const wildcard_failure: *const Decision = blk: {
        if (wildcard_rows.items.len > 0) {
            break :blk try compilePatternMatrixWithBindings(allocator, .{
                .rows = try wildcard_rows.toOwnedSlice(allocator),
                .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
            }, remaining_scrutinees, next_id, bound_scrutinees);
        }
        const f = try allocator.create(Decision);
        f.* = .failure;
        break :blk f;
    };

    // Build a per-row chain in REVERSE order so that the first matrix row
    // ends up at the outermost `check_binary`. Earlier code only handled
    // the first row's segments and silently dropped clauses 2+; chaining
    // each row preserves clause order while letting the IR see every
    // pattern's segment shape.
    var chain: *const Decision = wildcard_failure;
    var idx: usize = matrix.rows.len;
    while (idx > 0) {
        idx -= 1;
        const row = matrix.rows[idx];
        if (row.patterns.len == 0) continue;
        const pat = row.patterns[0];
        if (isWildcardPattern(pat)) continue;
        if (pat.?.* != .binary_match) continue;

        const segments = pat.?.binary_match.segments;
        const min_byte_size = computeBinaryMinByteSize(segments);

        const new_pats = if (row.patterns.len > 1) row.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
        var success_rows: std.ArrayList(PatternRow) = .empty;
        try success_rows.append(allocator, .{
            .patterns = new_pats,
            .body_index = row.body_index,
            .guard = row.guard,
        });
        // Wildcards still need to be reachable from this success branch
        // when the remaining columns demand them, so keep them in scope.
        for (matrix.rows) |w| {
            if (w.patterns.len == 0) continue;
            if (!isWildcardPattern(w.patterns[0])) continue;
            const tail = if (w.patterns.len > 1) w.patterns[1..] else @as([]const ?*const MatchPattern, &.{});
            try success_rows.append(allocator, .{
                .patterns = tail,
                .body_index = w.body_index,
                .guard = w.guard,
            });
        }
        const success = try compilePatternMatrixWithBindings(allocator, .{
            .rows = try success_rows.toOwnedSlice(allocator),
            .column_count = if (matrix.column_count > 0) matrix.column_count - 1 else 0,
        }, remaining_scrutinees, next_id, bound_scrutinees);

        const node = try allocator.create(Decision);
        node.* = .{ .check_binary = .{
            .scrutinee = scrutinee_expr,
            .min_byte_size = min_byte_size,
            .segments = segments,
            .success = success,
            .failure = chain,
        } };
        chain = node;
    }

    return chain;
}

/// Compute the minimum byte size required by a binary pattern's segments.
/// Sub-byte integer/float types accumulate bit-wise and round up; string
/// segments with literal sizes contribute their byte length.
fn computeBinaryMinByteSize(segments: []const BinaryMatchSegment) u32 {
    var min_bits: u32 = 0;
    for (segments) |seg| {
        switch (seg.type_spec) {
            .default => min_bits += 8,
            .integer => |i| min_bits += i.bits,
            .float => |f| min_bits += f.bits,
            .string => {
                if (min_bits % 8 != 0) min_bits = (min_bits + 7) / 8 * 8;
                if (seg.size) |sz| {
                    switch (sz) {
                        .literal => |n| min_bits += n * 8,
                        .variable => {},
                    }
                }
            },
            .utf8 => min_bits += 8,
            .utf16 => min_bits += 16,
            .utf32 => min_bits += 32,
        }
    }
    return (min_bits + 7) / 8;
}

fn literalEquals(a: LiteralValue, b: LiteralValue) bool {
    const tag_a = std.meta.activeTag(a);
    const tag_b = std.meta.activeTag(b);
    if (tag_a != tag_b) return false;
    return switch (a) {
        .int => |v| v == b.int,
        .float => |v| v == b.float,
        .string => |v| v == b.string,
        .atom => |v| v == b.atom,
        .bool_val => |v| v == b.bool_val,
        .nil => true,
    };
}

// ============================================================
// Operator → protocol mapping
// ============================================================

/// Metadata for routing a binary operator through a protocol impl call.
const OperatorMeta = struct {
    /// Protocol that defines the operator (`Arithmetic`, `Comparator`).
    protocol: []const u8,
    /// Method name as it appears in the impl (`+`, `==`, `rem`, ...).
    method: []const u8,
    /// Result type derived from the operand type. Arithmetic returns
    /// the operand type; comparison returns Bool.
    result_type: *const fn (operand_type: types_mod.TypeId) types_mod.TypeId,
};

fn sameAsOperand(operand_type: types_mod.TypeId) types_mod.TypeId {
    return operand_type;
}

/// Unify two type IDs for the purpose of typing a heterogeneous
/// collection. Equal types unify to themselves. Disagreeing scalar
/// types collapse to `TERM`. Tuples of identical arity unify
/// component-wise — each disagreeing slot becomes `TERM`. Differing
/// arities fall back to the whole element type being `TERM`.
fn unifyForCollection(store: *types_mod.TypeStore, a: types_mod.TypeId, b: types_mod.TypeId) types_mod.TypeId {
    if (a == b) return a;
    if (a == types_mod.TypeStore.UNKNOWN) return b;
    if (b == types_mod.TypeStore.UNKNOWN) return a;
    if (a == types_mod.TypeStore.TERM or b == types_mod.TypeStore.TERM) {
        return types_mod.TypeStore.TERM;
    }
    const ta = store.getType(a);
    const tb = store.getType(b);
    if (ta == .tuple and tb == .tuple and ta.tuple.elements.len == tb.tuple.elements.len) {
        var any_changed = false;
        const unified = store.allocator.alloc(types_mod.TypeId, ta.tuple.elements.len) catch return types_mod.TypeStore.TERM;
        for (ta.tuple.elements, tb.tuple.elements, 0..) |ea, eb, i| {
            const u = unifyForCollection(store, ea, eb);
            if (u != ea) any_changed = true;
            unified[i] = u;
        }
        if (!any_changed) return a;
        return store.addType(.{ .tuple = .{ .elements = unified } }) catch types_mod.TypeStore.TERM;
    }
    if (ta == .list and tb == .list) {
        const u = unifyForCollection(store, ta.list.element, tb.list.element);
        if (u == ta.list.element) return a;
        return store.addType(.{ .list = .{ .element = u } }) catch types_mod.TypeStore.TERM;
    }
    if (ta == .map and tb == .map) {
        const uk = unifyForCollection(store, ta.map.key, tb.map.key);
        const uv = unifyForCollection(store, ta.map.value, tb.map.value);
        if (uk == ta.map.key and uv == ta.map.value) return a;
        return store.addType(.{ .map = .{ .key = uk, .value = uv } }) catch types_mod.TypeStore.TERM;
    }
    return types_mod.TypeStore.TERM;
}

/// Propagate a unified collection element type back to a child element.
/// Updates `elem.type_id` to `unified` when the unified form differs but
/// is structurally compatible (same outer shape — tuple of same arity,
/// list, map). For nested tuples, recurses into each component so a list
/// like `[{:name, "x"}, {:age, 42}]` becomes `[{Atom, Term}]` and BOTH
/// child tuples are re-typed to `{Atom, Term}` so the IR builder can
/// thread the term-promoted slots into `tuple_init`'s component_types.
fn propagateUnifiedTypeToElement(store: *types_mod.TypeStore, elem: *Expr, unified: types_mod.TypeId) void {
    if (elem.type_id == unified) return;
    if (unified == types_mod.TypeStore.UNKNOWN) return;
    const elem_kind = store.getType(elem.type_id);
    const uni_kind = store.getType(unified);

    // Tuple — only re-type if both are tuples of the same arity and
    // recurse into each child tuple element.
    if (elem_kind == .tuple and uni_kind == .tuple and
        elem_kind.tuple.elements.len == uni_kind.tuple.elements.len)
    {
        // Recurse into each child of a tuple_init expression so nested
        // tuples carry the unified-component types as well.
        if (elem.kind == .tuple_init) {
            const children = elem.kind.tuple_init;
            for (children, uni_kind.tuple.elements) |child, child_uni| {
                propagateUnifiedTypeToElement(store, @constCast(child), child_uni);
            }
        }
        elem.type_id = unified;
        return;
    }

    // List — recurse into each child element.
    if (elem_kind == .list and uni_kind == .list) {
        if (elem.kind == .list_init) {
            const children = elem.kind.list_init;
            for (children) |child| {
                propagateUnifiedTypeToElement(store, @constCast(child), uni_kind.list.element);
            }
        }
        elem.type_id = unified;
        return;
    }

    // Scalar promoted to Term — update so the construction site wraps via Term.from.
    if (unified == types_mod.TypeStore.TERM) {
        elem.type_id = unified;
        return;
    }
}

fn alwaysBool(_: types_mod.TypeId) types_mod.TypeId {
    return types_mod.TypeStore.BOOL;
}

/// Map a binary AST op to its protocol/method, or null when the op is
/// handled directly by the primitive ZIR path (logical and/or, in,
/// concat). Operators routed here lower to a call against the matching
/// `impl PROTOCOL for OperandType` when one exists; otherwise they fall
/// through to the primitive path.
fn operatorProtocol(op: ast.BinaryOp.Op) ?OperatorMeta {
    return switch (op) {
        .add => .{ .protocol = "Arithmetic", .method = "+", .result_type = sameAsOperand },
        .sub => .{ .protocol = "Arithmetic", .method = "-", .result_type = sameAsOperand },
        .mul => .{ .protocol = "Arithmetic", .method = "*", .result_type = sameAsOperand },
        .div => .{ .protocol = "Arithmetic", .method = "/", .result_type = sameAsOperand },
        .rem_op => .{ .protocol = "Arithmetic", .method = "rem", .result_type = sameAsOperand },
        .equal => .{ .protocol = "Comparator", .method = "==", .result_type = alwaysBool },
        .not_equal => .{ .protocol = "Comparator", .method = "!=", .result_type = alwaysBool },
        .less => .{ .protocol = "Comparator", .method = "<", .result_type = alwaysBool },
        .greater => .{ .protocol = "Comparator", .method = ">", .result_type = alwaysBool },
        .less_equal => .{ .protocol = "Comparator", .method = "<=", .result_type = alwaysBool },
        .greater_equal => .{ .protocol = "Comparator", .method = ">=", .result_type = alwaysBool },
        else => null,
    };
}

// ============================================================
// HIR builder — converts typed AST to HIR
// ============================================================

pub const HirBuilder = struct {
    allocator: std.mem.Allocator,
    interner: *const ast.StringInterner,
    graph: *const scope_mod.ScopeGraph,
    type_store: *types_mod.TypeStore,
    next_group_id: u32,
    next_local: u32,
    current_param_names: []const ?ast.StringId,
    /// Parallel to `current_param_names`. Holds each parameter's TypeId
    /// so var_ref resolution against a parameter sees the type the type
    /// checker (or `inferred_signatures` for synthetic helpers like
    /// for-comp `__for_N`) assigned. The scope-graph binding entry
    /// often doesn't have `type_id` populated for synthetic helpers,
    /// so this in-memory copy is the source of truth during HIR build.
    /// Critical for HIR-time protocol dispatch on
    /// `Enumerable.next(state)` where `state` is the helper's param.
    current_param_types: []const TypeId,
    current_tuple_bindings: std.ArrayList(TupleBinding),
    current_struct_bindings: std.ArrayList(StructBinding),
    current_list_bindings: std.ArrayList(ListBinding),
    current_cons_tail_bindings: std.ArrayList(ConsTailBinding),
    current_binary_bindings: std.ArrayList(BinaryBinding),
    current_map_bindings: std.ArrayList(MapBinding),
    current_case_bindings: std.ArrayList(CaseBinding),
    current_assignment_bindings: std.ArrayList(AssignmentBinding),
    /// Parent function's assignment bindings — used for closure capture detection.
    /// When a closure references a variable from the parent function's bindings,
    /// it generates capture_get instead of local_get.
    parent_assignment_bindings: std.ArrayList(AssignmentBinding),
    current_struct_scope: ?scope_mod.ScopeId,
    current_clause_scope: ?scope_mod.ScopeId,
    /// Set while building the function groups for an `impl Protocol for
    /// Target(K, V)` block. Carries the impl's declared type parameters
    /// so each clause's `hir_type_var_scope` can be pre-populated with
    /// the same K, V bindings as the type checker used. Without this,
    /// `Map(K, V)` in the impl's signatures would resolve to an UNKNOWN
    /// type because HIR's type-var lookup wouldn't find K or V.
    current_impl: ?*const ast.ImplDecl = null,
    current_function_root_scope: ?scope_mod.ScopeId,
    current_function_name: ?[]const u8,
    current_function_name_id: ?ast.StringId,
    /// Phase 3.b — true while building the body of a function whose
    /// inferred/declared `raises` row is non-empty, i.e. one that will lower
    /// to a Zig error-union return. A PROPAGATING `raise` (one not lexically
    /// inside a `try` body, `try_scope_depth == 0`) in such a function lowers
    /// to a `ret_raise` (stash + `return error.ZapRaise`) instead of the
    /// Phase 2 `do_raise` abort, so the error crosses the call boundary to an
    /// enclosing `try`/`rescue`. Set per-clause in `buildFunctionGroup` from
    /// the type store's `inferred_raises` (the same stable qualified key the
    /// IR backend uses), saved/restored around nested groups.
    current_function_emits_error_union: bool = false,
    /// Variable names already bound in the current clause's parameters.
    /// When a bind pattern reuses a name from this set, it becomes a pin
    /// (equality check) instead of a fresh binding — Elixir-style variable
    /// unification.
    clause_bound_names: std.AutoHashMap(ast.StringId, void),
    family_to_group: std.AutoHashMap(scope_mod.FunctionFamilyId, u32),
    group_captures: std.AutoHashMap(u32, []const Capture),
    current_capture_map: std.AutoHashMap(ast.StringId, u32),
    current_capture_list: std.ArrayList(Capture),
    /// Maps type variable names to TypeIds within the current function clause,
    /// ensuring `a` in `fn foo(x :: a) -> a` refers to the same type variable.
    hir_type_var_scope: std.StringHashMap(types_mod.TypeId),
    /// Mirrors the manifest CTFE type-checker policy: build.zap may emit
    /// first-class `Type`/`Function` values that name target-source structs
    /// before those sources are loaded.
    allow_external_static_references: bool = false,
    /// Lexical nesting depth of enclosing `try { … } rescue { … }` bodies
    /// (Phase 3.a). When `> 0`, a `raise %E{}` lowered inside the `try`
    /// body takes the *recoverable* path — it unwinds to the enclosing
    /// `rescue` handler via the error-union/handler mechanism — instead of
    /// the Phase 1.4/2 `Kernel.do_raise` abort. Saved/restored around each
    /// `try` body in `buildExpr`, mirroring the `defer_stack` discipline.
    try_scope_depth: u32 = 0,
    /// Stack of expected types active around the *current* expression
    /// being lowered. Used for context-driven inference of parametric
    /// struct/union literals: when `%Box{...}` appears with no
    /// explicit `(...)` but the surrounding context (variable
    /// annotation, function return, function-arg type) provides a
    /// concrete `Box(i64)` `.applied` TypeId, the literal adopts that
    /// instantiation so monomorphization sees the concrete shape.
    /// Pushed by `buildExprWithExpected` / `lowerWithExpected` helpers
    /// and popped on return; lookups read the topmost entry.
    expected_type_stack: std.ArrayListUnmanaged(types_mod.TypeId) = .empty,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        interner: *const ast.StringInterner,
        graph: *const scope_mod.ScopeGraph,
        type_store: *types_mod.TypeStore,
    ) HirBuilder {
        return .{
            .allocator = allocator,
            .interner = interner,
            .graph = graph,
            .type_store = type_store,
            .next_group_id = 0,
            .next_local = 0,
            .current_param_names = &.{},
            .current_param_types = &.{},
            .current_tuple_bindings = .empty,
            .current_struct_bindings = .empty,
            .current_list_bindings = .empty,
            .current_cons_tail_bindings = .empty,
            .current_binary_bindings = .empty,
            .current_map_bindings = .empty,
            .current_case_bindings = .empty,
            .current_assignment_bindings = .empty,
            .parent_assignment_bindings = .empty,
            .current_struct_scope = null,
            .current_clause_scope = null,
            .current_function_root_scope = null,
            .current_function_name = null,
            .current_function_name_id = null,
            .clause_bound_names = std.AutoHashMap(ast.StringId, void).init(allocator),
            .family_to_group = std.AutoHashMap(scope_mod.FunctionFamilyId, u32).init(allocator),
            .group_captures = std.AutoHashMap(u32, []const Capture).init(allocator),
            .current_capture_map = std.AutoHashMap(ast.StringId, u32).init(allocator),
            .current_capture_list = .empty,
            .hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(allocator),
            .allow_external_static_references = false,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *HirBuilder) void {
        self.family_to_group.deinit();
        self.group_captures.deinit();
        self.current_capture_map.deinit();
        self.current_capture_list.deinit(self.allocator);
        self.current_assignment_bindings.deinit(self.allocator);
        self.current_tuple_bindings.deinit(self.allocator);
        self.current_struct_bindings.deinit(self.allocator);
        self.current_list_bindings.deinit(self.allocator);
        self.current_cons_tail_bindings.deinit(self.allocator);
        self.current_binary_bindings.deinit(self.allocator);
        self.current_map_bindings.deinit(self.allocator);
        self.current_case_bindings.deinit(self.allocator);
        self.parent_assignment_bindings.deinit(self.allocator);
        self.hir_type_var_scope.deinit();
        self.expected_type_stack.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    fn isNativeTypeName(self: *const HirBuilder, kind: scope_mod.NativeTypeKind, name: ast.StringId) bool {
        const registered = self.graph.nativeTypeStructName(kind) orelse return false;
        return registered == name or std.mem.eql(u8, self.interner.get(registered), self.interner.get(name));
    }

    fn resolveImplTargetTypePattern(self: *HirBuilder, impl_d: *const ast.ImplDecl) !TypeId {
        if (impl_d.target_type.parts.len == 0) return types_mod.TypeStore.UNKNOWN;
        const target_name = impl_d.target_type.parts[impl_d.target_type.parts.len - 1];
        const target_text = self.interner.get(target_name);
        const full_target_name = try self.internDottedStructName(impl_d.target_type);
        const full_target_text = self.interner.get(full_target_name);

        if (self.isNativeTypeName(.list, target_name) and impl_d.type_params.len == 1) {
            const element_name = self.interner.get(impl_d.type_params[0]);
            const element_type = self.hir_type_var_scope.get(element_name) orelse types_mod.TypeStore.UNKNOWN;
            return try self.type_store.addType(.{ .list = .{ .element = element_type } });
        }

        if (self.isNativeTypeName(.map, target_name) and impl_d.type_params.len == 2) {
            const key_name = self.interner.get(impl_d.type_params[0]);
            const value_name = self.interner.get(impl_d.type_params[1]);
            const key_type = self.hir_type_var_scope.get(key_name) orelse types_mod.TypeStore.UNKNOWN;
            const value_type = self.hir_type_var_scope.get(value_name) orelse types_mod.TypeStore.UNKNOWN;
            return try self.type_store.addType(.{ .map = .{ .key = key_type, .value = value_type } });
        }

        if (impl_d.type_params.len > 0) {
            const base = self.type_store.name_to_type.get(full_target_name) orelse
                self.type_store.name_to_type.get(target_name) orelse
                self.type_store.resolveTypeName(full_target_text) orelse
                self.type_store.resolveTypeName(target_text) orelse
                types_mod.TypeStore.UNKNOWN;
            const args = try self.allocator.alloc(TypeId, impl_d.type_params.len);
            for (impl_d.type_params, 0..) |type_param, index| {
                const name = self.interner.get(type_param);
                args[index] = self.hir_type_var_scope.get(name) orelse types_mod.TypeStore.UNKNOWN;
            }
            return try self.type_store.addType(.{ .applied = .{ .base = base, .args = args } });
        }

        if (self.type_store.name_to_type.get(full_target_name)) |type_id| return type_id;
        if (self.type_store.resolveTypeName(full_target_text)) |type_id| return type_id;
        if (self.type_store.resolveTypeName(target_text)) |type_id| return type_id;
        if (self.type_store.name_to_type.get(target_name)) |type_id| return type_id;
        return types_mod.TypeStore.UNKNOWN;
    }

    fn resolveImplProtocolTypeData(
        self: *HirBuilder,
        impl_d: *const ast.ImplDecl,
    ) !struct { protocol_type_args: []const TypeId, target_type_pattern: TypeId } {
        const saved_scope = self.hir_type_var_scope;
        self.hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(self.allocator);
        defer {
            self.hir_type_var_scope.deinit();
            self.hir_type_var_scope = saved_scope;
        }

        for (impl_d.type_params) |type_param| {
            const name = self.interner.get(type_param);
            const fresh = try self.type_store.freshVar();
            try self.hir_type_var_scope.put(name, fresh);
        }

        const protocol_type_args = try self.allocator.alloc(TypeId, impl_d.protocol_type_args.len);
        for (impl_d.protocol_type_args, 0..) |type_arg, index| {
            protocol_type_args[index] = self.resolveTypeExpr(type_arg);
        }

        return .{
            .protocol_type_args = protocol_type_args,
            .target_type_pattern = try self.resolveImplTargetTypePattern(impl_d),
        };
    }

    /// Look up a binding's type_id from the scope graph.
    /// Returns the type_id if found, otherwise UNKNOWN.
    /// `reference_scopes` carries the Flatt-2016 hygiene marks of the
    /// reference being resolved; pass `.empty` when the caller has no
    /// reference node in hand (synthetic capture lookups, etc.) — that
    /// path falls through to the lexical-chain walker.
    fn resolveBindingType(self: *const HirBuilder, name: ast.StringId, reference_scopes: scope_mod.ScopeSet) types_mod.TypeId {
        // Elixir-style shadowing: walk assignment bindings in reverse
        // so the most recent rebinding wins over any earlier ones.
        // This must mirror `buildBindingReference`'s ordering — both
        // must agree on which binding `name` resolves to. See that
        // function for the full rationale (COW ARC containers, etc.).
        var assignment_idx = self.current_assignment_bindings.items.len;
        while (assignment_idx > 0) {
            assignment_idx -= 1;
            const binding = self.current_assignment_bindings.items[assignment_idx];
            if (binding.name == name and binding.type_id != types_mod.TypeStore.UNKNOWN) {
                return binding.type_id;
            }
        }
        // Parameter resolution: a name that matches a clause
        // parameter prefers the HIR-resolved type from
        // `current_param_types` *only when that type contains type
        // variables*. The two stores can disagree when a type
        // annotation carries a free type-var (`Box(t)`): the type
        // checker creates one fresh `type_var` in its own scope and
        // records that on the scope-graph binding; the HIR builder
        // independently creates a different fresh `type_var` when
        // it resolves the same annotation in `buildClause`. Using
        // the HIR-resolved tv for parameters whose param type still
        // carries type-vars keeps every reference to the same
        // parameter within a clause carrying the *same* TypeId,
        // which is what the monomorphizer's
        // substitution-by-typevar-id depends on at call sites. For
        // fully concrete annotations we keep the scope-graph value
        // because it carries the (post-typecheck) ownership / span
        // provenance that downstream tests rely on.
        for (self.current_param_names, 0..) |maybe_name, idx| {
            if (maybe_name) |pn| {
                if (pn == name and idx < self.current_param_types.len) {
                    const param_tid = self.current_param_types[idx];
                    if (param_tid != types_mod.TypeStore.UNKNOWN and
                        self.type_store.containsTypeVars(param_tid))
                    {
                        return param_tid;
                    }
                }
            }
        }
        // Scope graph binding — populated by the type checker. Tests rely on
        // mutating the type at this site after type-checking but before HIR
        // build, so this must take precedence over the in-memory parameter
        // copy populated below.
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveBindingHygienic(scope_id, name, reference_scopes)) |bid| {
            const binding = self.graph.bindings.items[bid];
            if (binding.type_id) |prov| {
                return prov.type_id;
            }
        }
        if (self.current_clause_scope) |cs| {
            const scope = self.graph.getScope(cs);
            var it = scope.bindings.iterator();
            while (it.next()) |entry| {
                if (entry.key_ptr.* == name) {
                    const bid = entry.value_ptr.*;
                    const binding = self.graph.bindings.items[bid];
                    if (binding.type_id) |prov| {
                        return prov.type_id;
                    }
                }
            }
        }
        // Fall back to in-memory parameter types. The scope graph binding
        // for a parameter doesn't carry an inferred type for synthetic
        // helpers (e.g. for-comp `__for_N`), so this parallel array
        // populated in buildClause is the source of truth in that case.
        for (self.current_param_names, 0..) |maybe_name, idx| {
            if (maybe_name) |pn| {
                if (pn == name and idx < self.current_param_types.len) {
                    const tid = self.current_param_types[idx];
                    if (tid != types_mod.TypeStore.UNKNOWN) return tid;
                }
            }
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    /// Look up a function's declared return type from the scope graph.
    /// Searches current struct scope, then prelude.
    /// Resolve a generic function's return type by unifying argument types with
    /// parameter types and applying the substitution to the raw return type.
    fn resolveGenericReturnType(
        self: *const HirBuilder,
        mod_name: []const u8,
        func_name: []const u8,
        arity: u32,
        call_args: []const CallArg,
        raw_return: types_mod.TypeId,
    ) types_mod.TypeId {
        // Find the target struct's scope, then resolve the family through
        // the scope's `function_families` map. This goes through the
        // public `resolveFamily` API which honours impl-registered
        // function families — `registerImplFunctionsInTargetScopes`
        // (`src/collector.zig:594`) installs impl-defined functions
        // into their target scope's lookup map without rewriting the
        // family's own `scope_id`. A linear `family.scope_id ==
        // mod_entry.scope_id` filter would have missed them and
        // returned `raw_return` (typevars un-substituted), leaving
        // call sites with `Map(K_v, V_v)` propagated as `local_types`
        // — masked downstream by monomorphize but still wrong.
        for (self.graph.structs.items) |mod_entry| {
            if (mod_entry.name.parts.len == 0) continue;
            const last_part = self.interner.get(mod_entry.name.parts[mod_entry.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, mod_name)) continue;
            const name_id = self.interner.lookupExisting(func_name) orelse continue;
            const fam_id = self.graph.resolveFamily(mod_entry.scope_id, name_id, arity) orelse continue;
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len == 0) continue;
            const first_clause = family.clauses.items[0];
            if (first_clause.clause_index >= first_clause.decl.clauses.len) continue;
            const clause = first_clause.decl.clauses[first_clause.clause_index];
            if (clause.params.len != arity) continue;
            return self.substituteReturnTypeFromArgs(&clause, call_args, raw_return);
        }
        return raw_return;
    }

    /// Resolve a generic function's return type for a local-scope call by
    /// walking the scope chain to find the family. Mirrors
    /// `resolveGenericReturnType` but uses scope-based resolution instead
    /// of struct-name-based.
    fn resolveGenericReturnTypeLocal(
        self: *const HirBuilder,
        name: ast.StringId,
        arity: u32,
        call_args: []const CallArg,
        raw_return: types_mod.TypeId,
    ) types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        const fam_id = self.graph.resolveFamily(scope_id, name, arity) orelse return raw_return;
        const family = self.graph.getFamily(fam_id);
        if (family.clauses.items.len == 0) return raw_return;
        const first_clause = family.clauses.items[0];
        if (first_clause.clause_index >= first_clause.decl.clauses.len) return raw_return;
        const clause = first_clause.decl.clauses[first_clause.clause_index];
        if (clause.params.len != arity) return raw_return;
        return self.substituteReturnTypeFromArgs(&clause, call_args, raw_return);
    }

    /// Shared inference: walk params, unify with arg types into a substitution
    /// map, apply the substitution to the raw return type. Returns the raw
    /// return type unchanged when no inference is possible.
    ///
    /// The CALLED function's type variables (e.g., `a` in `pub fn +(a, a) -> a`)
    /// are resolved in a fresh `hir_type_var_scope` so that the surrounding
    /// clause's existing type-var bindings (e.g., `element` in the enclosing
    /// `fn map(list :: [element], f) -> [element]`) survive across the inference.
    fn substituteReturnTypeFromArgs(
        self: *const HirBuilder,
        clause: *const ast.FunctionClause,
        call_args: []const CallArg,
        raw_return: types_mod.TypeId,
    ) types_mod.TypeId {
        const self_mut: *HirBuilder = @constCast(self);
        const saved_scope = self_mut.hir_type_var_scope;
        self_mut.hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(self.allocator);
        defer {
            self_mut.hir_type_var_scope.deinit();
            self_mut.hir_type_var_scope = saved_scope;
        }

        var subs = types_mod.SubstitutionMap.init(self.allocator);
        for (clause.params, 0..) |param, i| {
            if (i >= call_args.len) break;
            var arg_type = call_args[i].expr.type_id;
            if (arg_type == types_mod.TypeStore.UNKNOWN) {
                if (call_args[i].expr.kind == .list_init and call_args[i].expr.kind.list_init.len == 0) {
                    const store_ptr2: *types_mod.TypeStore = @constCast(self.type_store);
                    arg_type = store_ptr2.addType(.{ .list = .{ .element = types_mod.TypeStore.I64 } }) catch types_mod.TypeStore.UNKNOWN;
                }
                if (arg_type == types_mod.TypeStore.UNKNOWN) continue;
            }
            if (param.type_annotation) |ta| {
                const param_type = self.resolveTypeExpr(ta);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                _ = store_ptr.unify(param_type, arg_type, &subs) catch {};
            }
        }
        if (subs.bindings.count() > 0) {
            // Resolve raw_return through the same type var scope, then substitute.
            if (clause.return_type) |rt| {
                const resolved_return = self.resolveTypeExpr(rt);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                return subs.applyToType(store_ptr, resolved_return);
            }
            const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
            return subs.applyToType(store_ptr, raw_return);
        }
        // No inference possible (all args UNKNOWN, e.g. case-clause bindings
        // without propagated types). Return UNKNOWN rather than an unresolved
        // type variable so downstream UNKNOWN-tolerant checks apply.
        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
        if (store_ptr.containsTypeVars(raw_return)) return types_mod.TypeStore.UNKNOWN;
        return raw_return;
    }

    /// Resolve a function's return type within a specific struct
    /// (for cross-struct calls).
    fn resolveFunctionReturnTypeInStruct(self: *const HirBuilder, struct_simple: []const u8, func_name: []const u8, arity: u32) types_mod.TypeId {
        // Find the matching struct's scope, then look up the family
        // via the scope's `function_families` map. The map covers
        // both functions declared inside the struct AND impl
        // functions registered via
        // `registerImplFunctionsInTargetScopes` — critical for
        // protocol dispatch through `String.concat`, `List.next`,
        // etc., where the impl-defined family lives in the impl's
        // own scope but is reachable from the target struct's scope
        // via the registered map entry.
        const func_name_id = self.interner.lookupExisting(func_name) orelse return types_mod.TypeStore.UNKNOWN;
        const key = scope_mod.FamilyKey{ .name = func_name_id, .arity = arity };
        for (self.graph.structs.items) |struct_entry| {
            if (struct_entry.name.parts.len == 0) continue;
            if (!self.structNameMatchesCallQualifier(struct_entry.name, struct_simple)) continue;
            const struct_scope = self.graph.getScope(struct_entry.scope_id);
            const fam_id = struct_scope.function_families.get(key) orelse continue;
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len > 0) {
                const first_clause = family.clauses.items[0];
                if (first_clause.clause_index < first_clause.decl.clauses.len) {
                    const clause = first_clause.decl.clauses[first_clause.clause_index];
                    if (clause.return_type) |rt| {
                        return self.resolveTypeExpr(rt);
                    }
                }
            }
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    fn resolveFunctionReturnType(self: *const HirBuilder, name: ast.StringId, arity: u32) types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveFamily(scope_id, name, arity)) |fam_id| {
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len > 0) {
                const first_clause = family.clauses.items[0];
                if (first_clause.clause_index < first_clause.decl.clauses.len) {
                    const clause = first_clause.decl.clauses[first_clause.clause_index];
                    if (clause.return_type) |rt| {
                        return self.resolveTypeExpr(rt);
                    }
                }
            }
        }
        // Synthetic helpers (`__for_N`) carry no source-level return
        // annotation but the type checker writes a call-site-inferred
        // return type into `inferred_signatures` once the body has been
        // checked. Falling back to that here lets recursive calls see
        // the right element type for cons emission, etc.
        if (self.type_store.inferred_signatures.get(name)) |sig| {
            return sig.return_type;
        }
        return types_mod.TypeStore.UNKNOWN;
    }

    /// Check if a function (by name and arity) is dispatched: i.e., one of its
    /// clauses can fail to match at runtime, so the call may produce a "no
    /// matching clause" outcome that a `~>` catch basin should be able to catch.
    ///
    /// A function is dispatched when EITHER:
    ///   * it has multiple clauses (the dispatcher must select one), OR
    ///   * its single clause has a non-trivial parameter pattern or a
    ///     refinement guard, so calling it with an unmatched argument is a
    ///     dispatch failure rather than a sure-match.
    ///
    /// Pure variable-binding / wildcard clauses with no guard are always
    /// total — they don't need a `__try` variant and would not benefit from
    /// catch-basin handling.
    fn isFunctionMultiClause(self: *const HirBuilder, name: ast.StringId, arity: u32) bool {
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        if (self.graph.resolveFamily(scope_id, name, arity)) |fam_id| {
            const family = self.graph.getFamily(fam_id);
            if (family.clauses.items.len > 1) return true;
            if (family.clauses.items.len == 1) {
                const clause_ref = family.clauses.items[0];
                const clause = clause_ref.decl.clauses[clause_ref.clause_index];
                if (clause.refinement != null) return true;
                for (clause.params) |param| {
                    if (!isTotalParamPattern(param.pattern)) return true;
                }
            }
        }
        return false;
    }

    /// A parameter pattern is "total" when it is guaranteed to match any
    /// runtime value of its declared type without inspecting the value.
    /// Bare bindings, wildcards, and parenthesised total patterns qualify.
    /// Anything that does runtime structural inspection (literals, tuples,
    /// lists, maps, struct patterns, binaries, pins) is non-total.
    fn isTotalParamPattern(pattern: *const ast.Pattern) bool {
        return switch (pattern.*) {
            .wildcard, .bind => true,
            .paren => |p| isTotalParamPattern(p.inner),
            else => false,
        };
    }

    fn applyCallArgModes(self: *const HirBuilder, args: []CallArg, callee_type_id: types_mod.TypeId) void {
        if (callee_type_id == types_mod.TypeStore.UNKNOWN) return;
        const callee_type = self.type_store.getType(callee_type_id);
        if (callee_type != .function) return;
        const ownerships = callee_type.function.param_ownerships orelse return;
        const count = @min(args.len, ownerships.len);
        for (args[0..count], ownerships[0..count]) |*arg, ownership| {
            arg.mode = switch (ownership) {
                .shared => .share,
                .unique => .move,
                .borrowed => .borrow,
            };
        }
    }

    fn defaultOwnershipForType(self: *const HirBuilder, type_id: types_mod.TypeId) Ownership {
        const typ = self.type_store.getType(type_id);
        return switch (typ) {
            .opaque_type => .unique,
            else => .shared,
        };
    }

    fn resolveParamOwnership(self: *const HirBuilder, param: ast.Param, resolved_type: types_mod.TypeId) Ownership {
        if (param.ownership_explicit) {
            return switch (param.ownership) {
                .shared => .shared,
                .unique => .unique,
                .borrowed => .borrowed,
            };
        }
        return switch (param.ownership) {
            .shared => self.defaultOwnershipForType(resolved_type),
            .unique => .unique,
            .borrowed => .borrowed,
        };
    }

    fn mapAstOwnership(ownership: ast.Ownership) Ownership {
        return switch (ownership) {
            .shared => .shared,
            .unique => .unique,
            .borrowed => .borrowed,
        };
    }

    fn resolveFunctionParamOwnerships(self: *HirBuilder, name: ast.StringId, arity: u32) ?[]const Ownership {
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        const family_id = self.graph.resolveFamily(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];

        const ownerships = self.allocator.alloc(Ownership, clause.params.len) catch return null;
        for (clause.params, 0..) |param, idx| {
            ownerships[idx] = blk: {
                if (param.pattern.* == .bind) {
                    const clause_scope = self.graph.resolveClauseScope(clause.meta) orelse clause.meta.scope_id;
                    if (self.graph.resolveBindingHygienic(clause_scope, param.pattern.bind.name, param.pattern.bind.meta.scopes)) |binding_id| {
                        if (self.graph.bindings.items[binding_id].type_id) |prov| {
                            break :blk self.resolveParamOwnership(param, prov.type_id);
                        }
                    }
                }
                if (param.type_annotation) |ann| {
                    break :blk self.resolveParamOwnership(param, self.resolveTypeExpr(ann));
                }
                break :blk .shared;
            };
        }
        return ownerships;
    }

    /// Resolve the declared parameter types for a function by name and arity.
    /// Used to populate CallArg.expected_type for implicit numeric widening.
    fn resolveFunctionParamTypes(self: *HirBuilder, name: ast.StringId, arity: u32) ?[]const types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        const family_id = self.graph.resolveFamily(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return null;
        const clause_ref = family.clauses.items[0];
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];

        const param_types = self.allocator.alloc(types_mod.TypeId, clause.params.len) catch return null;
        for (clause.params, 0..) |param, idx| {
            param_types[idx] = blk: {
                if (param.pattern.* == .bind) {
                    const clause_scope = self.graph.resolveClauseScope(clause.meta) orelse clause.meta.scope_id;
                    if (self.graph.resolveBindingHygienic(clause_scope, param.pattern.bind.name, param.pattern.bind.meta.scopes)) |binding_id| {
                        if (self.graph.bindings.items[binding_id].type_id) |prov| {
                            break :blk prov.type_id;
                        }
                    }
                }
                if (param.type_annotation) |ann| {
                    break :blk self.resolveTypeExpr(ann);
                }
                break :blk types_mod.TypeStore.UNKNOWN;
            };
        }
        return param_types;
    }

    const ResolvedFunctionCall = struct {
        param_types: []const types_mod.TypeId,
        param_ownerships: []const Ownership,
        return_type: types_mod.TypeId,
        clause_index: u32,
    };

    fn resolveCallInScope(self: *HirBuilder, scope_id: scope_mod.ScopeId, name: ast.StringId, arity: u32, args: []const CallArg) ?ResolvedFunctionCall {
        const resolved = self.graph.resolveFamilyAllowingDefaults(scope_id, name, arity) orelse return null;
        const family = self.graph.getFamily(resolved.family_id);
        if (family.clauses.items.len == 0) return null;

        // Single-pass overload selection. We track three pieces of state:
        //   `best`     — the current best ResolvedFunctionCall (lowest cost,
        //                tiebroken by canonical rank)
        //   `best_cost` — its applicability cost
        //   `best_rank` — its canonical-rank score (used only on ties)
        // When a new candidate has strictly lower cost it wins outright;
        // when it ties at cost it wins only if its canonical rank is lower.
        // The canonical rank prefers i64-then-narrower for ints (and
        // f64-then-narrower for floats) when an arg's static type is UNKNOWN,
        // so a type-only multi-overload family (e.g. `Integer.to_string`'s
        // 12 i8…u128 clauses) reliably lands on the natural-width overload
        // instead of whichever clause was declared first. Single-pass keeps
        // the per-call cost linear in the clause count — important because
        // dispatch fires once per `<>` operator (which expands to a
        // `Concatenable.concat` call), and long concat chains otherwise
        // multiply the dispatch work.
        var best: ?ResolvedFunctionCall = null;
        var best_cost: u32 = std.math.maxInt(u32);
        var best_rank: u32 = std.math.maxInt(u32);
        for (family.clauses.items, 0..) |clause_ref, idx| {
            const candidate = self.resolveClauseCallInfo(name, arity, resolved.declared_arity, clause_ref, @intCast(idx)) orelse continue;
            const cost = self.callInfoMatchCost(candidate, args) orelse continue;
            if (best == null or cost < best_cost) {
                best = candidate;
                best_cost = cost;
                best_rank = self.canonicalParamRank(candidate, args);
            } else if (cost == best_cost) {
                const rank = self.canonicalParamRank(candidate, args);
                if (rank < best_rank) {
                    best = candidate;
                    best_rank = rank;
                }
            }
        }

        if (best) |resolved_call| return resolved_call;
        return self.resolveClauseCallInfo(name, arity, resolved.declared_arity, family.clauses.items[0], 0);
    }

    /// Score a candidate by how "canonical" its parameter types are when the
    /// corresponding argument's static type is UNKNOWN. Lower rank wins.
    /// For a known argument the per-parameter contribution is zero — it was
    /// already disambiguated by `callInfoMatchCost`. For UNKNOWN args we
    /// score the expected param type by its distance from the canonical
    /// 64-bit width: i64 = 0, i32 = 64, i8 = 112, i128 = 128. Floats follow
    /// the same shape biased above all ints (256 + dist) so an int overload
    /// beats a float overload at equal width-distance.
    fn canonicalParamRank(self: *const HirBuilder, call_info: ResolvedFunctionCall, args: []const CallArg) u32 {
        var total: u32 = 0;
        const count = @min(call_info.param_types.len, args.len);
        for (args[0..count], call_info.param_types[0..count]) |arg, expected| {
            if (arg.expr.type_id != types_mod.TypeStore.UNKNOWN) continue;
            const expected_t = self.type_store.getType(expected);
            const slot: u32 = switch (expected_t) {
                .int => |int_info| blk: {
                    const bits = @as(i32, int_info.bits);
                    const dist: u32 = @intCast(if (bits >= 64) bits - 64 else 64 - bits);
                    const sign_penalty: u32 = if (int_info.signedness == .signed) 0 else 1;
                    break :blk dist * 2 + sign_penalty;
                },
                .float => |float_info| blk: {
                    const bits = @as(i32, float_info.bits);
                    const dist: u32 = @intCast(if (bits >= 64) bits - 64 else 64 - bits);
                    break :blk @as(u32, 256) + dist;
                },
                else => 1024,
            };
            total +|= slot;
        }
        return total;
    }

    fn resolveCallInStruct(self: *HirBuilder, struct_name: []const u8, name: ast.StringId, arity: u32, args: []const CallArg) ?ResolvedFunctionCall {
        for (self.graph.structs.items) |struct_entry| {
            if (struct_entry.name.parts.len == 0) continue;
            if (!self.structNameMatchesCallQualifier(struct_entry.name, struct_name)) continue;
            return self.resolveCallInScope(struct_entry.scope_id, name, arity, args);
        }
        return null;
    }

    fn resolveClauseCallInfo(
        self: *HirBuilder,
        name: ast.StringId,
        arity: u32,
        declared_arity: u32,
        clause_ref: scope_mod.FunctionClauseRef,
        family_clause_index: u32,
    ) ?ResolvedFunctionCall {
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) return null;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        const param_types = self.allocator.alloc(types_mod.TypeId, clause.params.len) catch return null;
        const param_ownerships = self.allocator.alloc(Ownership, clause.params.len) catch return null;
        for (clause.params, 0..) |param, idx| {
            const param_type = blk: {
                if (param.pattern.* == .bind) {
                    const clause_scope = self.graph.resolveClauseScope(clause.meta) orelse clause.meta.scope_id;
                    if (self.graph.resolveBindingHygienic(clause_scope, param.pattern.bind.name, param.pattern.bind.meta.scopes)) |binding_id| {
                        if (self.graph.bindings.items[binding_id].type_id) |prov| break :blk prov.type_id;
                    }
                }
                if (param.type_annotation) |ann| break :blk self.resolveTypeExpr(ann);
                break :blk types_mod.TypeStore.UNKNOWN;
            };
            param_types[idx] = param_type;
            param_ownerships[idx] = self.resolveParamOwnership(param, param_type);
        }
        var final_param_types = param_types;
        var final_param_ownerships = param_ownerships;
        if (declared_arity != arity) {
            final_param_types = param_types[0..arity];
            final_param_ownerships = param_ownerships[0..arity];
        }
        const return_type = if (clause.return_type) |rt| self.resolveTypeExpr(rt) else types_mod.TypeStore.UNKNOWN;
        _ = name;
        return .{
            .param_types = final_param_types,
            .param_ownerships = final_param_ownerships,
            .return_type = return_type,
            .clause_index = family_clause_index,
        };
    }

    fn callInfoMatchCost(self: *const HirBuilder, call_info: ResolvedFunctionCall, args: []const CallArg) ?u32 {
        var total: u32 = 0;
        const count = @min(call_info.param_types.len, args.len);
        for (args[0..count], call_info.param_types[0..count]) |arg, expected| {
            const cost = self.type_store.callMatchCost(arg.expr.type_id, expected) orelse return null;
            total +|= cost;
        }
        return total;
    }

    fn resolveFunctionValueGroup(self: *const HirBuilder, name: ast.StringId) ?u32 {
        var current: ?scope_mod.ScopeId = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        var found: ?u32 = null;
        while (current) |sid| {
            var it = self.graph.getScope(sid).function_families.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.name != name) continue;
                const group_id = self.family_to_group.get(entry.value_ptr.*) orelse continue;
                if (found != null) return null;
                found = group_id;
            }
            current = self.graph.getScope(sid).parent;
        }
        return found;
    }

    fn buildResolvedFunctionType(self: *HirBuilder, clause: ast.FunctionClause) anyerror!types_mod.TypeId {
        const params = try self.allocator.alloc(types_mod.TypeId, clause.params.len);
        const ownerships = try self.allocator.alloc(Ownership, clause.params.len);
        for (clause.params, 0..) |param, idx| {
            const param_type = if (param.type_annotation) |ann|
                self.resolveTypeExpr(ann)
            else
                types_mod.TypeStore.UNKNOWN;
            params[idx] = param_type;
            ownerships[idx] = self.resolveParamOwnership(param, param_type);
        }

        const return_type = if (clause.return_type) |rt|
            self.resolveTypeExpr(rt)
        else
            types_mod.TypeStore.UNKNOWN;

        return try self.type_store.addFunctionType(params, return_type, ownerships, self.defaultOwnershipForType(return_type));
    }

    fn resolveFunctionValueType(self: *HirBuilder, name: ast.StringId) anyerror!types_mod.TypeId {
        const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
        var current: ?scope_mod.ScopeId = scope_id;
        var found_clause: ?ast.FunctionClause = null;
        while (current) |sid| {
            var it = self.graph.getScope(sid).function_families.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.name != name) continue;
                const family = self.graph.getFamily(entry.value_ptr.*);
                if (family.clauses.items.len == 0) continue;
                const clause_ref = family.clauses.items[0];
                const clause = clause_ref.decl.clauses[clause_ref.clause_index];
                if (found_clause == null) {
                    found_clause = clause;
                }
                // Don't reject duplicates — the first match wins.
                // Duplicates can occur when a function is visible from both
                // the current scope and a parent scope in the chain.
            }
            current = self.graph.getScope(sid).parent;
        }

        if (found_clause) |clause| {
            return try self.buildResolvedFunctionType(clause);
        }

        return types_mod.TypeStore.UNKNOWN;
    }

    fn resolveFunctionRefType(self: *HirBuilder, fr: ast.FunctionRefExpr) anyerror!types_mod.TypeId {
        const scope_id = if (fr.struct_name) |struct_name|
            self.graph.findStructScope(struct_name)
        else
            self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;

        const resolved_scope = scope_id orelse return types_mod.TypeStore.UNKNOWN;
        const family_id = self.graph.resolveFamily(resolved_scope, fr.function, narrowedFunctionArity(fr.arity)) orelse return types_mod.TypeStore.UNKNOWN;
        const family = self.graph.getFamily(family_id);
        if (family.clauses.items.len == 0) return types_mod.TypeStore.UNKNOWN;
        const clause_ref = family.clauses.items[0];
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        return try self.buildResolvedFunctionType(clause);
    }

    fn resolveFunctionRefGroup(self: *const HirBuilder, fr: ast.FunctionRefExpr) ?u32 {
        const scope_id = if (fr.struct_name) |struct_name|
            self.graph.findStructScope(struct_name)
        else
            self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;

        const resolved_scope = scope_id orelse return null;
        const family_id = self.graph.resolveFamily(resolved_scope, fr.function, narrowedFunctionArity(fr.arity)) orelse return null;
        return self.family_to_group.get(family_id);
    }

    fn narrowedFunctionArity(arity: u32) u32 {
        const narrowed: u8 = @truncate(arity);
        return @intCast(narrowed);
    }

    fn resolveFirstClassTypeStructType(self: *HirBuilder) ?types_mod.TypeId {
        const type_name = self.interner.lookupExisting("Type") orelse return null;
        const type_id = self.type_store.name_to_type.get(type_name) orelse return null;
        const typ = self.type_store.getType(type_id);
        if (typ != .struct_type) return null;
        if (typ.struct_type.fields.len != 1) return null;
        const field = typ.struct_type.fields[0];
        if (!std.mem.eql(u8, self.interner.get(field.name), "name")) return null;
        if (field.type_id != types_mod.TypeStore.ATOM) return null;
        return type_id;
    }

    fn resolveFirstClassFunctionStructType(self: *HirBuilder) ?types_mod.TypeId {
        const function_name = self.interner.lookupExisting("Function") orelse return null;
        const function_type_id = self.type_store.name_to_type.get(function_name) orelse return null;
        const function_type = self.type_store.getType(function_type_id);
        if (function_type != .struct_type) return null;
        if (function_type.struct_type.fields.len != 3) return null;

        const type_type_id = self.resolveFirstClassTypeStructType() orelse return null;
        var has_struct = false;
        var has_name = false;
        var has_arity = false;
        for (function_type.struct_type.fields) |field| {
            const field_name = self.interner.get(field.name);
            if (std.mem.eql(u8, field_name, "struct")) {
                if (field.type_id != type_type_id) return null;
                has_struct = true;
            } else if (std.mem.eql(u8, field_name, "name")) {
                if (field.type_id != types_mod.TypeStore.ATOM) return null;
                has_name = true;
            } else if (std.mem.eql(u8, field_name, "arity")) {
                if (field.type_id != types_mod.TypeStore.U8) return null;
                has_arity = true;
            } else {
                return null;
            }
        }
        return if (has_struct and has_name and has_arity) function_type_id else null;
    }

    fn currentStructName(self: *HirBuilder) !?ast.StringId {
        const scope_id = self.current_struct_scope orelse return null;
        for (self.graph.structs.items) |entry| {
            if (entry.scope_id != scope_id) continue;
            return try self.internDottedStructName(entry.name);
        }
        return null;
    }

    fn resolveTypeReferenceName(self: *HirBuilder, struct_name: ast.StructName) !?ast.StringId {
        if (struct_name.parts.len == 0) return null;

        const dotted_name = try self.internDottedStructName(struct_name);
        if (struct_name.parts.len == 1) {
            const text = self.interner.get(dotted_name);
            if (self.type_store.resolveTypeName(text)) |type_id| {
                if (type_id != types_mod.TypeStore.UNKNOWN) return dotted_name;
            }
        }
        if (self.type_store.name_to_type.get(dotted_name) != null) return dotted_name;
        if (struct_name.parts.len == 1 and self.type_store.name_to_type.get(struct_name.parts[0]) != null) {
            return struct_name.parts[0];
        }
        if (self.graph.findStructScope(struct_name) != null) return dotted_name;
        if (self.allow_external_static_references) return dotted_name;
        return null;
    }

    fn structExprFieldValue(self: *const HirBuilder, struct_expr: ast.StructExpr, field_name_text: []const u8) ?*const ast.Expr {
        for (struct_expr.fields) |field| {
            if (std.mem.eql(u8, self.interner.get(field.name), field_name_text)) return field.value;
        }
        return null;
    }

    fn dottedTypeNameToStructName(self: *HirBuilder, type_name: ast.StringId, span: ast.SourceSpan) !ast.StructName {
        const type_name_text = self.interner.get(type_name);
        var parts: std.ArrayList(ast.StringId) = .empty;
        const interner_mut = @constCast(self.interner);
        var iterator = std.mem.splitScalar(u8, type_name_text, '.');
        while (iterator.next()) |part_text| {
            try parts.append(self.allocator, try interner_mut.intern(part_text));
        }
        return .{
            .parts = try parts.toOwnedSlice(self.allocator),
            .span = span,
        };
    }

    fn staticTypeValueName(self: *HirBuilder, expr: *const ast.Expr) !?ast.StringId {
        return switch (expr.*) {
            .struct_ref => |struct_ref| try self.resolveTypeReferenceName(struct_ref.name),
            .struct_expr => |struct_expr| blk: {
                const type_struct_id = self.resolveFirstClassTypeStructType() orelse break :blk null;
                const resolved_type_id = (try self.resolveNominalStructRefType(struct_expr.struct_name)) orelse break :blk null;
                if (resolved_type_id != type_struct_id) break :blk null;
                const name_value = self.structExprFieldValue(struct_expr, "name") orelse break :blk null;
                if (name_value.* != .atom_literal) break :blk null;
                break :blk name_value.atom_literal.value;
            },
            else => null,
        };
    }

    fn staticNonNegativeArityLiteral(expr: *const ast.Expr) ?u32 {
        if (expr.* != .int_literal) return null;
        if (expr.int_literal.value < 0) return null;
        const unsigned_value: u64 = @intCast(expr.int_literal.value);
        return @truncate(unsigned_value);
    }

    const StaticFunctionValue = struct {
        struct_name: ast.StructName,
        function_name: ast.StringId,
        arity: u32,
    };

    fn staticFunctionStructValue(self: *HirBuilder, struct_expr: ast.StructExpr) !?StaticFunctionValue {
        const function_type_id = self.resolveFirstClassFunctionStructType() orelse return null;
        const resolved_type_id = (try self.resolveNominalStructRefType(struct_expr.struct_name)) orelse return null;
        if (resolved_type_id != function_type_id) return null;

        const struct_value = self.structExprFieldValue(struct_expr, "struct") orelse return null;
        const name_value = self.structExprFieldValue(struct_expr, "name") orelse return null;
        const arity_value = self.structExprFieldValue(struct_expr, "arity") orelse return null;
        const target_type_name = (try self.staticTypeValueName(struct_value)) orelse return null;
        if (name_value.* != .atom_literal) return null;
        const raw_arity = staticNonNegativeArityLiteral(arity_value) orelse return null;

        return .{
            .struct_name = try self.dottedTypeNameToStructName(target_type_name, struct_value.getMeta().span),
            .function_name = name_value.atom_literal.value,
            .arity = raw_arity,
        };
    }

    fn buildAtomExpr(self: *HirBuilder, value: ast.StringId, span: ast.SourceSpan) !*const Expr {
        return try self.create(Expr, .{
            .kind = .{ .atom_lit = value },
            .type_id = types_mod.TypeStore.ATOM,
            .span = span,
        });
    }

    fn buildTypeValueExpr(self: *HirBuilder, type_name: ast.StringId, span: ast.SourceSpan) !*const Expr {
        const type_type_id = self.resolveFirstClassTypeStructType() orelse types_mod.TypeStore.UNKNOWN;
        const interner_mut = @constCast(self.interner);
        const name_field = try interner_mut.intern("name");
        const name_value = try self.buildAtomExpr(type_name, span);
        const fields = try self.allocator.alloc(StructFieldInit, 1);
        fields[0] = .{ .name = name_field, .value = name_value };
        return try self.create(Expr, .{
            .kind = .{ .struct_init = .{
                .type_id = type_type_id,
                .fields = fields,
            } },
            .type_id = type_type_id,
            .span = span,
        });
    }

    fn buildFunctionReferenceValueExpr(self: *HirBuilder, fr: ast.FunctionRefExpr) !*const Expr {
        const interner_mut = @constCast(self.interner);
        const struct_field = try interner_mut.intern("struct");
        const name_field = try interner_mut.intern("name");
        const arity_field = try interner_mut.intern("arity");

        const struct_type_name = if (fr.struct_name) |struct_name|
            (try self.resolveTypeReferenceName(struct_name)) orelse try self.internDottedStructName(struct_name)
        else
            (try self.currentStructName()) orelse return try self.create(Expr, .{
                .kind = .nil_lit,
                .type_id = self.resolveFirstClassFunctionStructType() orelse types_mod.TypeStore.UNKNOWN,
                .span = fr.meta.span,
            });

        const fields = try self.allocator.alloc(StructFieldInit, 3);
        fields[0] = .{
            .name = struct_field,
            .value = try self.buildTypeValueExpr(struct_type_name, fr.meta.span),
        };
        fields[1] = .{
            .name = name_field,
            .value = try self.buildAtomExpr(fr.function, fr.meta.span),
        };
        fields[2] = .{
            .name = arity_field,
            .value = try self.create(Expr, .{
                .kind = .{ .int_lit = @intCast(narrowedFunctionArity(fr.arity)) },
                .type_id = types_mod.TypeStore.U8,
                .span = fr.meta.span,
            }),
        };

        const function_type_id = self.resolveFirstClassFunctionStructType() orelse types_mod.TypeStore.UNKNOWN;
        return try self.create(Expr, .{
            .kind = .{ .struct_init = .{
                .type_id = function_type_id,
                .fields = fields,
            } },
            .type_id = function_type_id,
            .span = fr.meta.span,
        });
    }

    fn buildFunctionValueExpr(self: *HirBuilder, group_id: u32, type_id: types_mod.TypeId, span: ast.SourceSpan) anyerror!*const Expr {
        const group_captures = self.group_captures.get(group_id) orelse &.{};
        var capture_values: std.ArrayList(CaptureValue) = .empty;
        for (group_captures) |capture| {
            try capture_values.append(self.allocator, .{
                .expr = (try self.buildBindingReference(capture.name, capture.type_id, span, .empty)) orelse return error.OutOfMemory,
                .ownership = capture.ownership,
            });
        }
        return try self.create(Expr, .{
            .kind = .{ .closure_create = .{
                .function_group_id = group_id,
                .captures = try capture_values.toOwnedSlice(self.allocator),
            } },
            .type_id = type_id,
            .span = span,
        });
    }

    fn isScopeWithinFunctionRoot(self: *const HirBuilder, scope_id: scope_mod.ScopeId) bool {
        const root = self.current_function_root_scope orelse return false;
        var current: ?scope_mod.ScopeId = scope_id;
        while (current) |sid| {
            if (sid == root) return true;
            current = self.graph.getScope(sid).parent;
        }
        return false;
    }

    fn captureIndexForBinding(self: *HirBuilder, binding_id: scope_mod.BindingId) !?u32 {
        const binding = self.graph.bindings.items[binding_id];
        if (self.isScopeWithinFunctionRoot(binding.scope_id)) return null;

        if (self.current_capture_map.get(binding.name)) |idx| return idx;

        const idx: u32 = @intCast(self.current_capture_list.items.len);
        const ownership = if (binding.type_id) |prov| switch (prov.ownership) {
            .shared => Ownership.shared,
            .unique => Ownership.unique,
            .borrowed => Ownership.borrowed,
        } else Ownership.shared;
        try self.current_capture_list.append(self.allocator, .{
            .name = binding.name,
            .type_id = if (binding.type_id) |prov| prov.type_id else types_mod.TypeStore.UNKNOWN,
            .ownership = ownership,
        });
        try self.current_capture_map.put(binding.name, idx);
        return idx;
    }

    /// Build the lowered Expr for a reference to `name`. `reference_scopes`
    /// carries the Flatt-2016 hygiene marks of the source-level identifier
    /// when the caller has a node to extract them from; pass `.empty` for
    /// synthetic references created during lowering (capture closures,
    /// etc.) where there is no user-written identifier whose scope set
    /// would matter — those fall through to the lexical-chain walker via
    /// `resolveBindingHygienic`.
    fn buildBindingReference(
        self: *HirBuilder,
        name: ast.StringId,
        type_id: TypeId,
        span: ast.SourceSpan,
        reference_scopes: scope_mod.ScopeSet,
    ) anyerror!?*const Expr {
        // Elixir-style shadowing: assignment bindings (`name = expr`)
        // shadow parameters of the same name, and the most recent
        // rebinding wins over earlier ones in the same scope. See
        // also `resolveBindingType` — both must agree on resolution.
        // Reverse iteration of `current_assignment_bindings` picks the
        // most recently appended binding, which is the most recent
        // assignment in the lexical sequence of the current block.
        // This is critical for COW-mutable ARC types: an in-place
        // rebinding retains the receiver, so the COW path produces a
        // new buffer bound to a fresh local. Without most-recent-wins
        // resolution, every subsequent reference would silently observe
        // the pre-call parameter, yielding stale reads from the original
        // buffer.
        var assignment_idx = self.current_assignment_bindings.items.len;
        while (assignment_idx > 0) {
            assignment_idx -= 1;
            const binding = self.current_assignment_bindings.items[assignment_idx];
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_param_names, 0..) |param_name, idx| {
            if (param_name) |pn| {
                if (pn == name) {
                    return try self.create(Expr, .{
                        .kind = .{ .param_get = @intCast(idx) },
                        .type_id = type_id,
                        .span = span,
                    });
                }
            }
        }
        for (self.current_tuple_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_struct_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_list_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_cons_tail_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_binary_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_map_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }
        for (self.current_case_bindings.items) |binding| {
            if (binding.name == name) {
                return try self.create(Expr, .{ .kind = .{ .local_get = binding.local_index }, .type_id = type_id, .span = span });
            }
        }

        // Check parent function's assignment bindings — these are variables
        // from the enclosing function that need to be captured, not accessed
        // directly via local_get.
        for (self.parent_assignment_bindings.items) |binding| {
            if (binding.name == name) {
                // Create a capture for this parent binding
                const capture_type = binding.type_id;
                const idx: u32 = @intCast(self.current_capture_list.items.len);
                try self.current_capture_list.append(self.allocator, .{
                    .name = binding.name,
                    .type_id = capture_type,
                    .ownership = .shared,
                });
                try self.current_capture_map.put(binding.name, idx);
                return try self.create(Expr, .{
                    .kind = .{ .capture_get = idx },
                    .type_id = type_id,
                    .span = span,
                });
            }
        }

        if (self.current_clause_scope) |scope_id| {
            if (self.graph.resolveBindingHygienic(scope_id, name, reference_scopes)) |binding_id| {
                const capture_result = try self.captureIndexForBinding(binding_id);
                if (capture_result) |capture_idx| {
                    return try self.create(Expr, .{
                        .kind = .{ .capture_get = capture_idx },
                        .type_id = type_id,
                        .span = span,
                    });
                }
            }
        }

        return null;
    }

    // ============================================================
    // Program lowering
    // ============================================================

    pub fn buildProgram(self: *HirBuilder, program: *const ast.Program) !Program {
        var structs: std.ArrayList(Struct) = .empty;
        for (program.structs) |*mod| {
            const mod_scope = self.graph.findStructScope(mod.name) orelse
                self.graph.prelude_scope;
            self.current_struct_scope = mod_scope;
            try structs.append(self.allocator, try self.buildStruct(mod, mod_scope));
            self.current_struct_scope = null;
        }

        // Group top-level functions by name, merging clauses
        var fn_order: std.ArrayList(ast.StringId) = .empty;
        var fn_groups = std.AutoHashMap(ast.StringId, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
        defer fn_groups.deinit();

        for (program.top_items) |item| {
            const func = switch (item) {
                .function => |f| f,
                .priv_function => |f| f,
                else => continue,
            };
            const entry = try fn_groups.getOrPut(func.name);
            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
                try fn_order.append(self.allocator, func.name);
            }
            try entry.value_ptr.append(self.allocator, func);
        }

        var top_fns: std.ArrayList(FunctionGroup) = .empty;
        for (fn_order.items) |name| {
            if (fn_groups.getPtr(name)) |decls| {
                try top_fns.append(self.allocator, try self.buildMergedFunctionGroup(decls.items, self.graph.prelude_scope));
            }
        }

        // Build impl function groups and place them in the target struct's
        // functions array so cross-struct calls (`Integer.+`) resolve through
        // the normal struct-qualified call path. Each struct compilation
        // pass sees the global impl set; we skip impls whose target isn't in
        // the structs list for this pass to avoid emitting them as orphan
        // root-level functions.
        for (self.graph.impls.items) |impl_entry| {
            var target_struct_idx: ?usize = null;
            for (structs.items, 0..) |mod, idx| {
                if (self.structNamesEqual(mod.name, impl_entry.target_type)) {
                    target_struct_idx = idx;
                    break;
                }
            }
            if (target_struct_idx == null) continue;

            self.current_struct_scope = impl_entry.scope_id;
            const prev_impl = self.current_impl;
            self.current_impl = impl_entry.decl;
            defer self.current_impl = prev_impl;
            // Group impl functions by name (multi-clause merge), local to this impl.
            var impl_fn_order: std.ArrayList(ast.StringId) = .empty;
            var impl_fn_groups = std.AutoHashMap(ast.StringId, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
            defer impl_fn_groups.deinit();
            for (impl_entry.decl.functions) |func| {
                const entry = try impl_fn_groups.getOrPut(func.name);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .empty;
                    try impl_fn_order.append(self.allocator, func.name);
                }
                try entry.value_ptr.append(self.allocator, func);
            }
            var impl_groups: std.ArrayList(FunctionGroup) = .empty;
            for (impl_fn_order.items) |name| {
                if (impl_fn_groups.getPtr(name)) |decls| {
                    const group = try self.buildMergedFunctionGroup(decls.items, impl_entry.scope_id);
                    try impl_groups.append(self.allocator, group);
                }
            }
            self.current_struct_scope = null;

            // Splice impl groups onto the target struct's functions list.
            var combined: std.ArrayList(FunctionGroup) = .empty;
            try combined.appendSlice(self.allocator, structs.items[target_struct_idx.?].functions);
            try combined.appendSlice(self.allocator, impl_groups.items);
            structs.items[target_struct_idx.?].functions = try combined.toOwnedSlice(self.allocator);
        }

        // Build protocol info from scope graph
        var protocol_infos: std.ArrayList(ProtocolInfo) = .empty;
        for (self.graph.protocols.items) |proto| {
            var names: std.ArrayList(ast.StringId) = .empty;
            var arities: std.ArrayList(u32) = .empty;
            for (proto.decl.functions) |sig| {
                try names.append(self.allocator, sig.name);
                try arities.append(self.allocator, @intCast(sig.params.len));
            }
            try protocol_infos.append(self.allocator, .{
                .name = try self.internDottedStructName(proto.name),
                .type_params = proto.decl.type_params,
                .function_names = try names.toOwnedSlice(self.allocator),
                .function_arities = try arities.toOwnedSlice(self.allocator),
            });
        }

        // Build impl info from scope graph
        var impl_infos: std.ArrayList(ImplInfo) = .empty;
        for (self.graph.impls.items) |impl_entry| {
            var group_ids: std.ArrayList(u32) = .empty;
            // Find function groups that were built from this impl.
            // Impl functions are spliced onto the target struct's function list,
            // not emitted as top-level functions.
            for (structs.items) |mod| {
                for (mod.functions) |group| {
                    if (group.scope_id == impl_entry.scope_id) {
                        try group_ids.append(self.allocator, group.id);
                    }
                }
            }
            if (impl_entry.protocol_name.parts.len > 0 and impl_entry.target_type.parts.len > 0) {
                const impl_type_data = try self.resolveImplProtocolTypeData(impl_entry.decl);
                try impl_infos.append(self.allocator, .{
                    .protocol_name = try self.internDottedStructName(impl_entry.protocol_name),
                    .protocol_type_args = impl_type_data.protocol_type_args,
                    .target_struct = try self.internDottedStructName(impl_entry.target_type),
                    .target_type_pattern = impl_type_data.target_type_pattern,
                    .impl_scope_id = impl_entry.scope_id,
                    .function_group_ids = try group_ids.toOwnedSlice(self.allocator),
                });
            }
        }

        return .{
            .structs = try structs.toOwnedSlice(self.allocator),
            .top_functions = try top_fns.toOwnedSlice(self.allocator),
            .protocols = try protocol_infos.toOwnedSlice(self.allocator),
            .impls = try impl_infos.toOwnedSlice(self.allocator),
        };
    }

    fn buildStruct(self: *HirBuilder, mod: *const ast.StructDecl, mod_scope: scope_mod.ScopeId) !Struct {
        // Group struct functions by {name, arity} so that same-name
        // functions with different arities become separate groups.
        const FnGroupKey = struct { name: ast.StringId, arity: u32 };
        var fn_order: std.ArrayList(FnGroupKey) = .empty;
        var fn_groups = std.AutoHashMap(FnGroupKey, std.ArrayList(*const ast.FunctionDecl)).init(self.allocator);
        defer fn_groups.deinit();

        var type_defs: std.ArrayList(TypeDef) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    const arity: u32 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
                    const key = FnGroupKey{ .name = func.name, .arity = arity };
                    const entry = try fn_groups.getOrPut(key);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = .empty;
                        try fn_order.append(self.allocator, key);
                    }
                    try entry.value_ptr.append(self.allocator, func);
                },
                .type_decl => |td| {
                    try type_defs.append(self.allocator, .{
                        .name = td.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .alias,
                    });
                },
                .opaque_decl => |od| {
                    try type_defs.append(self.allocator, .{
                        .name = od.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .opaque_type,
                    });
                },
                .struct_decl => |sd| {
                    try type_defs.append(self.allocator, .{
                        .name = if (sd.name.parts.len > 0) sd.name.parts[0] else 0,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .struct_type,
                    });
                },
                .union_decl => |ed| {
                    try type_defs.append(self.allocator, .{
                        .name = ed.name,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .alias, // enums are emitted directly as type defs
                    });
                },
                else => {},
            }
        }

        // Pre-register all declared function families in family_to_group
        // so that function references like &name/arity can resolve any
        // sibling function regardless of declaration order.
        for (fn_order.items) |key| {
            if (fn_groups.getPtr(key)) |_| {
                if (self.graph.resolveFamily(mod_scope, key.name, key.arity)) |family_id| {
                    if (!self.family_to_group.contains(family_id)) {
                        const pre_id = self.next_group_id;
                        self.next_group_id += 1;
                        try self.family_to_group.put(family_id, pre_id);
                    }
                }
            }
        }

        var functions: std.ArrayList(FunctionGroup) = .empty;
        for (fn_order.items) |key| {
            if (fn_groups.getPtr(key)) |decls| {
                try functions.append(self.allocator, try self.buildMergedFunctionGroup(decls.items, mod_scope));
            }
        }

        return .{
            .name = mod.name,
            .scope_id = mod_scope,
            .functions = try functions.toOwnedSlice(self.allocator),
            .types = try type_defs.toOwnedSlice(self.allocator),
        };
    }

    // ============================================================
    // Function group building
    // ============================================================

    fn buildMergedFunctionGroup(
        self: *HirBuilder,
        decls: []const *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
    ) !FunctionGroup {
        // Reuse a pre-assigned group ID if one exists (from pre-registration),
        // otherwise allocate a new one.
        const arity: u32 = if (decls[0].clauses.len > 0) @intCast(decls[0].clauses[0].params.len) else 0;
        const group_id = blk: {
            if (self.graph.resolveFamily(scope_id, decls[0].name, arity)) |family_id| {
                if (self.family_to_group.get(family_id)) |existing_id| {
                    break :blk existing_id;
                }
                const new_id = self.next_group_id;
                self.next_group_id += 1;
                try self.family_to_group.put(family_id, new_id);
                break :blk new_id;
            }
            const new_id = self.next_group_id;
            self.next_group_id += 1;
            break :blk new_id;
        };

        self.current_function_name = self.interner.get(decls[0].name);
        self.current_function_name_id = decls[0].name;

        const saved_hir_type_var_scope = self.hir_type_var_scope;
        self.hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(self.allocator);
        defer {
            self.hir_type_var_scope.deinit();
            self.hir_type_var_scope = saved_hir_type_var_scope;
        }

        var clauses: std.ArrayList(Clause) = .empty;
        for (decls) |func| {
            for (func.clauses) |clause| {
                try clauses.append(self.allocator, try self.buildClause(&clause));
            }
        }

        const first = decls[0];
        const fallback_span: ast.SourceSpan = if (first.clauses.len > 0) first.clauses[0].meta.span else .{ .start = 0, .end = 0 };
        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = first.name,
            .arity = arity,
            .debug_span = if (clauses.items.len > 0) clauses.items[0].debug_span else fallback_span,
            .is_local = false,
            .captures = &.{},
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = null,
        };
    }

    fn buildFunctionGroup(
        self: *HirBuilder,
        func: *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
        fallback_parent: ?u32,
        is_local: bool,
    ) !FunctionGroup {
        const group_id = self.next_group_id;
        self.next_group_id += 1;

        const arity: u32 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
        if (self.graph.resolveFamily(scope_id, func.name, arity)) |family_id| {
            try self.family_to_group.put(family_id, group_id);
        }

        const saved_function_name = self.current_function_name;
        const saved_function_name_id = self.current_function_name_id;
        self.current_function_name = self.interner.get(func.name);
        self.current_function_name_id = func.name;
        // Phase 3.b: does this function carry the `raises` effect (non-empty
        // inferred/declared row)? If so, a propagating `raise` in its body
        // lowers to `ret_raise`. Resolved from the type store via the stable
        // qualified key built from the owning struct prefix + name + arity.
        const saved_emits_error_union = self.current_function_emits_error_union;
        self.current_function_emits_error_union = self.functionEmitsErrorUnion(func, scope_id, arity);
        const saved_hir_type_var_scope = self.hir_type_var_scope;
        self.hir_type_var_scope = std.StringHashMap(types_mod.TypeId).init(self.allocator);
        defer {
            self.hir_type_var_scope.deinit();
            self.hir_type_var_scope = saved_hir_type_var_scope;
        }
        const saved_next_local = self.next_local;
        const saved_root_scope = self.current_function_root_scope;
        const saved_capture_map = self.current_capture_map;
        const saved_capture_list = self.current_capture_list;
        // Save the enclosing function's parameter signature so that any
        // expressions built AFTER this nested group returns (e.g., the rest
        // of the parent body, including direct calls into this nested
        // closure) still resolve names against the outer params. Without
        // this, `add(10)` inside `make_adder(x)` would lower a reference
        // to `x` against `add`'s param list and synthesise a spurious
        // capture in the parent.
        const saved_param_names = self.current_param_names;
        const saved_param_types = self.current_param_types;
        self.current_function_root_scope = if (func.clauses.len > 0) self.graph.resolveClauseScope(func.clauses[0].meta) else null;
        self.current_capture_map = std.AutoHashMap(ast.StringId, u32).init(self.allocator);
        self.current_capture_list = .empty;

        // Save parent function's local bindings. These need to be available
        // for capture detection — when a closure references a parent's local
        // variable, it should generate a capture_get, not a local_get.
        const saved_assignment_bindings = self.current_assignment_bindings;
        const saved_tuple_bindings = self.current_tuple_bindings;
        const saved_struct_bindings = self.current_struct_bindings;
        const saved_list_bindings = self.current_list_bindings;
        const saved_cons_tail_bindings = self.current_cons_tail_bindings;
        const saved_binary_bindings = self.current_binary_bindings;
        const saved_map_bindings = self.current_map_bindings;
        const saved_case_bindings = self.current_case_bindings;
        // Store parent bindings for capture detection in the nested function
        const saved_parent_bindings = self.parent_assignment_bindings;
        self.parent_assignment_bindings = self.current_assignment_bindings;
        self.current_assignment_bindings = .empty;
        self.current_tuple_bindings = .empty;
        self.current_struct_bindings = .empty;
        self.current_list_bindings = .empty;
        self.current_cons_tail_bindings = .empty;
        self.current_binary_bindings = .empty;
        self.current_map_bindings = .empty;
        self.current_case_bindings = .empty;

        var clauses: std.ArrayList(Clause) = .empty;
        for (func.clauses) |clause| {
            try clauses.append(self.allocator, try self.buildClause(&clause));
        }

        const captures = try self.current_capture_list.toOwnedSlice(self.allocator);
        try self.group_captures.put(group_id, captures);

        // Validate function naming conventions:
        // - Functions ending with ? must return Bool
        // - Functions ending with ! must call raise() or another ! function
        const func_name = self.interner.get(func.name);
        if (func_name.len > 0) {
            const last_char = func_name[func_name.len - 1];
            if (last_char == '?') {
                // ? functions must return Bool
                for (clauses.items) |clause| {
                    if (clause.return_type != types_mod.TypeStore.BOOL and
                        clause.return_type != types_mod.TypeStore.UNKNOWN and
                        clause.return_type != types_mod.TypeStore.ERROR)
                    {
                        try self.errors.append(self.allocator, .{
                            .message = try std.fmt.allocPrint(self.allocator, "function '{s}' ends with '?' but does not return Bool — ? functions must always return Bool", .{func_name}),
                            .span = func.clauses[0].meta.span,
                        });
                        break;
                    }
                }
            }
            if (last_char == '!') {
                // ! functions must call raise() or another ! function
                var has_raise = false;
                for (clauses.items) |clause| {
                    if (self.bodyContainsRaise(clause.body)) {
                        has_raise = true;
                        break;
                    }
                }
                if (!has_raise) {
                    try self.errors.append(self.allocator, .{
                        .message = try std.fmt.allocPrint(self.allocator, "function '{s}' ends with '!' but does not raise — ! functions must call raise() or another ! function", .{func_name}),
                        .span = func.clauses[0].meta.span,
                    });
                }
            }
        }

        self.current_capture_map.deinit();
        self.current_capture_list = saved_capture_list;
        self.current_capture_map = saved_capture_map;
        self.current_function_root_scope = saved_root_scope;
        self.next_local = saved_next_local;
        self.current_function_name = saved_function_name;
        self.current_function_name_id = saved_function_name_id;
        self.current_function_emits_error_union = saved_emits_error_union;
        self.current_param_names = saved_param_names;
        self.current_param_types = saved_param_types;
        self.current_assignment_bindings = saved_assignment_bindings;
        self.current_tuple_bindings = saved_tuple_bindings;
        self.current_struct_bindings = saved_struct_bindings;
        self.current_list_bindings = saved_list_bindings;
        self.current_cons_tail_bindings = saved_cons_tail_bindings;
        self.current_binary_bindings = saved_binary_bindings;
        self.current_map_bindings = saved_map_bindings;
        self.current_case_bindings = saved_case_bindings;
        self.parent_assignment_bindings = saved_parent_bindings;

        const fallback_span: ast.SourceSpan = if (func.clauses.len > 0) func.clauses[0].meta.span else .{ .start = 0, .end = 0 };
        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = func.name,
            .arity = arity,
            .debug_span = if (clauses.items.len > 0) clauses.items[0].debug_span else fallback_span,
            .is_local = is_local,
            .captures = captures,
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = fallback_parent,
        };
    }

    fn firstExecutableSpan(block: *const Block) ?ast.SourceSpan {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| return expr.span,
                .local_set => |local_set| return local_set.value.span,
                .defer_stmt => |defer_node| return defer_node.expr.span,
                .function_group => {},
            }
        }
        return null;
    }

    /// Index of the last `.expr` statement in an AST statement
    /// sequence — i.e. the statement whose value flows out as the
    /// block's result. Returns null when no `.expr` is present (block
    /// is purely assignments / function decls).
    fn lastExprStmtIndex(stmts: []const ast.Stmt) ?usize {
        var index = stmts.len;
        while (index > 0) {
            index -= 1;
            if (stmts[index] == .expr) return index;
        }
        return null;
    }

    /// Check if a HIR block contains a call to raise() or a ! function.
    fn bodyContainsRaise(self: *const HirBuilder, block: *const Block) bool {
        for (block.stmts) |stmt| {
            const expr: ?*const Expr = switch (stmt) {
                .expr => |e| e,
                .local_set => |ls| ls.value,
                .defer_stmt => |defer_node| defer_node.expr,
                .function_group => null,
            };
            if (expr) |e| {
                if (self.exprContainsRaise(e)) return true;
            }
        }
        return false;
    }

    fn exprContainsRaise(self: *const HirBuilder, expr: *const Expr) bool {
        return switch (expr.kind) {
            .call => |call| {
                // Check if this call targets raise() or a ! function
                switch (call.target) {
                    .named => |named| {
                        if (std.mem.eql(u8, named.name, "raise")) return true;
                        if (named.name.len > 0 and named.name[named.name.len - 1] == '!') return true;
                    },
                    .direct => |direct| {
                        // Check if the direct target's name ends with !
                        for (self.graph.families.items) |family| {
                            if (family.id == direct.function_group_id) {
                                const fname = self.interner.get(family.name);
                                if (std.mem.eql(u8, fname, "raise")) return true;
                                if (fname.len > 0 and fname[fname.len - 1] == '!') return true;
                                break;
                            }
                        }
                    },
                    else => {},
                }
                // Also check args recursively
                for (call.args) |arg| {
                    if (self.exprContainsRaise(arg.expr)) return true;
                }
                return false;
            },
            .case => |ce| {
                for (ce.arms) |arm| {
                    if (self.bodyContainsRaise(arm.body)) return true;
                }
                return false;
            },
            .binary => |bo| {
                return self.exprContainsRaise(bo.lhs) or self.exprContainsRaise(bo.rhs);
            },
            .block => |blk| {
                return self.bodyContainsRaise(&blk);
            },
            .branch => |br| {
                if (self.bodyContainsRaise(br.then_block)) return true;
                if (br.else_block) |eb| return self.bodyContainsRaise(eb);
                return false;
            },
            else => false,
        };
    }

    fn buildClause(self: *HirBuilder, clause: *const ast.FunctionClause) !Clause {
        self.next_local = 0;

        // While building an impl block's clauses, pre-populate the
        // type-var scope with the impl's declared type parameters so
        // their occurrences in this clause's signatures resolve to the
        // same fresh TypeVar across params and return type. Mirrors the
        // type checker's pre-population in checkFunctionClause.
        if (self.current_impl) |impl_d| {
            const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
            for (impl_d.type_params) |tp_name_id| {
                const tp_name = self.interner.get(tp_name_id);
                if (!self.hir_type_var_scope.contains(tp_name)) {
                    const fresh = store_ptr.freshVar() catch continue;
                    self.hir_type_var_scope.put(tp_name, fresh) catch {};
                }
            }
        }
        const prev_clause_scope = self.current_clause_scope;
        // Resolve the clause's scope. Prefers `meta.scope_id` (set
        // directly by the collector) over `node_scope_map` so macro-
        // generated clauses with synthetic span 0:0 don't collide.
        self.current_clause_scope = self.graph.resolveClauseScope(clause.meta) orelse self.current_struct_scope orelse clause.meta.scope_id;
        defer self.current_clause_scope = prev_clause_scope;

        // Check for inferred signature from the type checker (populated for
        // generated helpers like __for_N from call-site argument types).
        const inferred_sig = if (self.current_function_name_id) |name_id|
            self.type_store.inferred_signatures.get(name_id)
        else
            null;

        // Track bound names for variable unification. When a bind pattern
        // reuses a name from an earlier parameter, compilePattern converts
        // it to a pin (equality guard) — like Elixir's variable unification.
        self.clause_bound_names.clearRetainingCapacity();

        var params: std.ArrayList(TypedParam) = .empty;
        for (clause.params, 0..) |param, param_idx| {
            const type_id = if (param.type_annotation) |ann|
                self.resolveTypeExpr(ann)
            else if (inferred_sig) |sig| blk: {
                // Use type inferred from call-site argument types
                break :blk if (param_idx < sig.param_types.len)
                    sig.param_types[param_idx]
                else
                    types_mod.TypeStore.UNKNOWN;
            } else types_mod.TypeStore.UNKNOWN;

            // When a struct pattern has no struct_name (parsed from %{...} :: Type),
            // inject the type name from the type annotation
            const match_pattern = blk: {
                if (param.pattern.* == .struct_pattern and param.type_annotation != null) {
                    const sp = param.pattern.struct_pattern;
                    if (sp.struct_name.parts.len == 0) {
                        const ann = param.type_annotation.?;
                        if (ann.* == .name) {
                            var bindings: std.ArrayList(StructFieldBind) = .empty;
                            for (sp.fields) |field| {
                                if (try self.compilePattern(field.pattern)) |p| {
                                    try bindings.append(self.allocator, .{
                                        .field_name = field.name,
                                        .pattern = p,
                                    });
                                }
                            }
                            break :blk try self.create(MatchPattern, .{
                                .struct_match = .{
                                    .type_name = ann.name.name,
                                    .field_bindings = try bindings.toOwnedSlice(self.allocator),
                                },
                            });
                        }
                        // The parser routes `%{key: pat, ...}` into
                        // `.struct_pattern` with empty struct_name (the
                        // syntax is shared with struct destructure). When
                        // the annotation is a map type (`%{K -> V}`), build
                        // a `map_match` so the IR's map-binding extraction
                        // path runs and the fields are looked up by key
                        // rather than as positional struct fields.
                        if (ann.* == .map) {
                            var bindings: std.ArrayList(MapFieldBind) = .empty;
                            for (sp.fields) |field| {
                                if (try self.compilePattern(field.pattern)) |p| {
                                    // Synthesise an atom-literal key
                                    // expression matching the field name.
                                    const key_ast: *ast.Expr = try self.allocator.create(ast.Expr);
                                    key_ast.* = .{ .atom_literal = .{
                                        .meta = .{ .span = sp.meta.span },
                                        .value = field.name,
                                    } };
                                    try bindings.append(self.allocator, .{
                                        .key = key_ast,
                                        .pattern = p,
                                    });
                                }
                            }
                            break :blk try self.create(MatchPattern, .{
                                .map_match = .{
                                    .field_bindings = try bindings.toOwnedSlice(self.allocator),
                                },
                            });
                        }
                    }
                }
                break :blk try self.compilePattern(param.pattern);
            };

            const name = if (param.pattern.* == .bind) param.pattern.bind.name else null;
            const default_expr = if (param.default) |def| try self.buildExpr(def) else null;
            try params.append(self.allocator, .{
                .name = name,
                .type_id = type_id,
                .ownership = self.resolveParamOwnership(param, type_id),
                .pattern = match_pattern,
                .default = default_expr,
            });

            // Record bound names from this parameter so later parameters
            // can detect variable unification (repeated names → pin patterns).
            self.collectBoundNames(param.pattern);
        }

        const return_type = if (clause.return_type) |rt|
            self.resolveTypeExpr(rt)
        else if (inferred_sig) |sig|
            sig.return_type
        else
            types_mod.TypeStore.NEVER;

        // Track param names for var_ref resolution
        var param_names: std.ArrayList(?ast.StringId) = .empty;
        var param_types: std.ArrayList(TypeId) = .empty;
        for (params.items) |p| {
            try param_names.append(self.allocator, p.name);
            try param_types.append(self.allocator, p.type_id);
        }
        self.current_param_names = try param_names.toOwnedSlice(self.allocator);
        self.current_param_types = try param_types.toOwnedSlice(self.allocator);

        // Process tuple patterns to create bindings for destructured variables
        self.current_tuple_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .tuple) {
                    for (pat.tuple, 0..) |sub_pat, elem_idx| {
                        if (sub_pat.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_tuple_bindings.append(self.allocator, .{
                                .name = sub_pat.bind,
                                .param_index = @intCast(param_idx),
                                .element_index = @intCast(elem_idx),
                                .local_index = local_idx,
                            });
                        }
                    }
                }
            }
        }

        // Process struct patterns to create bindings for destructured field variables
        self.current_struct_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .struct_match) {
                    for (pat.struct_match.field_bindings) |fb| {
                        if (fb.pattern.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_struct_bindings.append(self.allocator, .{
                                .name = fb.pattern.bind,
                                .param_index = @intCast(param_idx),
                                .field_name = fb.field_name,
                                .local_index = local_idx,
                                .struct_type = pat.struct_match.type_name,
                            });
                        }
                    }
                }
            }
        }

        // Process list patterns to create bindings for destructured list elements
        self.current_list_bindings = .empty;
        self.current_cons_tail_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .list) {
                    for (pat.list, 0..) |sub_pat, elem_idx| {
                        if (sub_pat.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_list_bindings.append(self.allocator, .{
                                .name = sub_pat.bind,
                                .param_index = @intCast(param_idx),
                                .element_index = @intCast(elem_idx),
                                .local_index = local_idx,
                            });
                        }
                    }
                }
                // Cons patterns [h | t]: register head elements as list bindings
                // and the tail as an assignment binding so the body can reference
                // them via local_get instead of falling through to capture_get.
                if (pat.* == .list_cons) {
                    for (pat.list_cons.heads, 0..) |head_pat, elem_idx| {
                        if (head_pat.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            try self.current_list_bindings.append(self.allocator, .{
                                .name = head_pat.bind,
                                .param_index = @intCast(param_idx),
                                .element_index = @intCast(elem_idx),
                                .local_index = local_idx,
                            });
                        }
                    }
                    if (pat.list_cons.tail.* == .bind) {
                        const tail_local_idx = self.next_local;
                        self.next_local += 1;
                        try self.current_cons_tail_bindings.append(self.allocator, .{
                            .name = pat.list_cons.tail.bind,
                            .param_index = @intCast(param_idx),
                            .start_index = @intCast(pat.list_cons.heads.len),
                            .local_index = tail_local_idx,
                        });
                    }
                }
            }
        }

        // Process binary patterns to create bindings for destructured segments
        self.current_binary_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .binary_match) {
                    for (pat.binary_match.segments, 0..) |seg, seg_idx| {
                        if (seg.pattern) |sub_pat| {
                            if (sub_pat.* == .bind) {
                                // Skip user-discard bindings (`_x`) but
                                // keep `__synth` names — see
                                // `ast.isDiscardBindName` for the
                                // distinction.
                                const name_str = self.interner.get(sub_pat.bind);
                                if (ast.isDiscardBindName(name_str)) continue;
                                const local_idx = self.next_local;
                                self.next_local += 1;
                                try self.current_binary_bindings.append(self.allocator, .{
                                    .name = sub_pat.bind,
                                    .param_index = @intCast(param_idx),
                                    .segment_index = @intCast(seg_idx),
                                    .local_index = local_idx,
                                    .segment = seg,
                                });
                            }
                        }
                    }
                }
            }
        }

        // Process map patterns to create bindings for destructured map fields
        self.current_map_bindings = .empty;
        for (params.items, 0..) |param, param_idx| {
            if (param.pattern) |pat| {
                if (pat.* == .map_match) {
                    for (pat.map_match.field_bindings) |fb| {
                        if (fb.pattern.* == .bind) {
                            const local_idx = self.next_local;
                            self.next_local += 1;
                            const key_hir = try self.buildExpr(fb.key);
                            try self.current_map_bindings.append(self.allocator, .{
                                .name = fb.pattern.bind,
                                .param_index = @intCast(param_idx),
                                .key_expr = key_hir,
                                .local_index = local_idx,
                            });
                        }
                    }
                }
            }
        }

        // Build decision tree for this clause
        const decision = try self.create(Decision, .{
            .success = .{ .bindings = &.{}, .body_index = 0 },
        });

        // Build refinement expression (guard predicate)
        const refinement_expr = if (clause.refinement) |ref| blk: {
            const rexpr = try self.buildExpr(ref);
            if (rexpr.kind == .call) {}
            break :blk rexpr;
        } else null;

        // Build body block (empty for bodyless declarations: protocol sigs, forward decls).
        // When the clause has an explicit return type, feed it as the
        // *expected tail type* so a parametric struct/union literal at
        // the tail can inherit the function's declared instantiation
        // (`pub fn build() -> Box(i64) { %Box{value: 42} }`).
        const body = if (clause.body) |body_stmts|
            try self.buildBlockWithExpectedTail(body_stmts, return_type)
        else
            try self.buildBlock(&.{});

        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .debug_span = firstExecutableSpan(body) orelse clause.meta.span,
            .decision = decision,
            .body = body,
            .refinement = refinement_expr,
            .tuple_bindings = try self.current_tuple_bindings.toOwnedSlice(self.allocator),
            .struct_bindings = try self.current_struct_bindings.toOwnedSlice(self.allocator),
            .list_bindings = try self.current_list_bindings.toOwnedSlice(self.allocator),
            .cons_tail_bindings = try self.current_cons_tail_bindings.toOwnedSlice(self.allocator),
            .binary_bindings = try self.current_binary_bindings.toOwnedSlice(self.allocator),
            .map_bindings = try self.current_map_bindings.toOwnedSlice(self.allocator),
        };
    }

    // ============================================================
    // Pattern compilation (spec §17)
    // ============================================================

    /// Recursively collect all bound variable names from an AST pattern.
    fn collectBoundNames(self: *HirBuilder, pattern: *const ast.Pattern) void {
        switch (pattern.*) {
            .bind => |b| {
                // Don't track user-discard names (`_x`) — they should
                // never participate in pin-style variable unification.
                // Compiler-synthesised `__*` names are unique per
                // generation site and likewise don't unify, so we treat
                // them the same here.
                const name_str = self.interner.get(b.name);
                if (name_str.len > 0 and name_str[0] != '_') {
                    self.clause_bound_names.put(b.name, {}) catch {};
                }
            },
            .list_cons => |lc| {
                for (lc.heads) |h| self.collectBoundNames(h);
                self.collectBoundNames(lc.tail);
            },
            .tuple => |t| {
                for (t.elements) |e| self.collectBoundNames(e);
            },
            .list => |l| {
                for (l.elements) |e| self.collectBoundNames(e);
            },
            .paren => |p| self.collectBoundNames(p.inner),
            else => {},
        }
    }

    fn compilePattern(self: *HirBuilder, pattern: *const ast.Pattern) anyerror!?*const MatchPattern {
        return switch (pattern.*) {
            .wildcard => try self.create(MatchPattern, .wildcard),
            .bind => |b| {
                // Variable unification: if this name was already bound by a
                // previous parameter, emit a pin (equality check) instead of
                // a fresh binding. This implements Elixir-style patterns like
                // `fn foo(x, [x | rest])` where the second `x` must equal the first.
                const name_str = self.interner.get(b.name);
                if (name_str.len > 0 and name_str[0] != '_' and self.clause_bound_names.contains(b.name)) {
                    return try self.create(MatchPattern, .{ .pin = b.name });
                }
                return try self.create(MatchPattern, .{ .bind = b.name });
            },
            .literal => |lit| try self.create(MatchPattern, .{
                .literal = switch (lit) {
                    .int => |v| .{ .int = v.value },
                    .float => |v| .{ .float = v.value },
                    .string => |v| .{ .string = v.value },
                    .atom => |v| .{ .atom = v.value },
                    .bool_lit => |v| .{ .bool_val = v.value },
                    .nil => .nil,
                },
            }),
            .tuple => |t| {
                var elems: std.ArrayList(*const MatchPattern) = .empty;
                for (t.elements) |elem| {
                    if (try self.compilePattern(elem)) |p| {
                        try elems.append(self.allocator, p);
                    }
                }
                return try self.create(MatchPattern, .{
                    .tuple = try elems.toOwnedSlice(self.allocator),
                });
            },
            .list => |l| {
                var elems: std.ArrayList(*const MatchPattern) = .empty;
                for (l.elements) |elem| {
                    if (try self.compilePattern(elem)) |p| {
                        try elems.append(self.allocator, p);
                    }
                }
                return try self.create(MatchPattern, .{
                    .list = try elems.toOwnedSlice(self.allocator),
                });
            },
            .list_cons => |lc| {
                var heads: std.ArrayList(*const MatchPattern) = .empty;
                for (lc.heads) |h| {
                    if (try self.compilePattern(h)) |p| {
                        try heads.append(self.allocator, p);
                    }
                }
                const tail = try self.compilePattern(lc.tail);
                return try self.create(MatchPattern, .{
                    .list_cons = .{
                        .heads = try heads.toOwnedSlice(self.allocator),
                        .tail = tail orelse try self.create(MatchPattern, .wildcard),
                    },
                });
            },
            .pin => |p| try self.create(MatchPattern, .{ .pin = p.name }),
            .paren => |p| self.compilePattern(p.inner),
            .struct_pattern => |sp| {
                // Get the type name from the struct_name (first part)
                // When struct_name is empty, the type comes from param annotation (handled in buildClause)
                const type_name = if (sp.struct_name.parts.len > 0) sp.struct_name.parts[0] else return null;
                var bindings: std.ArrayList(StructFieldBind) = .empty;
                for (sp.fields) |field| {
                    if (try self.compilePattern(field.pattern)) |p| {
                        try bindings.append(self.allocator, .{
                            .field_name = field.name,
                            .pattern = p,
                        });
                    }
                }
                return try self.create(MatchPattern, .{
                    .struct_match = .{
                        .type_name = type_name,
                        .field_bindings = try bindings.toOwnedSlice(self.allocator),
                    },
                });
            },
            .map => |mp| {
                var bindings: std.ArrayList(MapFieldBind) = .empty;
                for (mp.fields) |field| {
                    const value_pat = try self.compilePattern(field.value) orelse continue;
                    try bindings.append(self.allocator, .{
                        .key = field.key,
                        .pattern = value_pat,
                    });
                }
                return try self.create(MatchPattern, .{
                    .map_match = .{
                        .field_bindings = try bindings.toOwnedSlice(self.allocator),
                    },
                });
            },
            .binary => |bin| {
                return try self.create(MatchPattern, .{
                    .binary_match = .{
                        .segments = try self.compileBinarySegments(bin.segments),
                    },
                });
            },
            .tagged_union_variant => |tuv| {
                // The qualifier always has at least 2 parts (base,
                // variant); the parser enforces this invariant.
                const receiver_name = tuv.qualifier.parts[0];
                const variant_name = tuv.qualifier.parts[tuv.qualifier.parts.len - 1];

                const payload: ?*const MatchPattern = if (tuv.payload) |payload_pat|
                    try self.compilePattern(payload_pat)
                else
                    null;

                return try self.create(MatchPattern, .{
                    .tagged_variant_match = .{
                        .receiver_name = receiver_name,
                        .variant_name = variant_name,
                        .payload = payload,
                    },
                });
            },
        };
    }

    fn compileBinarySegments(self: *HirBuilder, segments: []const ast.BinarySegment) ![]const BinaryMatchSegment {
        var result: std.ArrayList(BinaryMatchSegment) = .empty;
        for (segments) |seg| {
            const pattern: ?*const MatchPattern = switch (seg.value) {
                .pattern => |pat| try self.compilePattern(pat),
                .expr => null,
                .string_literal => null,
            };
            const string_lit: ?ast.StringId = switch (seg.value) {
                .string_literal => |s| s,
                else => null,
            };
            try result.append(self.allocator, .{
                .pattern = pattern,
                .type_spec = seg.type_spec,
                .endianness = seg.endianness,
                .size = seg.size,
                .string_literal = string_lit,
            });
        }
        return try result.toOwnedSlice(self.allocator);
    }

    // ============================================================
    // Block building
    // ============================================================

    fn buildBlock(self: *HirBuilder, stmts: []const ast.Stmt) anyerror!*const Block {
        return self.buildBlockWithExpectedTail(stmts, types_mod.TypeStore.UNKNOWN);
    }

    /// Lower a statement block while threading an *expected tail
    /// type* into the lowering of the final `.expr` statement. Used
    /// to feed function-return-type context (or other surrounding
    /// expected-type context) into a parametric struct/union literal
    /// at the tail position so context-driven `.applied` inference
    /// can fire even when the user omitted explicit `(...)` at the
    /// literal. Statements other than the last `.expr` are lowered
    /// with no expected-type pressure — matching the surface-syntax
    /// expectation that only the tail flows out of the block.
    fn buildBlockWithExpectedTail(
        self: *HirBuilder,
        stmts: []const ast.Stmt,
        expected_tail_type: types_mod.TypeId,
    ) anyerror!*const Block {
        var hir_stmts: std.ArrayList(Stmt) = .empty;
        // Inherit outer bindings so variables from enclosing scopes are
        // visible inside block expressions (e.g., macro-expanded quote blocks).
        // Track the entry length so bindings added inside this block are
        // removed on exit — they don't leak to the outer scope.
        const bindings_base_len = self.current_assignment_bindings.items.len;
        defer self.current_assignment_bindings.shrinkRetainingCapacity(bindings_base_len);

        for (stmts) |stmt| {
            switch (stmt) {
                .function_decl => |func| {
                    const group_scope = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
                    const group = try self.buildFunctionGroup(func, group_scope, null, true);
                    const group_ptr = try self.create(FunctionGroup, group);
                    try hir_stmts.append(self.allocator, .{ .function_group = group_ptr });
                },
                else => {},
            }
        }

        // Index of the final `.expr` statement (the one whose value
        // flows out as the block's result) so we can push the
        // expected tail type only around that one statement.
        const tail_expr_index = lastExprStmtIndex(stmts);

        for (stmts, 0..) |stmt, stmt_index| {
            switch (stmt) {
                .expr => |expr| {
                    const apply_expected = tail_expr_index != null and
                        stmt_index == tail_expr_index.? and
                        expected_tail_type != types_mod.TypeStore.UNKNOWN;
                    if (apply_expected) try self.expected_type_stack.append(self.allocator, expected_tail_type);
                    defer if (apply_expected) {
                        _ = self.expected_type_stack.pop();
                    };
                    const hir_expr = try self.buildExpr(expr);
                    try hir_stmts.append(self.allocator, .{ .expr = hir_expr });
                },
                .assignment => |assign| {
                    // For anonymous function assignments, extract the function
                    // group as a separate statement (same as named function_decl)
                    // so the IR can build it properly. The assignment value becomes
                    // just the closure_create expression.
                    const value = if (assign.value.* == .anonymous_function) blk: {
                        const anon = assign.value.anonymous_function;
                        const function_type = try self.resolveFunctionValueType(anon.decl.name);
                        const group_scope = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
                        const group = try self.buildFunctionGroup(anon.decl, group_scope, null, true);
                        const group_ptr = try self.create(FunctionGroup, group);
                        try hir_stmts.append(self.allocator, .{ .function_group = group_ptr });
                        break :blk try self.buildFunctionValueExpr(group.id, function_type, anon.meta.span);
                    } else try self.buildExpr(assign.value);
                    const value_local = self.next_local;
                    self.next_local += 1;
                    // For `name = expr`, record the Zap identifier on the
                    // local_set so the IR builder can emit a `.dbg_var`
                    // referring to the binding's source name (Phase 0
                    // DWARF). Destructured patterns have no single
                    // user-visible name for `value_local`, so `name`
                    // stays null there.
                    const binding_name: ?ast.StringId = if (assign.pattern.* == .bind)
                        assign.pattern.bind.name
                    else
                        null;
                    try hir_stmts.append(self.allocator, .{
                        .local_set = .{ .index = value_local, .value = value, .name = binding_name },
                    });

                    // For `name = expr`, just bind the name to `value_local`.
                    // For destructure patterns ({a,b} = pair, [h|t] = lst,
                    // %Foo{x: x} = p, %{k => v} = m), recursively walk the
                    // pattern and emit one `local_set` per inner bind, each
                    // with an extractor expression that reads from a local
                    // holding the parent compound value.
                    if (assign.pattern.* == .bind) {
                        try self.current_assignment_bindings.append(self.allocator, .{
                            .name = assign.pattern.bind.name,
                            .local_index = value_local,
                            .type_id = value.type_id,
                        });
                    } else {
                        try self.lowerAssignmentDestructure(
                            assign.pattern,
                            value_local,
                            value.type_id,
                            assign.value.getMeta().span,
                            &hir_stmts,
                        );
                    }
                },
                .defer_stmt => |defer_node| {
                    // Phase 2.d: lower the cleanup expression now (so it
                    // type-resolves against the scope where it was written),
                    // but record it as a `defer_stmt` HIR node. The IR
                    // builder does NOT emit it inline — it pushes it onto the
                    // enclosing block's LIFO cleanup stack and re-lowers it at
                    // each scope-exit edge.
                    const hir_expr = try self.buildExpr(defer_node.expr);
                    try hir_stmts.append(self.allocator, .{ .defer_stmt = .{
                        .kind = defer_node.kind,
                        .expr = hir_expr,
                    } });
                },
                .function_decl => {},
                else => {},
            }
        }

        const owned_stmts = try hir_stmts.toOwnedSlice(self.allocator);
        // The block's result type is the last expression's type — same
        // convention every other expression-oriented language uses,
        // and what `case_expr`'s arm-type unifier expects to read so
        // it can propagate a concrete container type back into
        // structurally-empty siblings (`[]`, `%{}`).
        //
        // A trailing `defer`/`errdefer` is never the block's tail value
        // (it is a cleanup statement, not an expression), so the
        // result-type scan walks backward past `defer_stmt` entries to the
        // last value-producing statement.
        var block_result_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
        var result_scan = owned_stmts.len;
        while (result_scan > 0) {
            result_scan -= 1;
            switch (owned_stmts[result_scan]) {
                .expr => |expr| {
                    block_result_type = expr.type_id;
                    break;
                },
                .local_set => |ls| {
                    block_result_type = ls.value.type_id;
                    break;
                },
                .function_group => break,
                .defer_stmt => continue,
            }
        }
        return try self.create(Block, .{
            .stmts = owned_stmts,
            .result_type = block_result_type,
        });
    }

    // ============================================================
    // Expression building
    // ============================================================

    /// Build a HIR `Expr` from an AST `Expr`, then carry over the AST
    /// node's macro-expansion provenance (Phase 2.f GP2). The provenance
    /// is the only thing the dispatch below does not thread through; it is
    /// stamped here, at the single `buildExpr` chokepoint, so every HIR
    /// node produced from a macro-expanded AST node knows its user call
    /// site for debug-line attribution. The `@constCast` is sound: every
    /// arm of `buildExprDispatch` returns a node freshly allocated by
    /// `self.create` in this single-pass builder (HIR is built once, not
    /// shared/cached), so we own the node we are stamping; we only set the
    /// field when the source AST node actually carries expansion info and
    /// the built node has not already been stamped by a deeper expansion.
    fn buildExpr(self: *HirBuilder, expr: *const ast.Expr) anyerror!*const Expr {
        const built = try self.buildExprDispatch(expr);
        if (expr.getMeta().expansion) |info| {
            if (built.expansion == null) {
                @constCast(built).expansion = info;
            }
        }
        return built;
    }

    fn buildExprDispatch(self: *HirBuilder, expr: *const ast.Expr) anyerror!*const Expr {
        return switch (expr.*) {
            .int_literal => |v| try self.create(Expr, .{
                .kind = .{ .int_lit = v.value },
                .type_id = types_mod.TypeStore.I64,
                .span = v.meta.span,
            }),
            .float_literal => |v| try self.create(Expr, .{
                .kind = .{ .float_lit = v.value },
                .type_id = types_mod.TypeStore.F64,
                .span = v.meta.span,
            }),
            .string_literal => |v| try self.create(Expr, .{
                .kind = .{ .string_lit = v.value },
                .type_id = types_mod.TypeStore.STRING,
                .span = v.meta.span,
            }),
            .atom_literal => |v| try self.create(Expr, .{
                .kind = .{ .atom_lit = v.value },
                .type_id = types_mod.TypeStore.ATOM,
                .span = v.meta.span,
            }),
            .bool_literal => |v| try self.create(Expr, .{
                .kind = .{ .bool_lit = v.value },
                .type_id = types_mod.TypeStore.BOOL,
                .span = v.meta.span,
            }),
            .nil_literal => |v| try self.create(Expr, .{
                .kind = .nil_lit,
                .type_id = types_mod.TypeStore.NIL,
                .span = v.meta.span,
            }),
            .var_ref => |v| {
                var resolved_type = self.resolveBindingType(v.name, v.meta.scopes);
                if (resolved_type == types_mod.TypeStore.UNKNOWN) {
                    resolved_type = try self.resolveFunctionValueType(v.name);
                }

                if (self.current_clause_scope != null) {
                    if (try self.buildBindingReference(v.name, resolved_type, v.meta.span, v.meta.scopes)) |ref| {
                        return ref;
                    }
                }
                if (self.resolveFunctionValueGroup(v.name)) |group_id| {
                    return try self.buildFunctionValueExpr(group_id, resolved_type, v.meta.span);
                }
                const name_text = self.interner.get(v.name);
                if (self.type_store.resolveTypeName(name_text)) |type_id| {
                    if (type_id != types_mod.TypeStore.UNKNOWN) {
                        return try self.buildTypeValueExpr(v.name, v.meta.span);
                    }
                }
                // Last-resort fallback when a var_ref didn't resolve to a
                // capture, parameter, named function, or scope-graph binding.
                // Reaching here typically means the type checker accepted a
                // reference that the HIR build path can't ground (e.g. a
                // synthetic helper's parameter not yet in scope). Emit a
                // local_get of slot 0 so downstream code has *something*; the
                // backend will surface any genuine miss as a Zig compile error
                // rather than a silent runtime read of a wrong value.
                return try self.create(Expr, .{
                    .kind = .{ .local_get = 0 },
                    .type_id = resolved_type,
                    .span = v.meta.span,
                });
            },
            .binary_op => |bo| {
                const lhs_expr = try self.buildExpr(bo.lhs);
                const rhs_expr = try self.buildExpr(bo.rhs);

                // Protocol-driven dispatch: when either operand has a known
                // concrete type and the corresponding `impl PROTOCOL for T`
                // exists, lower `a OP b` to a call against the impl's
                // operator function (`Integer.+`, `Float.<`, ...). The
                // mangler turns the operator name into a Zig-safe identifier
                // downstream, and the impl body handles the type-specific
                // runtime path. Otherwise (UNKNOWN operand types, no impl)
                // fall through to the primitive ZIR binary op.
                if (operatorProtocol(bo.op)) |op_meta| {
                    const operand_type: types_mod.TypeId = if (lhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                        lhs_expr.type_id
                    else
                        rhs_expr.type_id;
                    if (operand_type != types_mod.TypeStore.UNKNOWN) {
                        if (self.type_store.typeToStructName(operand_type, self.interner)) |struct_name| {
                            if (self.hasImplByText(op_meta.protocol, struct_name) != null) {
                                var args: std.ArrayList(CallArg) = .empty;
                                try args.append(self.allocator, .{ .expr = lhs_expr, .mode = .share });
                                try args.append(self.allocator, .{ .expr = rhs_expr, .mode = .share });
                                const selected_call_info = if (self.interner.lookupExisting(op_meta.method)) |method_id|
                                    self.resolveCallInStruct(struct_name, method_id, 2, args.items)
                                else
                                    null;

                                return try self.create(Expr, .{
                                    .kind = .{ .call = .{
                                        .target = .{ .named = .{
                                            .struct_name = struct_name,
                                            .name = op_meta.method,
                                            .clause_index = if (selected_call_info) |info| info.clause_index else null,
                                        } },
                                        .args = try args.toOwnedSlice(self.allocator),
                                    } },
                                    .type_id = op_meta.result_type(operand_type),
                                    .span = bo.meta.span,
                                });
                            }
                        }
                    }
                }

                // Derive result type from operands and operator (primitive path).
                const result_type = switch (bo.op) {
                    // Arithmetic: same type as operands
                    .add, .sub, .mul, .div, .rem_op => blk: {
                        if (lhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                            break :blk lhs_expr.type_id;
                        if (rhs_expr.type_id != types_mod.TypeStore.UNKNOWN)
                            break :blk rhs_expr.type_id;
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    // Comparison/logical/membership: Bool
                    .equal, .not_equal, .less, .greater, .less_equal, .greater_equal, .and_op, .or_op, .in_op => types_mod.TypeStore.BOOL,
                    // String concat
                    .concat => types_mod.TypeStore.STRING,
                };
                return try self.create(Expr, .{
                    .kind = .{ .binary = .{
                        .op = bo.op,
                        .lhs = lhs_expr,
                        .rhs = rhs_expr,
                    } },
                    .type_id = result_type,
                    .span = bo.meta.span,
                });
            },
            .unary_op => |uo| blk: {
                const operand = try self.buildExpr(uo.operand);
                const result_type = switch (uo.op) {
                    .negate => operand.type_id,
                    .not_op => types_mod.TypeStore.BOOL,
                };
                break :blk try self.create(Expr, .{
                    .kind = .{ .unary = .{
                        .op = uo.op,
                        .operand = operand,
                    } },
                    .type_id = result_type,
                    .span = uo.meta.span,
                });
            },
            .call => |call| {
                // Check for union variant constructor: Result.Ok("hello")
                // Parsed as call(struct_ref(["Result", "Ok"]), args).
                //
                // Parametric receivers carry resolved type_args on the
                // struct_ref (e.g. `Option(i64).Some(42)`). When
                // present, the literal's TypeId becomes the `.applied`
                // form so per-instantiation type defs and substituted
                // payload types flow through monomorphisation. Bare
                // receivers (`Option.Some(42)` against a non-parametric
                // declaration) keep the existing template-type TypeId.
                if (call.callee.* == .struct_ref and call.args.len >= 1) {
                    const parts = call.callee.struct_ref.name.parts;
                    const type_args = call.callee.struct_ref.type_args;
                    if (parts.len == 2) {
                        if (self.type_store.name_to_type.get(parts[0])) |tid| {
                            const typ = self.type_store.getType(tid);
                            if (typ == .tagged_union) {
                                for (typ.tagged_union.variants) |v| {
                                    if (v.name == parts[1] and v.type_id != null) {
                                        const arg_expr = try self.buildExpr(call.args[0]);
                                        // Three sources for the
                                        // instantiation TypeId (mirrors
                                        // the nullary-variant arm above):
                                        //   1. Explicit type-args on
                                        //      the call's struct_ref
                                        //      (`Option(i64).Some(42)`).
                                        //   2. Context-driven inference
                                        //      from the surrounding
                                        //      `expected_type_stack`
                                        //      (a function return type
                                        //      `pub fn make() ->
                                        //      Option(Atom)` with body
                                        //      `Option.Some(:foo)`).
                                        //   3. Bare template TypeId
                                        //      (concrete tagged-union
                                        //      with no formal type
                                        //      params — `Result.Ok(x)`
                                        //      for a non-parametric
                                        //      `Result`).
                                        const explicit_applied = if (type_args.len > 0)
                                            self.buildAppliedStructLiteralType(tid, type_args)
                                        else
                                            null;
                                        const inferred_applied = if (explicit_applied != null)
                                            null
                                        else
                                            self.inferAppliedFromExpectedType(tid);
                                        const literal_type_id =
                                            explicit_applied orelse inferred_applied orelse tid;
                                        return try self.create(Expr, .{
                                            .kind = .{ .union_init = .{
                                                .union_type_id = literal_type_id,
                                                .variant_name = parts[1],
                                                .value = arg_expr,
                                            } },
                                            .type_id = literal_type_id,
                                            .span = call.meta.span,
                                        });
                                    }
                                }
                            }
                        }
                    }
                }

                var args: std.ArrayList(CallArg) = .empty;
                for (call.args) |arg| {
                    try args.append(self.allocator, .{
                        .expr = try self.buildExpr(arg),
                        .mode = .share,
                    });
                }

                var callee_expr: ?*const Expr = null;
                var selected_call_info: ?ResolvedFunctionCall = null;

                // Check for struct-qualified call: IO.puts(...), Math.square(...)
                // or :zig runtime bridge: :zig.println(...)
                const target: CallTarget = if (call.callee.* == .function_ref) blk: {
                    const fr = call.callee.function_ref;
                    const lookup_arity = narrowedFunctionArity(fr.arity);
                    if (fr.struct_name) |struct_name| {
                        const struct_name_text = self.structNameToString(struct_name);
                        selected_call_info = self.resolveCallInStruct(struct_name_text, fr.function, @intCast(call.args.len), args.items);
                        break :blk .{ .named = .{
                            .struct_name = struct_name_text,
                            .name = self.interner.get(fr.function),
                            .clause_index = if (selected_call_info) |info| info.clause_index else null,
                        } };
                    }

                    const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
                    if (self.graph.resolveFamilyAllowingDefaults(scope_id, fr.function, lookup_arity)) |resolved| {
                        if (self.family_to_group.get(resolved.family_id)) |group_id| {
                            selected_call_info = self.resolveCallInScope(scope_id, fr.function, @intCast(call.args.len), args.items);
                            break :blk .{ .direct = .{
                                .function_group_id = group_id,
                                .clause_index = if (selected_call_info) |info| info.clause_index else null,
                            } };
                        }
                    }
                    break :blk .{ .named = .{
                        .struct_name = null,
                        .name = self.interner.get(fr.function),
                    } };
                } else if (call.callee.* == .struct_expr) blk: {
                    if (try self.staticFunctionStructValue(call.callee.struct_expr)) |function_value| {
                        const struct_scope = self.graph.findStructScope(function_value.struct_name);
                        if (struct_scope) |scope_id| {
                            selected_call_info = self.resolveCallInScope(scope_id, function_value.function_name, @intCast(call.args.len), args.items);
                            if (self.graph.resolveFamilyAllowingDefaults(scope_id, function_value.function_name, narrowedFunctionArity(function_value.arity))) |resolved| {
                                if (self.family_to_group.get(resolved.family_id)) |group_id| {
                                    break :blk .{ .direct = .{
                                        .function_group_id = group_id,
                                        .clause_index = if (selected_call_info) |info| info.clause_index else null,
                                    } };
                                }
                            }
                        }
                        break :blk .{ .named = .{
                            .struct_name = self.structNameToString(function_value.struct_name),
                            .name = self.interner.get(function_value.function_name),
                            .clause_index = if (selected_call_info) |info| info.clause_index else null,
                        } };
                    }
                    callee_expr = try self.buildExpr(call.callee);
                    break :blk .{ .closure = callee_expr.? };
                } else if (call.callee.* == .field_access) blk: {
                    const fa = call.callee.field_access;
                    if (fa.object.* == .struct_ref) {
                        const func_name = self.interner.get(fa.field);
                        const written_struct_name = fa.object.struct_ref.name;
                        const initial_mod = self.structNameToString(written_struct_name);
                        // Protocol-call dispatch: rewrite `Protocol.method(arg, ...)`
                        // to `Impl.method(arg, ...)` when the first arg's type has
                        // a matching impl. Mirrors the binary_op dispatch path so
                        // every protocol-method invocation goes through the same
                        // type-driven lookup. Falls through to the literal struct
                        // name when the call isn't protocol-qualified or the type
                        // is UNKNOWN.
                        const dispatched_mod = if (args.items.len > 0)
                            self.protocolDispatchStruct(written_struct_name, args.items[0].expr.type_id) orelse initial_mod
                        else
                            initial_mod;
                        selected_call_info = self.resolveCallInStruct(dispatched_mod, fa.field, @intCast(call.args.len), args.items);
                        break :blk .{ .named = .{ .struct_name = dispatched_mod, .name = func_name, .clause_index = if (selected_call_info) |info| info.clause_index else null } };
                    }
                    // :zig.function() or :zig.Struct.function() — bridge to Zig runtime
                    if (fa.object.* == .atom_literal) {
                        const atom_name = self.interner.get(fa.object.atom_literal.value);
                        if (std.mem.eql(u8, atom_name, "zig")) {
                            const func_name = self.interner.get(fa.field);
                            break :blk .{ .builtin = func_name };
                        }
                    }
                    // :zig.Struct.function() — chained field access
                    if (fa.object.* == .field_access) {
                        const inner = fa.object.field_access;
                        if (inner.object.* == .atom_literal) {
                            const atom_name = self.interner.get(inner.object.atom_literal.value);
                            if (std.mem.eql(u8, atom_name, "zig")) {
                                // Build "Struct.function" qualified name. For
                                // generic containers (List, Map), encode the
                                // element type from the first arg so the ZIR
                                // backend can instantiate the right
                                // specialization (e.g. `List:str.next` ->
                                // `List(String).next`). Without this, every
                                // List.* call defaulted to `List(i64)`.
                                const mod_part = self.interner.get(inner.field);
                                const func_part = self.interner.get(fa.field);
                                const typed_qualified: ?[]const u8 = blk_t: {
                                    if (args.items.len == 0) break :blk_t null;
                                    if (!(std.mem.eql(u8, mod_part, "List") or std.mem.eql(u8, mod_part, "Map"))) break :blk_t null;
                                    const arg_type = args.items[0].expr.type_id;
                                    if (arg_type == types_mod.TypeStore.UNKNOWN) break :blk_t null;
                                    const t = self.type_store.getType(arg_type);
                                    if (std.mem.eql(u8, mod_part, "List") and t == .list) {
                                        const enc = encodeContainerElemName(self.type_store, t.list.element) orelse break :blk_t null;
                                        break :blk_t std.fmt.allocPrint(self.allocator, "List:{s}.{s}", .{ enc, func_part }) catch null;
                                    }
                                    if (std.mem.eql(u8, mod_part, "Map") and t == .map) {
                                        const k_enc = encodeContainerElemName(self.type_store, t.map.key) orelse break :blk_t null;
                                        const v_enc = encodeContainerElemName(self.type_store, t.map.value) orelse break :blk_t null;
                                        break :blk_t std.fmt.allocPrint(self.allocator, "Map:{s}:{s}.{s}", .{ k_enc, v_enc, func_part }) catch null;
                                    }
                                    break :blk_t null;
                                };
                                if (typed_qualified) |tq| break :blk .{ .builtin = tq };
                                const qualified = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ mod_part, func_part }) catch break :blk .{ .builtin = func_part };
                                break :blk .{ .builtin = qualified };
                            }
                        }
                    }
                    callee_expr = try self.buildExpr(call.callee);
                    break :blk .{ .closure = callee_expr.? };
                } else if (call.callee.* == .var_ref) blk: {
                    // Check if callee is a parameter (function value) or a named function
                    const vr = call.callee.var_ref;
                    var is_param = false;
                    for (self.current_param_names) |param_name| {
                        if (param_name) |pn| {
                            if (pn == vr.name) {
                                is_param = true;
                                break;
                            }
                        }
                    }
                    if (is_param) {
                        callee_expr = try self.buildExpr(call.callee);
                        break :blk .{ .closure = callee_expr.? };
                    }
                    if (self.current_clause_scope != null) {
                        if (try self.buildBindingReference(vr.name, self.resolveBindingType(vr.name, vr.meta.scopes), vr.meta.span, vr.meta.scopes)) |binding_ref| {
                            callee_expr = binding_ref;
                            break :blk .{ .closure = callee_expr.? };
                        }
                    }
                    const scope_id = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
                    if (self.graph.resolveFamily(scope_id, vr.name, @intCast(call.args.len))) |family_id| {
                        if (self.family_to_group.get(family_id)) |group_id| {
                            selected_call_info = self.resolveCallInScope(scope_id, vr.name, @intCast(call.args.len), args.items);
                            break :blk .{ .direct = .{ .function_group_id = group_id, .clause_index = if (selected_call_info) |info| info.clause_index else null } };
                        }
                    }
                    // Check if this bare call resolves to an imported function
                    const import_struct = self.resolveImport(vr.name, @intCast(call.args.len));
                    break :blk .{ .named = .{ .struct_name = import_struct, .name = self.interner.get(vr.name) } };
                } else blk: {
                    callee_expr = try self.buildExpr(call.callee);
                    break :blk .{ .closure = callee_expr.? };
                };

                if (callee_expr) |callee| {
                    self.applyCallArgModes(args.items, callee.type_id);
                }

                // Populate expected_type on each arg for implicit widening.
                // The selected clause decides the expected types: exact
                // overloads are favored first, and widening is only fallback.
                if (selected_call_info) |info| {
                    const count = @min(args.items.len, info.param_types.len);
                    for (args.items[0..count], info.param_types[0..count]) |*arg, param_type| {
                        arg.expected_type = param_type;
                    }
                } else if (call.callee.* == .var_ref) {
                    if (self.resolveFunctionParamTypes(call.callee.var_ref.name, @intCast(call.args.len))) |param_types| {
                        const count = @min(args.items.len, param_types.len);
                        for (args.items[0..count], param_types[0..count]) |*arg, param_type| {
                            arg.expected_type = param_type;
                        }
                    }
                } else if (call.callee.* == .field_access) {
                    // Struct-qualified call: resolve via callee's function type
                    if (callee_expr) |callee| {
                        const callee_type = self.type_store.getType(callee.type_id);
                        if (callee_type == .function) {
                            const count = @min(args.items.len, callee_type.function.params.len);
                            for (args.items[0..count], callee_type.function.params[0..count]) |*arg, param_type| {
                                arg.expected_type = param_type;
                            }
                        }
                    }
                }

                // Propagate expected_type to argument expressions with UNKNOWN type.
                // This is critical for empty list literals ([]) which have no elements
                // to infer from — their type comes from the calling context.
                for (args.items) |*arg| {
                    if (arg.expr.type_id == types_mod.TypeStore.UNKNOWN and arg.expected_type != types_mod.TypeStore.UNKNOWN) {
                        // Check if the expected type is concrete (no type variables)
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                        if (!store_ptr.containsTypeVars(arg.expected_type)) {
                            @constCast(arg.expr).type_id = arg.expected_type;
                        }
                    }
                }

                if (target == .direct) {
                    const group_id = target.direct.function_group_id;
                    const group_captures = self.group_captures.get(group_id) orelse &.{};
                    if (group_captures.len > 0) {
                        var full_args: std.ArrayList(CallArg) = .empty;
                        for (group_captures) |capture| {
                            try full_args.append(self.allocator, .{
                                .expr = (try self.buildBindingReference(capture.name, capture.type_id, call.meta.span, .empty)) orelse return error.OutOfMemory,
                                .mode = switch (capture.ownership) {
                                    .shared => .share,
                                    .unique => .move,
                                    .borrowed => .borrow,
                                },
                            });
                        }
                        for (args.items) |arg| try full_args.append(self.allocator, arg);
                        args.deinit(self.allocator);
                        args = full_args;
                    }
                }

                // Resolve return type for named calls
                const call_return_type: types_mod.TypeId = if (selected_call_info) |info| info.return_type else switch (target) {
                    .direct => blk: {
                        if (call.callee.* == .var_ref) {
                            const raw = self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
                            if (raw != types_mod.TypeStore.UNKNOWN) {
                                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                if (store_ptr.containsTypeVars(raw)) {
                                    break :blk self.resolveGenericReturnTypeLocal(call.callee.var_ref.name, @intCast(call.args.len), args.items, raw);
                                }
                            }
                            break :blk raw;
                        }
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    .named => |n| blk: {
                        if (n.struct_name == null) {
                            if (call.callee.* == .var_ref) {
                                const raw = self.resolveFunctionReturnType(call.callee.var_ref.name, @intCast(call.args.len));
                                if (raw != types_mod.TypeStore.UNKNOWN) {
                                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                    if (store_ptr.containsTypeVars(raw)) {
                                        break :blk self.resolveGenericReturnTypeLocal(call.callee.var_ref.name, @intCast(call.args.len), args.items, raw);
                                    }
                                }
                                break :blk raw;
                            }
                        } else {
                            if (call.callee.* == .field_access) {
                                const raw_return = self.resolveFunctionReturnTypeInStruct(n.struct_name.?, n.name, @intCast(call.args.len));
                                if (raw_return != types_mod.TypeStore.UNKNOWN) {
                                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                    if (store_ptr.containsTypeVars(raw_return)) {
                                        const resolved = self.resolveGenericReturnType(n.struct_name.?, n.name, @intCast(call.args.len), args.items, raw_return);
                                        break :blk resolved;
                                    }
                                }
                                break :blk raw_return;
                            }
                            // Bare-name var_ref (`a + b` rewritten to `+(a, b)`) that
                            // resolves to an imported struct's function. Same inference
                            // as the field_access case.
                            if (call.callee.* == .var_ref) {
                                const raw_return = self.resolveFunctionReturnTypeInStruct(n.struct_name.?, n.name, @intCast(call.args.len));
                                if (raw_return != types_mod.TypeStore.UNKNOWN) {
                                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                                    if (store_ptr.containsTypeVars(raw_return)) {
                                        const resolved = self.resolveGenericReturnType(n.struct_name.?, n.name, @intCast(call.args.len), args.items, raw_return);
                                        break :blk resolved;
                                    }
                                }
                                break :blk raw_return;
                            }
                        }
                        break :blk types_mod.TypeStore.UNKNOWN;
                    },
                    else => types_mod.TypeStore.UNKNOWN,
                };

                if (target == .named and call.callee.* == .var_ref) {
                    const named = target.named;
                    if (named.struct_name == null) {
                        if (if (selected_call_info) |info| info.param_ownerships else self.resolveFunctionParamOwnerships(call.callee.var_ref.name, @intCast(call.args.len))) |ownerships| {
                            const count = @min(args.items.len, ownerships.len);
                            for (args.items[0..count], ownerships[0..count]) |*arg, ownership| {
                                arg.mode = switch (ownership) {
                                    .shared => .share,
                                    .unique => .move,
                                    .borrowed => .borrow,
                                };
                            }
                        }
                    }
                }
                if (target == .direct and call.callee.* == .var_ref) {
                    if (if (selected_call_info) |info| info.param_ownerships else self.resolveFunctionParamOwnerships(call.callee.var_ref.name, @intCast(call.args.len))) |ownerships| {
                        const offset = args.items.len - call.args.len;
                        const count = @min(call.args.len, ownerships.len);
                        for (args.items[offset .. offset + count], ownerships[0..count]) |*arg, ownership| {
                            arg.mode = switch (ownership) {
                                .shared => .share,
                                .unique => .move,
                                .borrowed => .borrow,
                            };
                        }
                    }
                }

                return try self.create(Expr, .{
                    .kind = .{ .call = .{
                        .target = target,
                        .args = try args.toOwnedSlice(self.allocator),
                    } },
                    .type_id = call_return_type,
                    .span = call.meta.span,
                });
            },
            .if_expr => {
                // if_expr should be desugared to case_expr before reaching HIR
                unreachable;
            },
            .case_expr => |ce| {
                const scrutinee = try self.buildExpr(ce.scrutinee);
                var arms: std.ArrayList(CaseArm) = .empty;

                for (ce.clauses) |clause| {
                    // Append THIS clause's pattern bindings to the running
                    // `current_case_bindings` instead of resetting it. A
                    // nested case (e.g. the filter-case the desugarer
                    // emits inside a for-comp's cont arm) still needs the
                    // outer arm's bindings — the user's loop variable and
                    // `__next_state` — visible while building its own
                    // clause bodies. Save the start index, append this
                    // clause's pattern bindings, build the body, snapshot
                    // just this clause's slice for the lowered arm, then
                    // shrink back so siblings see the outer arm's
                    // bindings unchanged.
                    const start_idx = self.current_case_bindings.items.len;

                    const pattern = try self.compilePattern(clause.pattern);

                    // Process bindings from the pattern. Top-level `.bind` is the
                    // whole-scrutinee bind (kind=.scrutinee, set by the success
                    // leaf). Anything nested inside a compound pattern is .extracted
                    // and set by a `.bind` decision-tree node. Binary segments use
                    // .binary_element with their segment index.
                    if (pattern) |pat| {
                        try self.collectCasePatternBindings(pat, true);
                    }

                    // Switch into the clause's scope while building the
                    // guard and body so var_refs to pattern-bound names
                    // (e.g. `c` in `{:cont, c, _} -> c <> "!"`) pick up
                    // the type the type checker recorded on the
                    // case-clause binding. Without this, `resolveBindingType`
                    // walks UP from `current_clause_scope` (the
                    // surrounding function clause's scope) and never
                    // visits the case-clause scope (a child), leaving
                    // the var_ref typed as UNKNOWN — which breaks
                    // first-arg-type-driven protocol dispatch in the
                    // body (`Concatenable.concat`, `Arithmetic.+`, …).
                    const saved_clause_scope = self.current_clause_scope;
                    if (self.graph.resolveClauseScope(clause.meta)) |cs| {
                        self.current_clause_scope = cs;
                    }

                    const guard_expr = if (clause.guard) |g| try self.buildExpr(g) else null;
                    const body = try self.buildBlock(clause.body);

                    self.current_clause_scope = saved_clause_scope;

                    // Snapshot just THIS clause's bindings (those appended
                    // at or after start_idx) so the lowered arm carries
                    // only the bindings introduced by its own pattern.
                    const clause_slice = self.current_case_bindings.items[start_idx..];
                    const bindings = try self.allocator.dupe(CaseBinding, clause_slice);

                    try arms.append(self.allocator, .{
                        .pattern = pattern,
                        .guard = guard_expr,
                        .body = body,
                        .bindings = bindings,
                    });

                    // Drop this clause's bindings; siblings see the outer
                    // arm's bindings as they did before this clause.
                    self.current_case_bindings.shrinkRetainingCapacity(start_idx);
                }

                const arm_slice = try arms.toOwnedSlice(self.allocator);
                // The case's result type is the unified type of its
                // arms. If one arm has a concrete element type (e.g.
                // the for-comp's cont arm produces `[String]`) and
                // another is structurally compatible but stamped
                // UNKNOWN (e.g. the done arm's empty literal `[]`),
                // propagate the concrete shape so downstream cons /
                // list_init monomorphisation doesn't default to i64.
                // Falls back to UNKNOWN when no arm carries a concrete
                // type or when arms disagree concretely (the latter
                // gets caught downstream as a structural mismatch).
                const case_type_id: types_mod.TypeId = blk: {
                    var chosen: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
                    for (arm_slice) |arm| {
                        const t = arm.body.result_type;
                        if (t == types_mod.TypeStore.UNKNOWN) continue;
                        if (chosen == types_mod.TypeStore.UNKNOWN) {
                            chosen = t;
                            continue;
                        }
                        if (chosen != t) {
                            chosen = types_mod.TypeStore.UNKNOWN;
                            break;
                        }
                    }
                    break :blk chosen;
                };
                // When a unified type is known, propagate it back into
                // any arm whose result is structurally compatible but
                // currently UNKNOWN — the canonical case is the done
                // arm's `[]` empty list inside a for-comprehension's
                // cont/done split. Without this patch the IR would
                // emit `list_init(elem=i64)` for `[]` and `list_cons`
                // with String for the cont arm, and Zig sema rejects
                // the union of `?*const List(i64) | ?*const List(String)`.
                if (case_type_id != types_mod.TypeStore.UNKNOWN) {
                    for (arm_slice) |arm| {
                        if (arm.body.result_type == types_mod.TypeStore.UNKNOWN) {
                            self.patchEmptyContainerTypes(arm.body, case_type_id);
                        }
                    }
                }
                return try self.create(Expr, .{
                    .kind = .{ .case = .{
                        .scrutinee = scrutinee,
                        .arms = arm_slice,
                    } },
                    .type_id = case_type_id,
                    .span = ce.meta.span,
                });
            },
            .error_pipe => |ep| {
                return try self.buildErrorPipe(ep);
            },
            .try_expr => |te| {
                return try self.buildTryProject(te);
            },
            .try_rescue => |tr| {
                return try self.buildTryRescue(tr);
            },
            .panic_expr => |pe| try self.create(Expr, .{
                .kind = .{ .panic = try self.buildExpr(pe.message) },
                .type_id = types_mod.TypeStore.NEVER,
                .span = pe.meta.span,
            }),
            .raise_expr => |re| {
                // Phase 1.4: the desugar pass already rewrote `raise <value>`
                // into a `raise_expr` whose `value` is the
                // `Kernel.do_raise(<value>)` call (the Error-aware abort, a
                // `Never`-returning function). The `raise_expr` wrapper only
                // survived desugar so the type-checker could record the
                // raised error type into the inferred `raises` row; HIR
                // lowers it transparently by building the inner call. The
                // call to a `Never` function is the diverging terminator —
                // Zig sees it as noreturn, so no explicit unreachable is
                // needed.
                //
                // Phase 3.a: when this `raise` is lexically inside a
                // `try { … } rescue { … }` body (`try_scope_depth > 0`),
                // route it to the *recoverable* sink `Kernel.recoverable_raise`
                // instead of `do_raise`. That sink stashes the boxed `Error`
                // value into the runtime's raise side-channel and unwinds to
                // the nearest dynamically-enclosing `try` handler (the
                // `setjmp`/`longjmp` landing pad the IR emits at the `try`
                // site) rather than aborting via `crashReport`. Outside any
                // handler scope the original `do_raise` abort path is kept,
                // so an unhandled `raise` still produces the Phase 2 report.
                if (self.try_scope_depth > 0) {
                    if (try self.buildRecoverableRaise(re)) |recoverable| {
                        return recoverable;
                    }
                }
                // Phase 3.b — PROPAGATING raise: not lexically inside a `try`
                // body, but in a function that carries the `raises` effect
                // (its row is non-empty, so it returns an error union). Stash
                // the boxed error into the side-channel and `return
                // error.ZapRaise`, so the error crosses the call boundary to
                // an enclosing `try`/`rescue` rather than aborting here. The
                // lexical case above is unchanged (it falls through to the
                // same function's landing pad); only a raise that must leave
                // the function takes this path.
                if (self.try_scope_depth == 0 and self.current_function_emits_error_union) {
                    if (try self.buildRetRaise(re)) |propagating| {
                        return propagating;
                    }
                }
                // Abort path (`Kernel.do_raise(<value>)`): a `raise` is a
                // diverging terminator, so stamp the lowered expression
                // `Never` regardless of the inner `do_raise` call's surface
                // type. This lets a `raise` in a value-producing tail position
                // — e.g. a re-raise rescue arm `e :: IOError -> raise e`
                // peer-merged against a `… -> "recovered"` sibling, or a
                // `case` arm `_ -> raise err` merged against a `String` arm —
                // coerce to whatever the merge expects, exactly as the
                // recoverable path's `buildRecoverableRaise` already does. The
                // runtime call still diverges (`do_raise` is `Never`-returning
                // and aborts via `crashReport`); this only fixes the HIR type
                // surface so divergent arms unify cleanly.
                const lowered_raise = try self.buildExpr(re.value);
                return try self.create(Expr, .{
                    .kind = lowered_raise.kind,
                    .type_id = types_mod.TypeStore.NEVER,
                    .span = lowered_raise.span,
                });
            },
            .tuple => |t| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (t.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                const built_elems = try elems.toOwnedSlice(self.allocator);
                // Compute the tuple's type_id from its element types when all
                // children have concrete types. This lets downstream list/map
                // inference reason about tuples as proper compound types
                // (essential for keyword lists like `[{:name, "Alice"}, ...]`
                // where the list element is a tuple).
                var all_known = true;
                for (built_elems) |elem| {
                    if (elem.type_id == types_mod.TypeStore.UNKNOWN) {
                        all_known = false;
                        break;
                    }
                }
                const tuple_type_id: types_mod.TypeId = blk: {
                    if (!all_known) break :blk types_mod.TypeStore.UNKNOWN;
                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                    var elem_type_ids = self.allocator.alloc(types_mod.TypeId, built_elems.len) catch break :blk types_mod.TypeStore.UNKNOWN;
                    for (built_elems, 0..) |elem, i| {
                        elem_type_ids[i] = elem.type_id;
                    }
                    break :blk store_ptr.addType(.{ .tuple = .{ .elements = elem_type_ids } }) catch types_mod.TypeStore.UNKNOWN;
                };
                return try self.create(Expr, .{
                    .kind = .{ .tuple_init = built_elems },
                    .type_id = tuple_type_id,
                    .span = t.meta.span,
                });
            },
            .list => |l| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (l.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                const built_elems = try elems.toOwnedSlice(self.allocator);
                const list_type_id = if (built_elems.len > 0)
                    self.inferListElementType(built_elems)
                else
                    types_mod.TypeStore.UNKNOWN;
                return try self.create(Expr, .{
                    .kind = .{ .list_init = built_elems },
                    .type_id = list_type_id,
                    .span = l.meta.span,
                });
            },
            .list_cons_expr => |lce| {
                const head_expr = try self.buildExpr(lce.head);
                const tail_expr = try self.buildExpr(lce.tail);
                // Infer the list expression's element type from the
                // head's type when known. Without this, downstream IR/ZIR
                // monomorphisation defaults the element type to i64,
                // which breaks `[String | rest]` (and any other non-i64
                // element) emitted by the for-comp desugarer.
                const cons_type_id: types_mod.TypeId = blk: {
                    if (head_expr.type_id != types_mod.TypeStore.UNKNOWN) {
                        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                        break :blk store_ptr.addType(.{ .list = .{ .element = head_expr.type_id } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                    if (tail_expr.type_id != types_mod.TypeStore.UNKNOWN) {
                        const tail_typ = self.type_store.getType(tail_expr.type_id);
                        if (tail_typ == .list) break :blk tail_expr.type_id;
                    }
                    break :blk types_mod.TypeStore.UNKNOWN;
                };
                return try self.create(Expr, .{
                    .kind = .{ .list_cons = .{
                        .head = head_expr,
                        .tail = tail_expr,
                    } },
                    .type_id = cons_type_id,
                    .span = lce.meta.span,
                });
            },
            .map => |m| {
                var entries: std.ArrayList(MapEntry) = .empty;
                for (m.fields) |field| {
                    const key = try self.buildExpr(field.key);
                    const value = try self.buildExpr(field.value);
                    try entries.append(self.allocator, .{
                        .key = key,
                        .value = value,
                    });
                }
                const built_entries = try entries.toOwnedSlice(self.allocator);
                // Infer map type by unifying all entry types. If keys (or
                // values) disagree across entries we promote the disagreeing
                // axis to `Term`, so the runtime container instantiates as
                // `Map(K, Term)` and individual values can be wrapped at
                // construction sites. Tuple values are unified component-wise.
                const map_type_id = if (built_entries.len > 0) blk: {
                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                    var key_type = built_entries[0].key.type_id;
                    var val_type = built_entries[0].value.type_id;
                    for (built_entries[1..]) |entry| {
                        if (entry.key.type_id != types_mod.TypeStore.UNKNOWN) {
                            key_type = unifyForCollection(store_ptr, key_type, entry.key.type_id);
                        }
                        if (entry.value.type_id != types_mod.TypeStore.UNKNOWN) {
                            val_type = unifyForCollection(store_ptr, val_type, entry.value.type_id);
                        }
                    }
                    if (key_type != types_mod.TypeStore.UNKNOWN and val_type != types_mod.TypeStore.UNKNOWN) {
                        break :blk store_ptr.addType(.{ .map = .{ .key = key_type, .value = val_type } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                    break :blk types_mod.TypeStore.UNKNOWN;
                } else types_mod.TypeStore.UNKNOWN;
                return try self.create(Expr, .{
                    .kind = .{ .map_init = built_entries },
                    .type_id = map_type_id,
                    .span = m.meta.span,
                });
            },
            .pipe => {
                // Pipe should be desugared before reaching HIR
                unreachable;
            },
            .range => {
                // Range is rewritten to a struct_expr by the desugarer
                // (see desugar.zig). Reaching HIR with a raw `.range` means
                // a code path bypassed desugaring — surface it loudly rather
                // than silently re-desugaring here.
                unreachable;
            },
            .struct_expr => |se| {
                // Resolve struct type from struct name (e.g., %Point{x: 1, y: 2}).
                // `declaration_type_id` is the bare struct/union TypeId
                // (the type checker registered under `name_to_type`).
                // `literal_type_id` is what we record on the HIR node:
                // it's the canonical `.applied { base, args }` form for
                // parametric instantiations (`%Box(i64){...}`) and the
                // bare declaration TypeId for concrete struct literals.
                var declaration_type_id = types_mod.TypeStore.UNKNOWN;
                var literal_type_id = types_mod.TypeStore.UNKNOWN;
                if (se.struct_name.parts.len > 0) {
                    const full_type_name_id = try self.internDottedStructName(se.struct_name);
                    const simple_type_name_id = se.struct_name.parts[se.struct_name.parts.len - 1];
                    const type_name_id = if (self.type_store.name_to_type.get(full_type_name_id) != null)
                        full_type_name_id
                    else
                        simple_type_name_id;
                    if (self.type_store.name_to_type.get(type_name_id)) |tid| {
                        declaration_type_id = tid;
                        literal_type_id = tid;
                    }
                }
                // When the source writes explicit type arguments
                // (`%Box(i64){...}`), thread the canonical `.applied`
                // instantiation TypeId onto the HIR literal. The
                // monomorphizer keys specializations off this form, so
                // missing it would prevent per-instantiation
                // monomorphization of struct/union types.
                if (se.type_args.len > 0 and declaration_type_id != types_mod.TypeStore.UNKNOWN) {
                    literal_type_id = self.buildAppliedStructLiteralType(declaration_type_id, se.type_args);
                } else if (declaration_type_id != types_mod.TypeStore.UNKNOWN) {
                    // Context-driven inference (Phase 1.1.5.c): if the
                    // current context provides an expected `.applied`
                    // matching this declaration, adopt it as the
                    // literal's TypeId so monomorphization sees the
                    // instantiation even when the user omitted `(...)`
                    // at the literal site. Concrete structs (no
                    // formal type params) are unaffected.
                    if (self.inferAppliedFromExpectedType(declaration_type_id)) |inferred| {
                        literal_type_id = inferred;
                    }
                }
                // Build field expressions. For each field, push the
                // field's declared HIR type onto `expected_type_stack`
                // around the `buildExpr` call so context-driven
                // inference (e.g. a bare `Option.None` adopting the
                // field's `Option(i64)` instantiation) can read the
                // expected type. `fieldAccessResultType` does double
                // duty here — its substitution logic carries through
                // parametric struct instantiations so a field declared
                // as `Option(T)` inside `Foo(T)` sees the substituted
                // `Option(i64)` when the literal is `%Foo(i64){...}`.
                var hir_fields: std.ArrayList(StructFieldInit) = .empty;
                for (se.fields) |field| {
                    const expected_field_type = self.fieldAccessResultType(literal_type_id, field.name);
                    const apply_expected = expected_field_type != types_mod.TypeStore.UNKNOWN;
                    if (apply_expected) try self.expected_type_stack.append(self.allocator, expected_field_type);
                    const value = try self.buildExpr(field.value);
                    if (apply_expected) _ = self.expected_type_stack.pop();
                    try hir_fields.append(self.allocator, .{
                        .name = field.name,
                        .value = value,
                    });
                }
                if (se.update_source == null) {
                    try self.appendStructDefaults(&hir_fields, declaration_type_id);
                }
                return try self.create(Expr, .{
                    .kind = .{ .struct_init = .{
                        .type_id = literal_type_id,
                        .fields = try hir_fields.toOwnedSlice(self.allocator),
                    } },
                    .type_id = literal_type_id,
                    .span = se.meta.span,
                });
            },
            .field_access => |fa| {
                // Struct-qualified reference (e.g. Math.square without call parens)
                if (fa.object.* == .struct_ref) {
                    const func_name = self.interner.get(fa.field);
                    const mod_name = self.structNameToString(fa.object.struct_ref.name);

                    // Check if this is an enum variant access (e.g. Color.Red
                    // or IO.Mode.Raw for a dotted-name union)
                    const mod_parts = fa.object.struct_ref.name.parts;

                    // Try to resolve as a union type. For dotted names like IO.Mode,
                    // build the full dotted name and look it up.
                    const resolved_tid: ?types_mod.TypeId = blk: {
                        if (mod_parts.len >= 2) {
                            // Build full dotted name (e.g., "IO.Mode")
                            var name_buf: std.ArrayList(u8) = .empty;
                            for (mod_parts, 0..) |part, i| {
                                if (i > 0) name_buf.append(self.allocator, '.') catch {};
                                name_buf.appendSlice(self.allocator, self.interner.get(part)) catch {};
                            }
                            const interner_mut = @constCast(self.interner);
                            const full_name_id = interner_mut.intern(name_buf.items) catch break :blk null;
                            if (self.type_store.name_to_type.get(full_name_id)) |tid| break :blk tid;
                            // Fall back to last part only
                            if (self.type_store.name_to_type.get(mod_parts[mod_parts.len - 1])) |tid| break :blk tid;
                        } else if (mod_parts.len == 1) {
                            if (self.type_store.name_to_type.get(mod_parts[0])) |tid| break :blk tid;
                        }
                        break :blk null;
                    };

                    if (resolved_tid) |tid| {
                        const typ = self.type_store.getType(tid);
                        if (typ == .tagged_union) {
                            return try self.create(Expr, .{
                                .kind = .{
                                    .field_get = .{
                                        .object = try self.create(Expr, .{
                                            .kind = .nil_lit, // placeholder for enum type ref
                                            .type_id = tid,
                                            .span = fa.object.getMeta().span,
                                        }),
                                        .field = fa.field,
                                    },
                                },
                                .type_id = tid,
                                .span = fa.meta.span,
                            });
                        }
                    }

                    return try self.create(Expr, .{
                        .kind = .{ .call = .{
                            .target = .{ .named = .{ .struct_name = mod_name, .name = func_name } },
                            .args = &.{},
                        } },
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .span = fa.meta.span,
                    });
                }
                // Struct field access (e.g. user.name)
                const object = try self.buildExpr(fa.object);
                if (object.type_id != types_mod.TypeStore.UNKNOWN) {
                    const object_type = self.type_store.getType(object.type_id);
                    if (object_type == .tuple) {
                        const field_name = self.interner.get(fa.field);
                        const tuple_index = std.fmt.parseUnsigned(u32, field_name, 10) catch {
                            return try self.create(Expr, .{
                                .kind = .{ .field_get = .{
                                    .object = object,
                                    .field = fa.field,
                                } },
                                .type_id = types_mod.TypeStore.UNKNOWN,
                                .span = fa.meta.span,
                            });
                        };
                        if (tuple_index < object_type.tuple.elements.len) {
                            return try self.create(Expr, .{
                                .kind = .{ .tuple_index_get = .{
                                    .object = object,
                                    .index = tuple_index,
                                } },
                                .type_id = object_type.tuple.elements[tuple_index],
                                .span = fa.meta.span,
                            });
                        }
                    }
                }
                const field_type = self.fieldAccessResultType(object.type_id, fa.field);
                return try self.create(Expr, .{
                    .kind = .{ .field_get = .{
                        .object = object,
                        .field = fa.field,
                    } },
                    .type_id = field_type,
                    .span = fa.meta.span,
                });
            },
            .unwrap => |ue| {
                const inner = try self.buildExpr(ue.expr);
                return try self.create(Expr, .{
                    .kind = .{ .unwrap = inner },
                    .type_id = inner.type_id,
                    .span = ue.meta.span,
                });
            },
            .block => |blk| {
                const inner = try self.buildBlock(blk.stmts);
                return try self.create(Expr, .{
                    .kind = .{ .block = inner.* },
                    .type_id = inner.result_type,
                    .span = blk.meta.span,
                });
            },
            .type_annotated => |ta| {
                // expr :: Type — lower the inner expression with the annotated type
                const inner = try self.buildExpr(ta.expr);
                const annotated_type = self.resolveTypeExpr(ta.type_expr);
                return try self.create(Expr, .{
                    .kind = inner.kind,
                    .type_id = annotated_type,
                    .span = ta.meta.span,
                });
            },
            .function_ref => |fr| {
                return try self.buildFunctionReferenceValueExpr(fr);
            },
            .anonymous_function => |anon| {
                var function_type = try self.resolveFunctionValueType(anon.decl.name);
                // Fall back to building type from the clause directly if scope lookup fails
                if (function_type == types_mod.TypeStore.UNKNOWN and anon.decl.clauses.len > 0) {
                    function_type = try self.buildResolvedFunctionType(anon.decl.clauses[0]);
                }
                const group_scope = self.current_clause_scope orelse self.current_struct_scope orelse self.graph.prelude_scope;
                const group = try self.buildFunctionGroup(anon.decl, group_scope, null, true);
                const group_ptr = try self.create(FunctionGroup, group);
                const closure_expr = try self.buildFunctionValueExpr(group.id, function_type, anon.meta.span);
                const block = try self.create(Block, .{
                    .stmts = try self.allocator.dupe(Stmt, &.{
                        .{ .function_group = group_ptr },
                        .{ .expr = closure_expr },
                    }),
                    .result_type = function_type,
                });
                return try self.create(Expr, .{
                    .kind = .{ .block = block.* },
                    .type_id = function_type,
                    .span = anon.meta.span,
                });
            },
            .struct_ref => |mr| {
                // Check for enum variant reference:
                //   Color.Red → parts ["Color", "Red"] (type is parts[0], variant is parts[1])
                //   IO.Mode.Raw → parts ["IO", "Mode", "Raw"] (type is "IO.Mode", variant is "Raw")
                if (mr.name.parts.len >= 2) {
                    const variant_name = mr.name.parts[mr.name.parts.len - 1];
                    // Build the type name from all parts except the last (the variant)
                    const type_tid: ?types_mod.TypeId = blk: {
                        // Try just the penultimate part (e.g., "Color" from Color.Red)
                        const simple_name = mr.name.parts[mr.name.parts.len - 2];
                        if (self.type_store.name_to_type.get(simple_name)) |tid| break :blk tid;
                        // Try the full dotted prefix (e.g., "IO.Mode" from IO.Mode.Raw)
                        if (mr.name.parts.len >= 3) {
                            var name_buf: std.ArrayList(u8) = .empty;
                            for (mr.name.parts[0 .. mr.name.parts.len - 1], 0..) |part, i| {
                                if (i > 0) name_buf.append(self.allocator, '.') catch {};
                                name_buf.appendSlice(self.allocator, self.interner.get(part)) catch {};
                            }
                            const interner_mut = @constCast(self.interner);
                            const full_name_id = interner_mut.intern(name_buf.items) catch break :blk null;
                            if (self.type_store.name_to_type.get(full_name_id)) |tid| break :blk tid;
                        }
                        break :blk null;
                    };
                    if (type_tid) |tid| {
                        const typ = self.type_store.getType(tid);
                        if (typ == .tagged_union) {
                            // Three sources of the instantiation TypeId
                            // for a nullary variant construction:
                            //
                            //   1. **Explicit type-args.**
                            //      `Option(i64).None` lands here with
                            //      `mr.type_args = [i64]`. Build the
                            //      `.applied {Option, [i64]}` TypeId.
                            //
                            //   2. **Context-driven inference.** A bare
                            //      `Option.None` written where the
                            //      surrounding context supplies an
                            //      expected `.applied` form whose base
                            //      matches `tid` (e.g. a struct field
                            //      declared as `cause :: Option(Error)`,
                            //      a function return type
                            //      `pub fn foo() -> Option(i64)`, a
                            //      pattern arm with an annotated
                            //      scrutinee). Adopt the expected
                            //      `.applied` TypeId so monomorphization
                            //      sees the instantiation and the IR
                            //      layer routes through the per-
                            //      instantiation TypeDef.
                            //
                            //   3. **Concrete enum / unit-only union.**
                            //      `Color.Red` for a non-parametric
                            //      `tagged_union` with no formal type
                            //      params — keep the bare declaration
                            //      TypeId. These lower via the
                            //      `field_get` enum-literal path and
                            //      coerce against the union via
                            //      Sema's enum-to-tag inference.
                            //
                            // Cases 1 and 2 always emit `union_init`
                            // (the synthetic-file union(enum) requires
                            // explicit `@unionInit` — Sema rejects a
                            // bare `.None` against a union type
                            // without a tag). Case 3 keeps the
                            // legacy `field_get` shape.
                            const explicit_applied = if (mr.type_args.len > 0)
                                self.buildAppliedStructLiteralType(tid, mr.type_args)
                            else
                                null;
                            const inferred_applied = if (explicit_applied != null)
                                null
                            else
                                self.inferAppliedFromExpectedType(tid);
                            const applied_type_id: ?types_mod.TypeId =
                                explicit_applied orelse inferred_applied;

                            if (applied_type_id) |literal_type_id| {
                                // Parametric tagged unions emit a synthetic
                                // top-level `union(enum)` per instantiation
                                // (Step 3.6 in zir_builder), so even unit
                                // variants must materialise as
                                // `@unionInit(<Instantiation>, "<Variant>", {})`
                                // rather than a bare enum literal. The void
                                // payload uses a synthesized nil_lit at the
                                // union's TypeId (carries through the ARC
                                // analyses, which expect a typed value).
                                const void_payload = try self.create(Expr, .{
                                    .kind = .nil_lit,
                                    .type_id = types_mod.TypeStore.NIL,
                                    .span = mr.meta.span,
                                });
                                return try self.create(Expr, .{
                                    .kind = .{ .union_init = .{
                                        .union_type_id = literal_type_id,
                                        .variant_name = variant_name,
                                        .value = void_payload,
                                    } },
                                    .type_id = literal_type_id,
                                    .span = mr.meta.span,
                                });
                            }

                            // Concrete (non-parametric) tagged union:
                            // emit `field_get` enum-literal shape and
                            // ride the existing pattern-match coercion
                            // path. The literal TypeId is the bare
                            // declaration TypeId.
                            return try self.create(Expr, .{
                                .kind = .{
                                    .field_get = .{
                                        .object = try self.create(Expr, .{
                                            .kind = .nil_lit, // placeholder for enum type ref
                                            .type_id = tid,
                                            .span = mr.meta.span,
                                        }),
                                        .field = variant_name,
                                    },
                                },
                                .type_id = tid,
                                .span = mr.meta.span,
                            });
                        }
                    }
                }
                if (try self.resolveTypeReferenceName(mr.name)) |type_name| {
                    return try self.buildTypeValueExpr(type_name, mr.meta.span);
                }
                return try self.create(Expr, .{
                    .kind = .nil_lit,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = mr.meta.span,
                });
            },
            else => {
                const meta = expr.getMeta();
                return try self.create(Expr, .{
                    .kind = .nil_lit,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });
            },
        };
    }

    // ============================================================
    // Error pipe lowering
    // ============================================================

    /// Build the realized `?` propagation operator (`value?`) into an
    /// `ExprKind.try_project` HIR node. The operand's HIR `type_id` is the
    /// concrete `Result(T, E)` instantiation (a `.tagged_union`, or an
    /// `.applied { base: <Result decl>, args }` when the operand is a
    /// monomorphic call whose declared return type carries the args). The
    /// IR builder lowers `try_project` to a `union_switch`: the `Ok(v)`
    /// prong yields `v` (the expression's value, an `Ok`-payload-typed
    /// result), and the `Error(e)` prong re-wraps `Result(T, E).Error(e)`
    /// and `ret`-terminates to early-return the enclosing function.
    ///
    /// The Ok/Error variant names are discovered structurally from the
    /// resolved tagged union rather than hardcoded, so the lowering does
    /// not bake any stdlib `Result` knowledge into the compiler.
    /// Build a `try { body } rescue { pat -> … } after { … }` handler
    /// (Phase 3.a). The `body` lowers with `try_scope_depth` incremented so
    /// any `raise %E{}` inside it takes the recoverable path (unwinds to the
    /// rescue handler) rather than aborting. The rescue arms reuse the
    /// `case`-arm machinery, matching against `error_local` — the local that
    /// the IR lowering binds the unwound `Error` value to.
    fn buildTryRescue(self: *HirBuilder, tr: ast.TryRescueExpr) anyerror!*const Expr {
        // Allocate the local that holds the raised Error value inside the
        // rescue arms.
        const error_local = self.next_local;
        self.next_local += 1;

        // Build the `try` body with the handler scope active.
        self.try_scope_depth += 1;
        const body = try self.buildBlock(tr.body);
        self.try_scope_depth -= 1;

        // Build the rescue arms. They pattern-match the raised Error value
        // (bound to `error_local`). This mirrors the `case_expr` lowering:
        // each arm gets its own pattern bindings, scoped guard+body, and a
        // snapshot of just-this-arm's bindings.
        //
        // Phase 3.a (#185): alongside each arm we compute a
        // `RescueDiscriminator` from the clause's pattern + `:: Type`
        // annotation. The IR's `lowerRescueDispatch` reads it to gate each
        // type-discriminating arm behind a `protocol_box_vtable_eq` runtime
        // type test against the raised `Error` box — so multi-clause
        // `rescue` dispatches on the boxed error's *real* concrete type
        // instead of always taking the first arm. A catch-all clause (`_`,
        // a bare bind `e`, or `e :: <Protocol>`) matches any box untested.
        var arms: std.ArrayList(CaseArm) = .empty;
        var discriminators: std.ArrayList(RescueDiscriminator) = .empty;
        var has_user_catch_all = false;
        for (tr.rescue_clauses) |clause| {
            const start_idx = self.current_case_bindings.items.len;
            const pattern = try self.compilePattern(clause.pattern);
            if (pattern) |pat| {
                try self.collectCasePatternBindings(pat, true);
            }

            const saved_clause_scope = self.current_clause_scope;
            if (self.graph.resolveClauseScope(clause.meta)) |cs| {
                self.current_clause_scope = cs;
            }
            const guard_expr = if (clause.guard) |g| try self.buildExpr(g) else null;
            const arm_body = try self.buildBlock(clause.body);
            self.current_clause_scope = saved_clause_scope;

            const clause_slice = self.current_case_bindings.items[start_idx..];
            const bindings = try self.allocator.dupe(CaseBinding, clause_slice);
            try arms.append(self.allocator, .{
                .pattern = pattern,
                .guard = guard_expr,
                .body = arm_body,
                .bindings = bindings,
            });
            const discriminator = self.rescueDiscriminatorForClause(clause);
            // A guard makes even a catch-all-shaped arm conditional, so it
            // can never be the total fallback; only an unguarded catch-all
            // discharges the re-raise obligation.
            if (discriminator == .catch_all and clause.guard == null) {
                has_user_catch_all = true;
            }
            try discriminators.append(self.allocator, discriminator);
            self.current_case_bindings.shrinkRetainingCapacity(start_idx);
        }

        // Phase 3.a (#185) "unrescued types propagate" rule: when the user
        // did not write a total catch-all, append a synthetic final arm
        // that re-raises the recovered `Error`. Building it as
        // `__rescue_unmatched__ -> raise __rescue_unmatched__` reuses the
        // ordinary `raise` lowering verbatim — inside an enclosing `try`
        // it routes to `recoverable_raise` (propagates to the outer
        // handler); at top level it routes to `do_raise` (the Phase 2
        // crash report). The IR dispatch makes this arm the terminal
        // `else`, so an error matching none of the user arms is never
        // silently swallowed.
        if (!has_user_catch_all) {
            try self.appendRescueReraiseArm(&arms, &discriminators, tr.meta);
        }

        const arm_slice = try arms.toOwnedSlice(self.allocator);
        const discriminator_slice = try discriminators.toOwnedSlice(self.allocator);

        // Build the optional `after` (finally) block.
        const after_block: ?*const Block = if (tr.after_block) |cleanup|
            try self.buildBlock(cleanup)
        else
            null;

        // Pre-build the runtime landing-pad calls: `Kernel.raise_occurred()`
        // (the body-vs-handler discriminator) and `Kernel.take_recoverable_raise()`
        // (recovers + clears the side-channel Error value for the arms).
        const raise_occurred_call = try self.buildKernelZeroArgCall("raise_occurred", tr.meta);
        const take_raise_call = try self.buildKernelZeroArgCall("take_recoverable_raise", tr.meta);

        // The result type is the join of the body's success type and the
        // rescue arms' result types (computed the same way the type checker's
        // `.try_rescue` arm does in src/types.zig). A `NEVER` body type (the
        // body unconditionally raises — its tail is a `Never`-stamped
        // recoverable raise) or a `NIL`/`UNKNOWN` body type is *absorbable*:
        // the join settles on the first concrete arm type. This mirrors the
        // type checker's discharge rule (`result_type == NIL or UNKNOWN ->
        // adopt clause type`) so HIR and the type checker agree, and — crucially
        // — so `lowerTryRescue` receives the true joined type (e.g. `String`)
        // rather than `UNKNOWN`, which it needs to coerce the normal-completion
        // (else) branch of the landing-pad `if` to the same peer type as the
        // rescue arms.
        var result_type: types_mod.TypeId = body.result_type;
        for (arm_slice) |arm| {
            const t = arm.body.result_type;
            // A `NEVER`/`UNKNOWN` arm contributes no value type to the peer
            // join: a diverging arm — a user `e :: X -> raise e` re-raise, or
            // the synthesized re-raise catch-all (#185) — never yields a
            // value, so it must NOT collapse the join to `UNKNOWN`. Skipping
            // both lets the join settle on the value-producing arms' type
            // (e.g. `String`), which `lowerRescueDispatch` then uses to
            // coerce the divergent arms' dead merge edges.
            if (t == types_mod.TypeStore.UNKNOWN or t == types_mod.TypeStore.NEVER) continue;
            if (result_type == types_mod.TypeStore.UNKNOWN or
                result_type == types_mod.TypeStore.NIL or
                result_type == types_mod.TypeStore.NEVER)
            {
                result_type = t;
                continue;
            }
            if (result_type != t) {
                result_type = types_mod.TypeStore.UNKNOWN;
                break;
            }
        }

        return try self.create(Expr, .{
            .kind = .{ .try_rescue = .{
                .body = body,
                .arms = arm_slice,
                .error_local = error_local,
                .raise_occurred_call = raise_occurred_call,
                .take_raise_call = take_raise_call,
                .after_block = after_block,
                .result_type_id = result_type,
                .arm_discriminators = discriminator_slice,
            } },
            .type_id = result_type,
            .span = tr.meta.span,
        });
    }

    /// Classify how a single `rescue` clause matches the raised `Error` box
    /// at runtime (Phase 3.a, #185). Drives whether the IR dispatch gates
    /// the arm behind a `protocol_box_vtable_eq` test:
    ///
    ///   * `_` (wildcard) or a bare bind `e` with no `:: Type`  -> catch-all.
    ///   * `e :: <Protocol>` where the annotation names the protocol the box
    ///     already carries (e.g. `Error`)                       -> catch-all
    ///     (the existential already satisfies it; no downcast).
    ///   * `e :: ConcreteError`                                 -> concrete,
    ///     no unbox (the binding stays the boxed `Error` so the body's
    ///     `raise e` / `Error.method(e)` still sees an `Error`).
    ///   * `%ConcreteError{...}` struct pattern                 -> concrete,
    ///     needs_unbox (its fields are read off the downcast concrete value).
    fn rescueDiscriminatorForClause(self: *HirBuilder, clause: ast.CaseClause) RescueDiscriminator {
        // A struct pattern always names a concrete type and binds fields off
        // the concrete value, so it requires the downcast.
        if (clause.pattern.* == .struct_pattern) {
            const sp = clause.pattern.struct_pattern;
            if (sp.struct_name.parts.len > 0) {
                const target = self.interner.get(sp.struct_name.parts[sp.struct_name.parts.len - 1]);
                return .{ .concrete = .{ .target_type_name = target, .needs_unbox = true } };
            }
            return .catch_all;
        }

        // A wildcard `_` matches any box.
        if (clause.pattern.* == .wildcard) return .catch_all;

        // A bind `e` is a catch-all unless qualified by `:: ConcreteType`.
        if (clause.pattern.* == .bind) {
            const annotation = clause.type_annotation orelse return .catch_all;
            // Resolve the annotation's leading type name. A bare named type
            // (`IOError`, `Error`) is what a rescue annotation is in
            // practice; anything more complex (applied, function type) is
            // not a concrete error impl, so treat it as a catch-all.
            const type_name = self.leadingTypeName(annotation) orelse return .catch_all;
            const type_struct_name: ast.StructName = .{
                .parts = &[_]ast.StringId{type_name},
                .span = .{ .start = 0, .end = 0 },
            };
            // `e :: <Protocol>` (the existential the box already carries)
            // matches any box: no downcast.
            if (self.isProtocolName(type_struct_name)) return .catch_all;
            // `e :: ConcreteError`: gate on the runtime type, bind the box.
            return .{ .concrete = .{ .target_type_name = self.interner.get(type_name), .needs_unbox = false } };
        }

        // Any other pattern shape (literal, tuple, …) is not a meaningful
        // rescue discriminator; treat as catch-all so the dispatch stays
        // total and the type checker's exhaustiveness pass owns diagnostics.
        return .catch_all;
    }

    /// Extract the type identifier of a `TypeExpr` when it is a bare named
    /// type (`IOError`, `Error`). Returns its interned id, or null for
    /// non-named type expressions (applied, function, tuple, …). Used by
    /// `rescueDiscriminatorForClause` to resolve a `:: Type` annotation to a
    /// concrete error name / protocol name.
    fn leadingTypeName(self: *HirBuilder, type_expr: *const ast.TypeExpr) ?ast.StringId {
        switch (type_expr.*) {
            .name => |named| return named.name,
            .paren => |paren| return self.leadingTypeName(paren.inner),
            else => return null,
        }
    }

    /// Append the synthetic re-raise catch-all arm (Phase 3.a, #185).
    /// Builds `__rescue_unmatched__ -> raise __rescue_unmatched__` through
    /// the ordinary `raise` lowering: the binding resolves to the recovered
    /// `Error` box (the IR dispatch wires the bind local to `error_local`),
    /// and the `raise` re-raises it — recoverable when nested in an
    /// enclosing `try`, aborting via the crash report at top level. The arm
    /// carries a `catch_all` discriminator so the IR dispatch emits it as
    /// the terminal `else` with no runtime type test.
    fn appendRescueReraiseArm(
        self: *HirBuilder,
        arms: *std.ArrayList(CaseArm),
        discriminators: *std.ArrayList(RescueDiscriminator),
        meta: ast.NodeMeta,
    ) anyerror!void {
        const interner_mut = @constCast(self.interner);
        const bind_name = try interner_mut.intern("__rescue_unmatched__");

        // The bind pattern, registered as a top-level (scrutinee) case
        // binding so a `var_ref` to it inside the arm body resolves to the
        // recovered box via `buildBindingReference`'s `current_case_bindings`
        // lookup, and the IR dispatch wires its local to `error_local`.
        const start_idx = self.current_case_bindings.items.len;
        const bind_pattern = try self.create(MatchPattern, .{ .bind = bind_name });
        try self.collectCasePatternBindings(bind_pattern, true);

        // The body: `raise __rescue_unmatched__`. Build the AST `raise`
        // (whose value is `Kernel.do_raise(<var>)`, exactly what the desugar
        // produces for a user `raise e`) and lower it through `buildExpr` so
        // the recoverable-vs-abort selection (`try_scope_depth`) and the
        // `Never`-stamping fire identically to a hand-written re-raise arm.
        const var_ref = try self.create(ast.Expr, .{
            .var_ref = .{ .meta = meta, .name = bind_name },
        });
        const do_raise_call = try self.buildDoRaiseCallForReraise(var_ref, meta);
        const raise_ast = try self.create(ast.Expr, .{
            .raise_expr = .{ .meta = meta, .value = do_raise_call },
        });
        const raise_stmt = try self.allocator.alloc(ast.Stmt, 1);
        raise_stmt[0] = .{ .expr = raise_ast };
        const arm_body = try self.buildBlock(raise_stmt);

        const clause_slice = self.current_case_bindings.items[start_idx..];
        const bindings = try self.allocator.dupe(CaseBinding, clause_slice);
        try arms.append(self.allocator, .{
            .pattern = bind_pattern,
            .guard = null,
            .body = arm_body,
            .bindings = bindings,
        });
        try discriminators.append(self.allocator, .catch_all);
        self.current_case_bindings.shrinkRetainingCapacity(start_idx);
    }

    /// Build the `Kernel.do_raise(<value>)` AST call the synthetic re-raise
    /// arm's `raise_expr` wraps. Mirrors the desugar's `buildDoRaiseCall`
    /// for an `Error`-typed value: `raise <value>` desugars to
    /// `Kernel.do_raise(<value>)`, which the HIR `raise_expr` arm then
    /// routes to the recoverable sink inside a `try` scope.
    fn buildDoRaiseCallForReraise(self: *HirBuilder, value: *const ast.Expr, meta: ast.NodeMeta) anyerror!*const ast.Expr {
        const interner_mut = @constCast(self.interner);
        const kernel_name = try interner_mut.intern("Kernel");
        const do_raise_name = try interner_mut.intern("do_raise");
        const kernel_parts = try self.allocator.dupe(ast.StringId, &.{kernel_name});
        const kernel_ref = try self.create(ast.Expr, .{
            .struct_ref = .{ .meta = meta, .name = .{ .parts = kernel_parts, .span = meta.span } },
        });
        const callee = try self.create(ast.Expr, .{
            .field_access = .{ .meta = meta, .object = kernel_ref, .field = do_raise_name },
        });
        const args = try self.allocator.dupe(*const ast.Expr, &.{value});
        return try self.create(ast.Expr, .{
            .call = .{ .meta = meta, .callee = callee, .args = args },
        });
    }

    /// Build and lower a zero-argument `Kernel.<name>()` call to HIR. Used
    /// to synthesize the `try`/`rescue` landing-pad helper calls
    /// (`raise_occurred`, `take_recoverable_raise`) without re-running the
    /// desugar pass.
    fn buildKernelZeroArgCall(self: *HirBuilder, name: []const u8, meta: ast.NodeMeta) anyerror!*const Expr {
        const interner_mut = @constCast(self.interner);
        const kernel_name = try interner_mut.intern("Kernel");
        const fn_name = try interner_mut.intern(name);
        const kernel_parts = try self.allocator.dupe(ast.StringId, &.{kernel_name});
        const kernel_ref = try self.create(ast.Expr, .{
            .struct_ref = .{ .meta = meta, .name = .{ .parts = kernel_parts, .span = meta.span } },
        });
        const callee = try self.create(ast.Expr, .{
            .field_access = .{ .meta = meta, .object = kernel_ref, .field = fn_name },
        });
        const call_expr = try self.create(ast.Expr, .{
            .call = .{ .meta = meta, .callee = callee, .args = &.{} },
        });
        return try self.buildExpr(call_expr);
    }

    /// Phase 3.b — does the function `func` (declared in `scope_id` with
    /// `arity`) carry the `raises` effect? Resolves the owning struct prefix
    /// by walking up parent scopes from the family's scope to a registered
    /// struct, then queries the type store's `inferred_raises` via the same
    /// stable qualified key the type checker stored under and the IR backend
    /// reads. A top-level `main` (no struct) uses the bare `"<name>/<arity>"`.
    fn functionEmitsErrorUnion(
        self: *HirBuilder,
        func: *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
        arity: u32,
    ) bool {
        const method_name = self.interner.get(func.name);
        var struct_prefix: ?[]const u8 = null;
        var struct_prefix_buf: ?[]const u8 = null;
        defer if (struct_prefix_buf) |buf| self.allocator.free(buf);
        var scope_cursor: ?scope_mod.ScopeId = scope_id;
        outer: while (scope_cursor) |sid| {
            // `self.graph` is `*const`, so iterate `structs.items` directly
            // rather than `findStructByScope` (which returns a mutable ptr).
            for (self.graph.structs.items) |entry| {
                if (entry.scope_id != sid) continue;
                const joined = entry.name.joinedWith(self.allocator, self.interner, ".") catch break :outer;
                struct_prefix_buf = joined;
                struct_prefix = joined;
                break :outer;
            }
            scope_cursor = self.graph.getScope(sid).parent;
        }
        return self.type_store.functionRaises(struct_prefix, method_name, arity);
    }

    /// Phase 3.b — build a propagating `raise` (`ret_raise`) HIR node from a
    /// `raise_expr`. Reuses `buildRecoverableRaise` to construct the
    /// `Kernel.recoverable_raise(<box>)` stash call (which boxes the error and
    /// stores it into the thread-local side-channel), then wraps it in a
    /// `ret_raise` node whose IR lowering appends `return error.ZapRaise`.
    /// `Never`-typed so a propagating raise in tail position coerces to any
    /// expected merge type, exactly like the abort and lexical-recoverable
    /// raises. Returns `null` (so the caller falls back to the abort path)
    /// when the value is not in the expected `Kernel.do_raise(arg)` shape.
    fn buildRetRaise(self: *HirBuilder, re: ast.RaiseExpr) anyerror!?*const Expr {
        const stash_call = (try self.buildRecoverableRaise(re)) orelse return null;
        return try self.create(Expr, .{
            .kind = .{ .ret_raise = .{ .stash_call = stash_call } },
            .type_id = types_mod.TypeStore.NEVER,
            .span = re.meta.span,
        });
    }

    /// Rebuild a `raise`'s lowered `Kernel.do_raise(<error>)` call as the
    /// recoverable sink `Kernel.recoverable_raise(<error>)` and lower it to
    /// HIR. Used by the `raise_expr` arm when inside a `try` handler scope.
    /// Returns `null` when the `raise_expr` value is not in the expected
    /// `Kernel.do_raise(arg)` shape (defensive — the desugar always produces
    /// it), so the caller falls back to the abort lowering.
    fn buildRecoverableRaise(self: *HirBuilder, re: ast.RaiseExpr) anyerror!?*const Expr {
        if (re.value.* != .call) return null;
        const call = re.value.call;
        if (call.callee.* != .field_access) return null;
        const fa = call.callee.field_access;
        if (call.args.len != 1) return null;

        const interner_mut = @constCast(self.interner);
        const recoverable_name = try interner_mut.intern("recoverable_raise");

        const new_callee = try self.create(ast.Expr, .{
            .field_access = .{ .meta = fa.meta, .object = fa.object, .field = recoverable_name },
        });
        const new_call = try self.create(ast.Expr, .{
            .call = .{ .meta = call.meta, .callee = new_callee, .args = call.args },
        });
        const lowered = try self.buildExpr(new_call);
        // Stamp the recoverable-raise call as `Never`-typed even though the
        // `Kernel.recoverable_raise` stdlib fn returns `Nil` at runtime. A
        // `raise` is a diverging terminator in the type system, so a
        // recoverable raise in tail position must coerce to the enclosing
        // `try`/`rescue` result type (like the abort `do_raise`). Without
        // this the body's tail would type as `Nil` and the handler-vs-body
        // branch merge in `lowerTryRescue` would reject `Nil` vs the rescue
        // arms' result type. The runtime fn still returns normally — control
        // falls through to the compiler-emitted `raise_occurred()` landing
        // pad — so this is purely a type-surface coercion, not a codegen
        // noreturn claim.
        const never_typed = try self.create(Expr, .{
            .kind = lowered.kind,
            .type_id = types_mod.TypeStore.NEVER,
            .span = lowered.span,
        });
        return never_typed;
    }

    fn buildTryProject(self: *HirBuilder, te: ast.TryExpr) anyerror!*const Expr {
        const operand = try self.buildExpr(te.value);

        // Resolve the underlying tagged-union declaration through `.applied`
        // so a parametric `Result(T, E)` instantiation is handled exactly
        // like a bare `Result` tagged union.
        const operand_typ = self.type_store.getType(operand.type_id);
        const decl_typ = switch (operand_typ) {
            .tagged_union => operand_typ,
            .applied => |ap| self.type_store.getType(ap.base),
            else => operand_typ,
        };

        // Discover the `Ok`/`Error` variant names and the `Ok` payload type
        // structurally. A `Result` has exactly two variants, each carrying a
        // payload; the unwrap yields the `Ok` payload type and the
        // early-return re-wraps the `Error` payload.
        const interner_mut = @constCast(self.interner);
        var ok_variant_name: ast.StringId = interner_mut.intern("Ok") catch unreachable;
        var error_variant_name: ast.StringId = interner_mut.intern("Error") catch unreachable;
        var ok_payload_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
        if (decl_typ == .tagged_union) {
            // Build the per-instantiation substitution so the `Ok` payload
            // type reflects the concrete instantiation rather than the raw
            // declaration type variable.
            var subs: ?types_mod.SubstitutionMap = null;
            defer if (subs) |*owned| owned.deinit();
            if (operand_typ == .applied) {
                const decl_union = decl_typ.tagged_union;
                var built = types_mod.SubstitutionMap.init(self.allocator);
                const pair_count = @min(decl_union.type_params.len, operand_typ.applied.args.len);
                for (decl_union.type_params[0..pair_count], operand_typ.applied.args[0..pair_count]) |formal_id, arg_id| {
                    const formal_typ = self.type_store.getType(formal_id);
                    if (formal_typ != .type_var) continue;
                    built.bind(formal_typ.type_var, arg_id);
                }
                subs = built;
            }
            for (decl_typ.tagged_union.variants) |variant| {
                const variant_text = self.interner.get(variant.name);
                if (std.mem.eql(u8, variant_text, "Ok")) {
                    ok_variant_name = variant.name;
                    ok_payload_type = variant.type_id orelse types_mod.TypeStore.UNKNOWN;
                    if (subs) |*s| {
                        if (ok_payload_type != types_mod.TypeStore.UNKNOWN) {
                            ok_payload_type = s.applyToType(self.type_store, ok_payload_type);
                        }
                    }
                } else if (std.mem.eql(u8, variant_text, "Error")) {
                    error_variant_name = variant.name;
                }
            }
        }

        return try self.create(Expr, .{
            .kind = .{ .try_project = .{
                .operand = operand,
                .result_type_id = operand.type_id,
                .ok_variant_name = ok_variant_name,
                .error_variant_name = error_variant_name,
            } },
            .type_id = ok_payload_type,
            .span = te.meta.span,
        });
    }

    /// Build an error pipe expression: chain ~> handler
    /// Flattens the pipe chain, builds each step, detects which return tagged
    /// unions, and produces an ErrorPipeHir that the IR builder lowers to
    /// nested union_switch instructions.
    fn buildErrorPipe(self: *HirBuilder, ep: ast.ErrorPipeExpr) anyerror!*const Expr {
        // Flatten the AST pipe chain into individual steps
        var ast_steps: std.ArrayList(*const ast.Expr) = .empty;
        self.flattenAstPipeChain(ep.chain, &ast_steps);

        if (ast_steps.items.len == 0) {
            return try self.create(Expr, .{
                .kind = .nil_lit,
                .type_id = types_mod.TypeStore.UNKNOWN,
                .span = ep.meta.span,
            });
        }

        // Build each step as a HIR expression.
        // Step 0 is the base call. Steps 1+ are pipe rhs (need lhs piped in as first arg).
        var hir_steps: std.ArrayList(ErrorPipeStep) = .empty;
        for (ast_steps.items) |step| {
            const hir_expr = try self.buildExpr(step);
            // Check if this step calls a multi-clause function (needs __try variant)
            const is_dispatched = blk: {
                if (step.* == .call) {
                    const callee = step.call.callee;
                    const arity: u32 = @intCast(step.call.args.len + 1);
                    if (callee.* == .var_ref) {
                        break :blk self.isFunctionMultiClause(callee.var_ref.name, arity);
                    } else if (callee.* == .field_access) {
                        break :blk self.isFunctionMultiClause(callee.field_access.field, arity);
                    }
                }
                break :blk false;
            };
            try hir_steps.append(self.allocator, .{
                .expr = hir_expr,
                .is_dispatched = is_dispatched,
            });
        }

        // Build the error handler expression
        const handler_lowering = try self.buildErrorHandlerExpr(ep.handler, ep.meta);

        // Result type is the last step's type (the catch basin handler
        // must return the same type for the expression to be well-typed).
        const result_type = if (hir_steps.items.len > 0)
            hir_steps.items[hir_steps.items.len - 1].expr.type_id
        else
            types_mod.TypeStore.UNKNOWN;

        return try self.create(Expr, .{
            .kind = .{ .error_pipe = .{
                .steps = try hir_steps.toOwnedSlice(self.allocator),
                .handler = handler_lowering.expr,
                .err_local = handler_lowering.err_local,
            } },
            .type_id = result_type,
            .span = ep.meta.span,
        });
    }

    /// Flatten a pipe chain AST expression into individual steps.
    fn flattenAstPipeChain(self: *HirBuilder, expr: *const ast.Expr, steps: *std.ArrayList(*const ast.Expr)) void {
        switch (expr.*) {
            .pipe => |pe| {
                self.flattenAstPipeChain(pe.lhs, steps);
                steps.append(self.allocator, pe.rhs) catch {};
            },
            else => {
                steps.append(self.allocator, expr) catch {};
            },
        }
    }

    const HandlerLowering = struct {
        expr: *const Expr,
        /// `null` → no `__err` allocation (function-style handler).
        /// Some(idx) → IR populates local `idx` with the failing pipe value
        /// before lowering the handler; pattern bindings on `__err` resolve
        /// to the same local index.
        err_local: ?u32,
    };

    /// Build an error handler HIR expression from an AST ErrorHandler.
    /// For block handlers `~> { pattern -> body, ... }`, builds a case
    /// expression that pattern-matches on a fresh `__err` local. The IR
    /// populates that local with the failing pipe value before lowering
    /// the handler. For function handlers `~> handler_fn(...)` the function
    /// expression is returned directly with no `__err` allocation; the IR
    /// passes the failing value as the function's first argument.
    fn buildErrorHandlerExpr(self: *HirBuilder, handler: ast.ErrorHandler, meta: ast.NodeMeta) !HandlerLowering {
        switch (handler) {
            .block => |clauses| {
                // Allocate a fresh local for `__err`. The IR sets this local
                // to the failing pipe value before lowering the handler, so
                // both pattern bindings and the synthesized var_ref to __err
                // resolve to the same index.
                const err_local = self.next_local;
                self.next_local += 1;

                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                const err_name = try interner_mut.intern("__err");

                // Make `__err` resolvable as a normal binding for the
                // duration of the case build. Restored on exit so the
                // surrounding scope sees no leaked binding.
                try self.current_assignment_bindings.append(self.allocator, .{
                    .name = err_name,
                    .local_index = err_local,
                    .type_id = types_mod.TypeStore.UNKNOWN,
                });
                const saved_bindings_len = self.current_assignment_bindings.items.len;
                defer {
                    if (self.current_assignment_bindings.items.len == saved_bindings_len) {
                        _ = self.current_assignment_bindings.pop();
                    }
                }

                const scrutinee_expr = try self.create(Expr, .{
                    .kind = .{ .local_get = err_local },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });

                // Build case arms by reusing the regular case-expr binding/
                // pattern machinery. Each arm gets its own binding state via
                // save/restore so cross-arm leakage cannot occur.
                var arms: std.ArrayList(CaseArm) = .empty;
                for (clauses) |clause| {
                    const saved_case_bindings = self.current_case_bindings;
                    self.current_case_bindings = .empty;

                    const pattern = try self.compilePattern(clause.pattern);
                    if (pattern) |pat| {
                        try self.collectCasePatternBindings(pat, true);
                    }

                    const guard_expr = if (clause.guard) |g| try self.buildExpr(g) else null;
                    const body = try self.buildBlock(clause.body);
                    const bindings = try self.current_case_bindings.toOwnedSlice(self.allocator);

                    try arms.append(self.allocator, .{
                        .pattern = pattern,
                        .guard = guard_expr,
                        .body = body,
                        .bindings = bindings,
                    });

                    self.current_case_bindings = saved_case_bindings;
                }

                const case_expr = try self.create(Expr, .{
                    .kind = .{ .case = .{
                        .scrutinee = scrutinee_expr,
                        .arms = try arms.toOwnedSlice(self.allocator),
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = meta.span,
                });
                return .{ .expr = case_expr, .err_local = err_local };
            },
            .function => |func| {
                return .{ .expr = try self.buildExpr(func), .err_local = null };
            },
        }
    }

    // ============================================================
    // Allocation helper
    // ============================================================

    fn resolveTypeExpr(self: *const HirBuilder, type_expr: *const ast.TypeExpr) TypeId {
        return switch (type_expr.*) {
            .name => |n| {
                const name_str = self.interner.get(n.name);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);

                // Names already bound as type variables in the active
                // hir_type_var_scope short-circuit to the bound TypeId.
                // Mirrors the type checker's behaviour so impl-declared
                // parameters like `K`, `V` resolve consistently across
                // params and return types.
                if (n.args.len == 0) {
                    if (self.hir_type_var_scope.get(name_str)) |existing| return existing;
                }

                // Built-in generic containers: `Map(K, V)` and `List(T)`
                // map onto the dedicated TypeStore variants the rest of
                // the pipeline already understands. Same shape that the
                // existing `[T]` and `%{K=>V}` sigils produce. The native
                // type identity comes from the `@native_type` attribute
                // on the corresponding stdlib struct (see ScopeGraph
                // `NativeTypeKind`), so users can shadow `List`/`Map`
                // safely without triggering compiler-special handling.
                if (n.args.len > 0) {
                    if (self.isNativeTypeName(.map, n.name) and n.args.len == 2) {
                        const key_t = self.resolveTypeExpr(n.args[0]);
                        const value_t = self.resolveTypeExpr(n.args[1]);
                        return store_ptr.addType(.{ .map = .{ .key = key_t, .value = value_t } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                    if (self.isNativeTypeName(.list, n.name) and n.args.len == 1) {
                        const elem_t = self.resolveTypeExpr(n.args[0]);
                        return store_ptr.addType(.{ .list = .{ .element = elem_t } }) catch types_mod.TypeStore.UNKNOWN;
                    }
                }

                // First check builtins
                if (self.type_store.resolveTypeName(name_str)) |id| return id;
                // Then check user-defined types (struct/enum) from scope graph
                if (self.graph.resolveTypeByName(n.name)) |scope_type_id| {
                    // Resolve scope TypeId to TypeStore TypeId via name_to_type map
                    if (self.type_store.name_to_type.get(n.name)) |ts_id| {
                        // Parametric user types in type position: build
                        // the canonical `.applied { base, args }` form
                        // so monomorphization sees `Box(i64)` rather
                        // than the bare `Box` declaration. Without this
                        // path, an annotation like `pub fn build() ->
                        // Box(i64)` would lower as the declaration
                        // TypeId, hiding the instantiation from
                        // context-driven inference at struct literal
                        // sites.
                        if (n.args.len > 0) {
                            const stored_typ = self.type_store.getType(ts_id);
                            const is_parametric_nominal = (stored_typ == .struct_type and stored_typ.struct_type.type_params.len > 0) or
                                (stored_typ == .tagged_union and stored_typ.tagged_union.type_params.len > 0);
                            if (is_parametric_nominal) {
                                const resolved_args = self.allocator.alloc(types_mod.TypeId, n.args.len) catch return ts_id;
                                for (n.args, 0..) |arg, idx| {
                                    resolved_args[idx] = self.resolveTypeExpr(arg);
                                }
                                return store_ptr.addType(.{ .applied = .{
                                    .base = ts_id,
                                    .args = resolved_args,
                                } }) catch ts_id;
                            }
                        }
                        return ts_id;
                    }
                    // If not in TypeStore yet, it may be a forward reference
                    _ = scope_type_id;
                }
                // Check if this is a protocol name — create a protocol_constraint type
                for (self.graph.protocols.items) |proto| {
                    if (proto.name.parts.len > 0 and self.structNameMatchesText(proto.name, name_str)) {
                        // Resolve type parameters (e.g., Enumerable(member) → [type_var_for_member])
                        var type_params: std.ArrayList(types_mod.TypeId) = .empty;
                        for (n.args) |arg| {
                            type_params.append(self.allocator, self.resolveTypeExpr(arg)) catch {};
                        }
                        return store_ptr.addType(.{
                            .protocol_constraint = .{
                                .protocol_name = n.name,
                                .type_params = type_params.toOwnedSlice(self.allocator) catch &.{},
                            },
                        }) catch types_mod.TypeStore.UNKNOWN;
                    }
                }
                return types_mod.TypeStore.UNKNOWN;
            },
            .never => types_mod.TypeStore.NEVER,
            .paren => |p| self.resolveTypeExpr(p.inner),
            .literal => |lt| {
                return switch (lt.value) {
                    .int => types_mod.TypeStore.I64,
                    .string => types_mod.TypeStore.STRING,
                    .bool_val => types_mod.TypeStore.BOOL,
                    .nil => types_mod.TypeStore.NIL,
                };
            },
            .union_type => |ut| {
                // General union type — resolve each member
                var member_types: std.ArrayList(TypeId) = .empty;
                for (ut.members) |member| {
                    member_types.append(self.allocator, self.resolveTypeExpr(member)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const members = member_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                for (self.type_store.types.items, 0..) |typ, i| {
                    if (typ == .union_type) {
                        const existing = typ.union_type;
                        if (existing.members.len == members.len) {
                            var match = true;
                            for (existing.members, members) |a, b| {
                                if (a != b) {
                                    match = false;
                                    break;
                                }
                            }
                            if (match) return @intCast(i);
                        }
                    }
                }
                return types_mod.TypeStore.UNKNOWN;
            },
            .tuple => |tt| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (tt.elements) |elem| {
                    elem_types.append(self.allocator, self.resolveTypeExpr(elem)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const elements = elem_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                return store_ptr.addType(.{ .tuple = .{ .elements = elements } }) catch types_mod.TypeStore.UNKNOWN;
            },
            .function => |ft| {
                var param_types: std.ArrayList(TypeId) = .empty;
                for (ft.params) |param| {
                    param_types.append(self.allocator, self.resolveTypeExpr(param)) catch return types_mod.TypeStore.UNKNOWN;
                }
                const params = param_types.toOwnedSlice(self.allocator) catch return types_mod.TypeStore.UNKNOWN;
                const param_ownerships = self.allocator.alloc(Ownership, ft.param_ownerships.len) catch return types_mod.TypeStore.UNKNOWN;
                for (ft.param_ownerships, ft.param_ownerships_explicit, params, 0..) |ownership, explicit, param_type, idx| {
                    param_ownerships[idx] = if (explicit)
                        mapAstOwnership(ownership)
                    else if (mapAstOwnership(ownership) == .shared)
                        self.defaultOwnershipForType(param_type)
                    else
                        mapAstOwnership(ownership);
                }
                const return_type = self.resolveTypeExpr(ft.return_type);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                const ret_ownership = if (ft.return_ownership_explicit)
                    mapAstOwnership(ft.return_ownership)
                else if (mapAstOwnership(ft.return_ownership) == .shared)
                    self.defaultOwnershipForType(return_type)
                else
                    mapAstOwnership(ft.return_ownership);
                return store_ptr.addFunctionType(params, return_type, param_ownerships, ret_ownership) catch types_mod.TypeStore.UNKNOWN;
            },
            .list => |lt| {
                const elem_type = self.resolveTypeExpr(lt.element);
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                return store_ptr.addType(.{ .list = .{ .element = elem_type } }) catch types_mod.TypeStore.UNKNOWN;
            },
            .map => |mt| {
                if (mt.fields.len > 0) {
                    const key_type = self.resolveTypeExpr(mt.fields[0].key);
                    const value_type = self.resolveTypeExpr(mt.fields[0].value);
                    const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                    return store_ptr.addType(.{ .map = .{ .key = key_type, .value = value_type } }) catch types_mod.TypeStore.UNKNOWN;
                }
                return types_mod.TypeStore.UNKNOWN;
            },
            .variable => |tv| {
                // Type variable — ensure the same name within a function clause maps
                // to the same TypeId so that `fn foo(x :: a) -> a` has consistent types.
                const var_name = self.interner.get(tv.name);
                if (self.type_store.resolveTypeName(var_name)) |id| return id;
                if (self.hir_type_var_scope.get(var_name)) |existing| {
                    return existing;
                }
                const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
                const fresh = store_ptr.freshVar() catch return types_mod.TypeStore.UNKNOWN;
                const self_mut: *HirBuilder = @constCast(self);
                self_mut.hir_type_var_scope.put(var_name, fresh) catch {};
                return fresh;
            },
            else => types_mod.TypeStore.UNKNOWN,
        };
    }

    /// Resolve a bare call to an imported struct via the current scope's imports.
    /// Returns the struct name string if the function is imported, null otherwise.
    /// Resolution follows Elixir semantics: local struct > imports > Kernel/top-level.
    fn resolveImport(self: *const HirBuilder, name: ast.StringId, arity: u32) ?[]const u8 {
        const mod_scope_id = self.current_struct_scope orelse return null;
        const mod_scope = self.graph.getScope(mod_scope_id);

        // Check if the function is defined locally in this struct (local takes priority)
        const local_key = scope_mod.FamilyKey{ .name = name, .arity = arity };
        if (mod_scope.function_families.get(local_key) != null) return null;

        // Check imports on this scope
        for (mod_scope.imports.items) |imp| {
            if (self.importMatchesFunction(imp, name, arity)) {
                return self.structNameToString(imp.source_struct);
            }
        }

        return null;
    }

    /// Check if an import declaration makes a specific function name/arity available.
    fn importMatchesFunction(self: *const HirBuilder, imp: scope_mod.ImportedScope, name: ast.StringId, arity: u32) bool {
        switch (imp.filter) {
            .all => {
                // Import all — verify the source struct actually exports this function
                return self.sourceStructHasFunction(imp.source_struct, name, arity);
            },
            .only => |entries| {
                // Only import listed functions
                for (entries) |entry| {
                    if (entry.name == name) {
                        if (entry.arity) |a| {
                            if (a == arity) return true;
                        } else {
                            // Type import (arity null) — doesn't match function calls
                            continue;
                        }
                    }
                }
                return false;
            },
            .except => |entries| {
                // Import all except listed — first check source struct exports it
                if (!self.sourceStructHasFunction(imp.source_struct, name, arity)) return false;
                // Then check it's not excluded
                for (entries) |entry| {
                    if (entry.name == name) {
                        if (entry.arity) |a| {
                            if (a == arity) return false; // excluded
                        }
                    }
                }
                return true;
            },
        }
    }

    /// Check if a struct (by name) exports a specific function.
    fn sourceStructHasFunction(self: *const HirBuilder, mod_name: ast.StructName, name: ast.StringId, arity: u32) bool {
        // Find the struct in the scope graph
        for (self.graph.structs.items) |mod_entry| {
            if (self.structNamesEqual(mod_entry.name, mod_name)) {
                const mod_scope = self.graph.getScope(mod_entry.scope_id);
                const key = scope_mod.FamilyKey{ .name = name, .arity = arity };
                return mod_scope.function_families.get(key) != null;
            }
        }
        return false;
    }

    /// Compare two StructNames for equality (all parts must match).
    fn structNamesEqual(_: *const HirBuilder, a: ast.StructName, b: ast.StructName) bool {
        if (a.parts.len != b.parts.len) return false;
        for (a.parts, b.parts) |pa, pb| {
            if (pa != pb) return false;
        }
        return true;
    }

    fn structNameToString(self: *const HirBuilder, name: ast.StructName) []const u8 {
        if (name.parts.len == 1) return self.interner.get(name.parts[0]);
        return name.joinedWith(self.allocator, self.interner, "_") catch self.interner.get(name.parts[0]);
    }

    fn structNameMatchesText(self: *const HirBuilder, name: ast.StructName, text: []const u8) bool {
        if (name.parts.len == 0) return false;
        if (name.parts.len == 1) {
            return std.mem.eql(u8, self.interner.get(name.parts[0]), text);
        }

        const dotted = name.joinedWith(self.allocator, self.interner, ".") catch return false;
        defer self.allocator.free(dotted);
        return std.mem.eql(u8, dotted, text);
    }

    fn structNameMatchesCallQualifier(self: *const HirBuilder, name: ast.StructName, qualifier: []const u8) bool {
        if (name.parts.len == 0) return false;

        const last_part = self.interner.get(name.parts[name.parts.len - 1]);
        if (std.mem.eql(u8, last_part, qualifier)) return true;

        const prefix = self.structNameToString(name);
        if (std.mem.eql(u8, prefix, qualifier)) return true;

        return self.structNameMatchesText(name, qualifier);
    }

    /// Build the canonical `.applied { base, args }` TypeId for a
    /// parametric struct literal like `%Box(i64){...}`. Each `type_arg`
    /// AST node is resolved via `resolveTypeExpr` so nested
    /// instantiations (`%Box(Option(i64)){...}`) lower their inner
    /// arguments through the same path. Falls back to the declaration
    /// TypeId if any arg fails to resolve — the type checker already
    /// emitted a diagnostic in that case (arity mismatch / non-
    /// parametric type) so callers see a coherent literal type rather
    /// than UNKNOWN cascading into IR.
    fn buildAppliedStructLiteralType(
        self: *HirBuilder,
        declaration_type_id: types_mod.TypeId,
        type_args: []const *const ast.TypeExpr,
    ) types_mod.TypeId {
        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
        const resolved = self.allocator.alloc(types_mod.TypeId, type_args.len) catch return declaration_type_id;
        for (type_args, 0..) |type_arg_expr, idx| {
            resolved[idx] = self.resolveTypeExpr(type_arg_expr);
        }
        return store_ptr.addType(.{ .applied = .{
            .base = declaration_type_id,
            .args = resolved,
        } }) catch declaration_type_id;
    }

    /// Compute the substituted result type of a field-access `obj.field`
    /// where `obj`'s static type is `receiver_type_id`. When the
    /// receiver is `.applied { base = StructDecl(T1..Tn), args = [A1..An] }`,
    /// the field's declared type is rewritten through the
    /// per-instantiation substitution `Ti -> Ai`. When the receiver is
    /// a bare struct declaration the field's declared type is returned
    /// verbatim (matches existing concrete-struct semantics). Returns
    /// `TypeStore.UNKNOWN` when the receiver type carries no struct
    /// shape (UNKNOWN, primitive, etc.) or when the field name does
    /// not exist on the declared struct.
    fn fieldAccessResultType(
        self: *const HirBuilder,
        receiver_type_id: types_mod.TypeId,
        field_name: ast.StringId,
    ) types_mod.TypeId {
        if (receiver_type_id == types_mod.TypeStore.UNKNOWN) return types_mod.TypeStore.UNKNOWN;
        if (receiver_type_id >= self.type_store.types.items.len) return types_mod.TypeStore.UNKNOWN;
        const receiver_type = self.type_store.getType(receiver_type_id);

        const struct_type, const arg_types = switch (receiver_type) {
            .struct_type => |st| .{ st, @as(?[]const types_mod.TypeId, null) },
            .applied => |ap| blk: {
                if (ap.base >= self.type_store.types.items.len) return types_mod.TypeStore.UNKNOWN;
                const base_typ = self.type_store.getType(ap.base);
                if (base_typ != .struct_type) return types_mod.TypeStore.UNKNOWN;
                break :blk .{ base_typ.struct_type, @as(?[]const types_mod.TypeId, ap.args) };
            },
            else => return types_mod.TypeStore.UNKNOWN,
        };

        const declared_field_type = blk: {
            for (struct_type.fields) |field| {
                if (field.name == field_name) break :blk field.type_id;
            }
            return types_mod.TypeStore.UNKNOWN;
        };

        const args = arg_types orelse return declared_field_type;
        if (args.len == 0 or struct_type.type_params.len == 0) return declared_field_type;

        var subs = types_mod.SubstitutionMap.init(self.allocator);
        defer subs.deinit();
        const pair_count = @min(struct_type.type_params.len, args.len);
        for (struct_type.type_params[0..pair_count], args[0..pair_count]) |formal_id, arg_id| {
            if (formal_id >= self.type_store.types.items.len) continue;
            const formal_typ = self.type_store.getType(formal_id);
            if (formal_typ != .type_var) continue;
            subs.bind(formal_typ.type_var, arg_id);
        }
        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);
        return subs.applyToType(store_ptr, declared_field_type);
    }

    /// Context-driven inference for `%Box{...}` (no explicit `(...)`).
    /// When the enclosing context — a variable annotation, function
    /// return type, or function-argument expected type — provides a
    /// concrete `.applied` whose `base` matches the struct
    /// declaration, return that `.applied` TypeId so the literal
    /// adopts the same instantiation. Returns null if no expected
    /// context is in scope, if the context's base doesn't match, or
    /// if the declaration isn't parametric (concrete structs use the
    /// declaration TypeId directly).
    fn inferAppliedFromExpectedType(
        self: *const HirBuilder,
        declaration_type_id: types_mod.TypeId,
    ) ?types_mod.TypeId {
        if (self.expected_type_stack.items.len == 0) return null;
        const expected = self.expected_type_stack.items[self.expected_type_stack.items.len - 1];
        if (expected == types_mod.TypeStore.UNKNOWN) return null;
        if (expected >= self.type_store.types.items.len) return null;
        const expected_typ = self.type_store.getType(expected);
        if (expected_typ != .applied) return null;
        if (expected_typ.applied.base != declaration_type_id) return null;
        return expected;
    }

    fn internDottedStructName(self: *HirBuilder, name: ast.StructName) !ast.StringId {
        if (name.parts.len == 0) return 0;
        if (name.parts.len == 1) return name.parts[0];

        var name_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer name_buf.deinit(self.allocator);
        for (name.parts, 0..) |part, index| {
            if (index > 0) try name_buf.append(self.allocator, '.');
            try name_buf.appendSlice(self.allocator, self.interner.get(part));
        }
        const interner_mut = @constCast(self.interner);
        return try interner_mut.intern(name_buf.items);
    }

    fn hasImpl(self: *const HirBuilder, protocol_name: ast.StructName, target_name: []const u8) ?ast.StructName {
        for (self.graph.impls.items) |entry| {
            if (!self.structNamesEqual(entry.protocol_name, protocol_name)) continue;
            if (self.structNameMatchesText(entry.target_type, target_name)) return entry.target_type;
        }
        return null;
    }

    fn hasImplByText(self: *const HirBuilder, protocol_name: []const u8, target_name: []const u8) ?ast.StructName {
        for (self.graph.impls.items) |entry| {
            if (!self.structNameMatchesText(entry.protocol_name, protocol_name)) continue;
            if (self.structNameMatchesText(entry.target_type, target_name)) return entry.target_type;
        }
        return null;
    }

    fn isProtocolName(self: *const HirBuilder, name: ast.StructName) bool {
        for (self.graph.protocols.items) |entry| {
            if (self.structNamesEqual(entry.name, name)) return true;
        }
        return false;
    }

    /// Generic protocol-call dispatch: when a user writes `Protocol.method(arg, ...)`
    /// and `Protocol` is a registered protocol with an `impl Protocol for T`
    /// matching the first argument's type, returns the target type's struct
    /// name so the call lowers to `T.method(arg, ...)`.
    ///
    /// Returns null when:
    ///   - `mod_name` is not a registered protocol
    ///   - the first arg's type is UNKNOWN or has no canonical struct name
    ///   - no impl exists for the resolved target type
    /// Callers fall through to the original struct name when null is returned.
    fn protocolDispatchStruct(
        self: *const HirBuilder,
        protocol_name: ast.StructName,
        first_arg_type: types_mod.TypeId,
    ) ?[]const u8 {
        if (!self.isProtocolName(protocol_name)) return null;
        if (first_arg_type == types_mod.TypeStore.UNKNOWN) return null;
        const target_struct = self.type_store.typeToStructName(first_arg_type, self.interner) orelse return null;
        const impl_target = self.hasImpl(protocol_name, target_struct) orelse return null;
        return self.structNameToString(impl_target);
    }

    fn resolveNominalStructRefType(self: *HirBuilder, struct_name: ast.StructName) !?types_mod.TypeId {
        if (struct_name.parts.len == 0) return null;

        const full_name = try self.internDottedStructName(struct_name);
        if (self.type_store.name_to_type.get(full_name)) |type_id| return type_id;

        if (struct_name.parts.len == 1) {
            if (self.type_store.name_to_type.get(struct_name.parts[0])) |type_id| return type_id;
        }

        return null;
    }

    fn appendStructDefaults(self: *HirBuilder, fields: *std.ArrayList(StructFieldInit), struct_type_id: types_mod.TypeId) !void {
        if (struct_type_id == types_mod.TypeStore.UNKNOWN) return;
        if (struct_type_id >= self.type_store.types.items.len) return;

        const typ = self.type_store.getType(struct_type_id);
        if (typ != .struct_type) return;

        for (typ.struct_type.fields) |declared_field| {
            var already_provided = false;
            for (fields.items) |field| {
                if (field.name == declared_field.name) {
                    already_provided = true;
                    break;
                }
            }
            if (already_provided) continue;

            const default_expr = declared_field.default_expr orelse continue;
            // Push the field's declared type onto the expected-type
            // stack BEFORE lowering the default expression. This is
            // the same context-driven inference user-supplied fields
            // get (search for `expected_field_type` in the struct-
            // literal lowering); it lets a default expression like
            // `Option.None` lower as the right parametric variant
            // construction (`union_init(Option_Error, .None, ...)`)
            // instead of a bare `enum_literal` whose type Sema later
            // rejects against the field's `Option_Error` slot. The
            // pub error `cause :: Option(Error) = Option.None` desugar
            // depends on this propagation to type-check.
            const apply_expected = declared_field.type_id != types_mod.TypeStore.UNKNOWN;
            if (apply_expected) try self.expected_type_stack.append(self.allocator, declared_field.type_id);
            const value = try self.buildExpr(default_expr);
            if (apply_expected) _ = self.expected_type_stack.pop();
            // Stamp the field's declared type onto literals and empty
            // containers in the freshly built default. Without this
            // an empty list default like `tags :: [String] = []`
            // lowers as a bare `list_init []` with UNKNOWN element
            // type — the IR defaults it to `List(i64)` and Zig's
            // Sema rejects the struct init with a `List(i64)` vs
            // `List(String)` mismatch lifted from the synthetic
            // construction site (far from the actual mistake). Same
            // shape for narrow-integer defaults like
            // `port :: u16 = 8080`: the literal lowers as i64 unless
            // we stamp the field's width. Stamping is type-
            // directional: if the inferred type already matches,
            // this is a no-op. The expected_type_stack push above
            // handles variant-construction default expressions that
            // need to know the parametric instantiation up front;
            // this stamps post-build literals that didn't need the
            // stack push to lower correctly.
            self.propagateExpectedTypeToDefault(value, declared_field.type_id);
            try fields.append(self.allocator, .{
                .name = declared_field.name,
                .value = value,
            });
        }
    }

    /// Push the declared field type down into a freshly lowered HIR
    /// default expression. This is the construction-site analog of
    /// `patchEmptyContainerTypes` plus integer-literal narrowing —
    /// the same machinery `buildExpr` already runs on user-supplied
    /// call arguments (see the `arg.expected_type` propagation
    /// loop around line 4795).
    fn propagateExpectedTypeToDefault(self: *const HirBuilder, expr: *const Expr, expected_type: types_mod.TypeId) void {
        if (expected_type == types_mod.TypeStore.UNKNOWN) return;
        if (expected_type >= self.type_store.types.items.len) return;
        if (self.type_store.getType(expected_type) == .struct_type) {
            // For nested struct defaults like `inner :: Inner =
            // %Inner{}`, the HIR build already produced a
            // `struct_init` carrying the right type. No further
            // stamping is needed — and stamping a struct type on top
            // of a primitive would silently corrupt the value.
            return;
        }

        // Empty list/map literals: the existing helper carries the
        // exact UNKNOWN-to-expected stamping the codegen needs.
        self.patchEmptyContainerTypesExpr(expr, expected_type);

        // Integer-literal narrowing: a bare `8080` lowers as a
        // default-typed `int_lit` (HIR's `buildExpr` stamps `I64`
        // unconditionally). When the receiving field declares a
        // different integer width — `port :: u16 = 8080`,
        // `flags :: u8 = 0`, etc. — we restamp the literal here so
        // the codegen path that previously failed on
        // `expected u8, got value 8080` gets the right slot from
        // the start. This is the construction-site analog of the
        // `arg.expected_type` propagation loop that buildExpr runs
        // for user-supplied call arguments (search for
        // "Propagate expected_type to argument expressions").
        const expected_kind = self.type_store.getType(expected_type);
        const mut: *Expr = @constCast(expr);
        if (mut.kind == .int_lit and expected_kind == .int) {
            mut.type_id = expected_type;
            return;
        }

        // String literal whose type slot stayed UNKNOWN: same
        // stamping. (String literals normally get STRING from
        // `buildExpr`; this is a defensive write so a future
        // refactor that leaves the slot UNKNOWN still types
        // correctly at the construction site.)
        if (mut.kind == .string_lit and mut.type_id == types_mod.TypeStore.UNKNOWN and expected_type == types_mod.TypeStore.STRING) {
            mut.type_id = expected_type;
            return;
        }
    }

    fn isFieldlessStructType(self: *const HirBuilder, type_id: types_mod.TypeId) bool {
        if (type_id >= self.type_store.types.items.len) return false;
        const typ = self.type_store.getType(type_id);
        return typ == .struct_type and typ.struct_type.fields.len == 0;
    }

    /// Walk a block and stamp `expected_type` on any UNKNOWN-typed
    /// empty container literals (currently `list_init []` and
    /// `map_init {}`). Used by `case_expr` to propagate a unified arm
    /// type back into siblings whose result is an empty literal — the
    /// for-comprehension's `{:done, _, _} -> []` arm being the canonical
    /// example. Mutates the block's HIR in place via @constCast; the
    /// HIR allocator owns these expressions and they're not shared
    /// across structs.
    /// Compute the element TypeId for a list literal whose entries are
    /// already lowered to HIR. Performs structural unification so that
    /// disagreeing scalar elements promote to `TERM`, and disagreeing
    /// tuple components promote position-wise to `TERM`.
    ///
    /// Examples:
    ///   `[1, 2, 3]`              → `[i64]`
    ///   `[1, "x"]`               → `[Term]`
    ///   `[{:a, 1}, {:b, "s"}]`   → `[{Atom, Term}]` (component-wise)
    ///   `[{:a, 1}, {:b, "s", 7}]`→ `[Term]` (different arity → fall back)
    fn inferListElementType(self: *const HirBuilder, built_elems: []const *const Expr) types_mod.TypeId {
        if (built_elems.len == 0) return types_mod.TypeStore.UNKNOWN;
        const store_ptr: *types_mod.TypeStore = @constCast(self.type_store);

        // First pass: pick a starting concrete type.
        var element_type: types_mod.TypeId = types_mod.TypeStore.UNKNOWN;
        for (built_elems) |elem| {
            if (elem.type_id != types_mod.TypeStore.UNKNOWN) {
                element_type = elem.type_id;
                break;
            }
        }

        // Fallback: detect string-literal lists when nothing carries type info.
        if (element_type == types_mod.TypeStore.UNKNOWN) {
            for (built_elems) |elem| {
                if (elem.kind == .string_lit) {
                    element_type = types_mod.TypeStore.STRING;
                    break;
                }
            }
        }

        if (element_type == types_mod.TypeStore.UNKNOWN) return types_mod.TypeStore.UNKNOWN;

        // Second pass: unify the chosen type with every other element.
        for (built_elems) |elem| {
            if (elem.type_id == types_mod.TypeStore.UNKNOWN) continue;
            element_type = unifyForCollection(store_ptr, element_type, elem.type_id);
        }

        // Propagate the unified element type back to each child element so
        // downstream IR sees the type that the list ACTUALLY expects (e.g.
        // a heterogeneous keyword list `[name: "x", age: 42]` unifies to
        // `[{Atom, Term}]` — each tuple element_type must reflect the
        // promoted `Term` slot so `tuple_init` knows to emit `Term.from`).
        for (built_elems) |elem| {
            if (elem.type_id == types_mod.TypeStore.UNKNOWN) continue;
            propagateUnifiedTypeToElement(store_ptr, @constCast(elem), element_type);
        }

        return store_ptr.addType(.{ .list = .{ .element = element_type } }) catch types_mod.TypeStore.UNKNOWN;
    }

    fn patchEmptyContainerTypes(self: *const HirBuilder, block: *const Block, expected_type: types_mod.TypeId) void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| self.patchEmptyContainerTypesExpr(expr, expected_type),
                .local_set => |ls| self.patchEmptyContainerTypesExpr(ls.value, expected_type),
                // A `defer`/`errdefer` cleanup is never the block's tail
                // value, so an empty container literal inside it never needs
                // the block's expected-type patch.
                .defer_stmt => {},
                .function_group => {},
            }
        }
        if (block.result_type == types_mod.TypeStore.UNKNOWN) {
            const mut: *Block = @constCast(block);
            mut.result_type = expected_type;
        }
    }

    fn patchEmptyContainerTypesExpr(self: *const HirBuilder, expr: *const Expr, expected_type: types_mod.TypeId) void {
        const expected_kind = self.type_store.getType(expected_type);
        switch (expr.kind) {
            .list_init => |elems| {
                if (elems.len == 0 and expr.type_id == types_mod.TypeStore.UNKNOWN and expected_kind == .list) {
                    const mut: *Expr = @constCast(expr);
                    mut.type_id = expected_type;
                }
            },
            .map_init => |entries| {
                if (entries.len == 0 and expr.type_id == types_mod.TypeStore.UNKNOWN and expected_kind == .map) {
                    const mut: *Expr = @constCast(expr);
                    mut.type_id = expected_type;
                }
            },
            else => {},
        }
    }

    /// Recursively collect case-arm bindings from a match pattern.
    /// `is_top_level` distinguishes a top-level `name -> body` bind (kind=.scrutinee,
    /// emitted by the success leaf) from binds nested inside a compound pattern
    /// (kind=.extracted, emitted by a decision-tree `.bind` node).
    fn collectCasePatternBindings(self: *HirBuilder, pat: *const MatchPattern, is_top_level: bool) !void {
        switch (pat.*) {
            .bind => |name| {
                const name_str = self.interner.get(name);
                // Skip user-intent discards (`_x`) but keep compiler-
                // synthesised names (`__next_state`, `__err`, …) — those
                // back generated bindings the IR's bind-decision-tree
                // handler must resolve to extract decomposed values
                // (e.g. the cont-arm tail in a for-comprehension).
                if (ast.isDiscardBindName(name_str)) return;
                const local_idx = self.next_local;
                self.next_local += 1;
                try self.current_case_bindings.append(self.allocator, .{
                    .name = name,
                    .local_index = local_idx,
                    .kind = if (is_top_level) .scrutinee else .extracted,
                    .element_index = 0,
                });
            },
            .tuple => |sub_pats| {
                for (sub_pats) |sub_pat| {
                    try self.collectCasePatternBindings(sub_pat, false);
                }
            },
            .list => |sub_pats| {
                for (sub_pats) |sub_pat| {
                    try self.collectCasePatternBindings(sub_pat, false);
                }
            },
            .list_cons => |lc| {
                for (lc.heads) |head_pat| {
                    try self.collectCasePatternBindings(head_pat, false);
                }
                try self.collectCasePatternBindings(lc.tail, false);
            },
            .struct_match => |sm| {
                for (sm.field_bindings) |field| {
                    try self.collectCasePatternBindings(field.pattern, false);
                }
            },
            .map_match => |mm| {
                for (mm.field_bindings) |field| {
                    try self.collectCasePatternBindings(field.pattern, false);
                }
            },
            .binary_match => |bm| {
                for (bm.segments, 0..) |seg, seg_idx| {
                    if (seg.pattern) |sub_pat| {
                        if (sub_pat.* != .bind) continue;
                        const name_str = self.interner.get(sub_pat.bind);
                        // Same discard convention as the case-pattern
                        // collector — see `ast.isDiscardBindName`.
                        if (ast.isDiscardBindName(name_str)) continue;
                        const local_idx = self.next_local;
                        self.next_local += 1;
                        try self.current_case_bindings.append(self.allocator, .{
                            .name = sub_pat.bind,
                            .local_index = local_idx,
                            .kind = .binary_element,
                            .element_index = @intCast(seg_idx),
                        });
                    }
                }
            },
            .tagged_variant_match => |tvm| {
                // Recurse into the payload pattern so a bind inside
                // (e.g. `Option.Some(v) -> v + 1`) registers a fresh
                // local with kind=.extracted — the IR layer's
                // tagged-variant lowering will assign it the payload
                // local produced by `scrutinee.VariantName` extraction.
                if (tvm.payload) |payload_pat| {
                    try self.collectCasePatternBindings(payload_pat, false);
                }
            },
            .wildcard, .literal, .pin => {},
        }
    }

    fn create(self: *HirBuilder, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    /// Recursively destructure an assignment LHS pattern, emitting one
    /// `local_set` per inner `bind` and registering each as an
    /// `AssignmentBinding` for later var_ref resolution. The parent
    /// compound value lives in `parent_local`; nested patterns reference
    /// it via a `local_get` extractor.
    fn lowerAssignmentDestructure(
        self: *HirBuilder,
        pat: *const ast.Pattern,
        parent_local: u32,
        parent_type: TypeId,
        span: ast.SourceSpan,
        out_stmts: *std.ArrayList(Stmt),
    ) !void {
        switch (pat.*) {
            .wildcard, .literal => {},
            .pin => {},
            .paren => |inner| try self.lowerAssignmentDestructure(inner.inner, parent_local, parent_type, span, out_stmts),
            .bind => |b| {
                // A bind nested in a compound: alias the parent's local (no
                // copy, no extraction). The parent extractor already produced
                // a fresh local; the bind just gives it a name.
                try self.current_assignment_bindings.append(self.allocator, .{
                    .name = b.name,
                    .local_index = parent_local,
                    .type_id = parent_type,
                });
            },
            .tuple => |tp| {
                const parent_typ = self.type_store.getType(parent_type);
                for (tp.elements, 0..) |sub_pat, idx| {
                    if (sub_pat.* == .wildcard or sub_pat.* == .literal) continue;
                    const elem_type = if (parent_typ == .tuple and idx < parent_typ.tuple.elements.len)
                        parent_typ.tuple.elements[idx]
                    else
                        types_mod.TypeStore.UNKNOWN;
                    const elem_local = try self.emitDestructureStep(.{ .tuple = .{
                        .object = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .index = @intCast(idx),
                    } }, elem_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(sub_pat, elem_local, elem_type, span, out_stmts);
                }
            },
            .list => |lp| {
                const parent_typ = self.type_store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else types_mod.TypeStore.UNKNOWN;
                for (lp.elements, 0..) |sub_pat, idx| {
                    if (sub_pat.* == .wildcard or sub_pat.* == .literal) continue;
                    const elem_local = try self.emitDestructureStep(.{ .list_at = .{
                        .list = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .index = @intCast(idx),
                    } }, elem_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(sub_pat, elem_local, elem_type, span, out_stmts);
                }
            },
            .list_cons => |lc| {
                const parent_typ = self.type_store.getType(parent_type);
                const elem_type = if (parent_typ == .list) parent_typ.list.element else types_mod.TypeStore.UNKNOWN;
                for (lc.heads, 0..) |head_pat, head_index| {
                    if (!(head_pat.* == .wildcard or head_pat.* == .literal)) {
                        const head_local = try self.emitDestructureStep(.{ .list_at = .{
                            .list = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                            .index = @intCast(head_index),
                        } }, elem_type, span, out_stmts);
                        try self.lowerAssignmentDestructure(head_pat, head_local, elem_type, span, out_stmts);
                    }
                }
                if (!(lc.tail.* == .wildcard or lc.tail.* == .literal)) {
                    const tail_local = try self.emitDestructureStep(.{ .list_tail = .{
                        .list = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .start_index = @intCast(lc.heads.len),
                    } }, parent_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(lc.tail, tail_local, parent_type, span, out_stmts);
                }
            },
            .struct_pattern => |sp| {
                for (sp.fields) |field| {
                    if (field.pattern.* == .wildcard or field.pattern.* == .literal) continue;
                    const field_type = self.resolveStructFieldType(parent_type, field.name);
                    const field_local = try self.emitDestructureStep(.{ .field = .{
                        .object = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .field = field.name,
                    } }, field_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(field.pattern, field_local, field_type, span, out_stmts);
                }
            },
            .map => |mp| {
                const parent_typ = self.type_store.getType(parent_type);
                const value_type = if (parent_typ == .map) parent_typ.map.value else types_mod.TypeStore.UNKNOWN;
                for (mp.fields) |field| {
                    if (field.value.* == .wildcard or field.value.* == .literal) continue;
                    const key_expr = try self.buildExpr(field.key);
                    const value_local = try self.emitDestructureStep(.{ .map_at = .{
                        .map = try self.create(Expr, .{ .kind = .{ .local_get = parent_local }, .type_id = parent_type, .span = span }),
                        .key = key_expr,
                    } }, value_type, span, out_stmts);
                    try self.lowerAssignmentDestructure(field.value, value_local, value_type, span, out_stmts);
                }
            },
            .binary => {
                // Binary patterns on assignment LHS are uncommon. Treat as a
                // no-op for now — when this becomes a real use case, build a
                // case expression via the binary segment extractor.
            },
            .tagged_union_variant => {
                // Tagged-union variant patterns on assignment LHS would
                // be an irrefutable bind on a known variant — i.e.
                // `Option.Some(v) = opt` would crash at runtime when
                // `opt` is `None`. Refuse silently here (the type
                // checker will surface a destructuring-shape error
                // when this lands as a public surface); they are
                // only meaningful in `case` arms today.
            },
        }
    }

    const DestructureStep = union(enum) {
        tuple: TupleIndexGetExpr,
        list_at: ListIndexGetExpr,
        list_head: ListHeadGetExpr,
        list_tail: ListTailGetExpr,
        field: FieldGetExpr,
        map_at: MapValueGetExpr,
    };

    fn emitDestructureStep(
        self: *HirBuilder,
        step: DestructureStep,
        elem_type: TypeId,
        span: ast.SourceSpan,
        out_stmts: *std.ArrayList(Stmt),
    ) !u32 {
        const dest_local = self.next_local;
        self.next_local += 1;
        const expr_kind: ExprKind = switch (step) {
            .tuple => |s| .{ .tuple_index_get = s },
            .list_at => |s| .{ .list_index_get = s },
            .list_head => |s| .{ .list_head_get = s },
            .list_tail => |s| .{ .list_tail_get = s },
            .field => |s| .{ .field_get = s },
            .map_at => |s| .{ .map_value_get = s },
        };
        const value_expr = try self.create(Expr, .{
            .kind = expr_kind,
            .type_id = elem_type,
            .span = span,
        });
        try out_stmts.append(self.allocator, .{
            .local_set = .{ .index = dest_local, .value = value_expr },
        });
        return dest_local;
    }

    fn resolveStructFieldType(self: *const HirBuilder, struct_type: TypeId, field_name: ast.StringId) TypeId {
        const typ = self.type_store.getType(struct_type);
        if (typ != .struct_type) return types_mod.TypeStore.UNKNOWN;
        for (typ.struct_type.fields) |f| {
            if (f.name == field_name) return f.type_id;
        }
        return types_mod.TypeStore.UNKNOWN;
    }
};

/// Encode a TypeId into the short token used by ZIR's typed-builtin
/// dispatch (matches `ir.zigTypeToEncodedName`). Used to materialize
/// `:zig.List.fn` calls into `List:Elem.fn` so the runtime container
/// instantiates with the right element type.
/// Encode a HIR type as the short name used in `:zig.List.method` /
/// `:zig.Map.method` builtin call dispatch (e.g. `List:str.next`,
/// `Map:u32:bool.put`). Returns null for types the encoder cannot
/// resolve to a concrete instantiation — type variables, unknown,
/// or container types still bound to a generic parameter — so
/// callers fall through to the unqualified `Struct.method` form.
/// The IR's lowerCall arm then re-encodes from each call site's
/// actual local type, which is what makes monomorphized
/// specializations dispatch to the right runtime variant.
fn encodeContainerElemName(store: *const types_mod.TypeStore, type_id: types_mod.TypeId) ?[]const u8 {
    if (type_id == types_mod.TypeStore.UNKNOWN) return null;
    const t = store.getType(type_id);
    return switch (t) {
        .int => |i| switch (i.bits) {
            8 => if (i.signedness == .signed) "i8" else "u8",
            16 => if (i.signedness == .signed) "i16" else "u16",
            32 => if (i.signedness == .signed) "i32" else "u32",
            64 => if (i.signedness == .signed) "i64" else "u64",
            128 => if (i.signedness == .signed) "i128" else "u128",
            else => "i64",
        },
        .float => |f| switch (f.bits) {
            16 => "f16",
            32 => "f32",
            64 => "f64",
            80 => "f80",
            128 => "f128",
            else => "f64",
        },
        .bool_type => "bool",
        .string_type => "str",
        .atom_type => "u32",
        .term_type => "Term",
        .struct_type => |s| store.interner.get(s.name),
        .tagged_union => |tu| store.interner.get(tu.name),
        else => null,
    };
}

// Standard library resolution removed — IO, Kernel, etc. are now
// real Zap structs defined in lib/ and compiled with the program.

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "HIR build simple function" {
    const source =
        \\pub struct Test {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.structs.len);
    try std.testing.expectEqual(@as(u32, 2), hir_program.structs[0].functions[0].arity);
}

test "HIR build struct" {
    const source =
        \\pub struct Math {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.structs.len);
    try std.testing.expectEqual(@as(usize, 1), hir_program.structs[0].functions.len);
}

test "HIR resolves numeric List applications structurally" {
    const source =
        \\@native_type = "list"
        \\
        \\pub struct List {
        \\}
        \\
        \\pub struct Test {
        \\  pub fn ints(values :: List(i64)) -> List(i64) {
        \\    values
        \\  }
        \\
        \\  pub fn floats(values :: List(f64)) -> List(f64) {
        \\    values
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 2), hir_program.structs.len);

    const test_struct = hir_program.structs[1];
    try std.testing.expectEqual(@as(usize, 2), test_struct.functions.len);

    const ints_clause = test_struct.functions[0].clauses[0];
    const ints_param_type = type_store.getType(ints_clause.params[0].type_id);
    const ints_return_type = type_store.getType(ints_clause.return_type);
    try std.testing.expect(ints_param_type == .list);
    try std.testing.expectEqual(types_mod.TypeStore.I64, ints_param_type.list.element);
    try std.testing.expect(ints_return_type == .list);
    try std.testing.expectEqual(types_mod.TypeStore.I64, ints_return_type.list.element);

    const floats_clause = test_struct.functions[1].clauses[0];
    const floats_param_type = type_store.getType(floats_clause.params[0].type_id);
    const floats_return_type = type_store.getType(floats_clause.return_type);
    try std.testing.expect(floats_param_type == .list);
    try std.testing.expectEqual(types_mod.TypeStore.F64, floats_param_type.list.element);
    try std.testing.expect(floats_return_type == .list);
    try std.testing.expectEqual(types_mod.TypeStore.F64, floats_return_type.list.element);
}

test "HIR lowers numeric tuple field access to tuple_index_get" {
    const source =
        \\pub struct Test {
        \\  pub fn second() -> String {
        \\    tuple = {1, "two", true}
        \\    tuple.1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const clause = hir_program.structs[0].functions[0].clauses[0];
    const result_expr = clause.body.stmts[1].expr;
    try std.testing.expect(result_expr.kind == .tuple_index_get);
    try std.testing.expectEqual(@as(u32, 1), result_expr.kind.tuple_index_get.index);
    try std.testing.expectEqual(types_mod.TypeStore.STRING, result_expr.type_id);
}

test "HIR pattern compilation" {
    const source =
        \\pub struct Test {
        \\  pub fn foo(x :: Atom) -> Nil {
        \\    case x {
        \\      {:ok, v} -> v
        \\      {:error, e} -> e
        \\    }
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    // Should have built the function with case expression
    try std.testing.expectEqual(@as(usize, 1), hir_program.structs[0].functions.len);
    try std.testing.expectEqual(@as(usize, 0), builder.errors.items.len);
}

test "HIR typed params default to shared ownership" {
    const source =
        \\pub struct Test {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const params = hir_program.structs[0].functions[0].clauses[0].params;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqual(Ownership.shared, params[0].ownership);
    try std.testing.expectEqual(Ownership.shared, params[1].ownership);
}

test "HIR opaque typed params default to unique ownership" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use(handle :: Handle) -> Handle {
        \\    handle
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const params = hir_program.structs[0].functions[0].clauses[0].params;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqual(Ownership.unique, params[0].ownership);
}

test "HIR respects borrowed param annotation" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn inspect(handle :: borrowed Handle) {
        \\    handle
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const params = hir_program.structs[0].functions[0].clauses[0].params;
    try std.testing.expectEqual(Ownership.borrowed, params[0].ownership);
}

test "HIR call args default to share mode" {
    const source =
        \\pub struct Test {
        \\  pub fn foo(x) {
        \\    x
        \\  }
        \\
        \\  pub fn bar(y) {
        \\    foo(y)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const bar_clause = hir_program.structs[0].functions[1].clauses[0];
    const call_expr = bar_clause.body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(@as(usize, 1), call_expr.kind.call.args.len);
    try std.testing.expectEqual(ValueMode.share, call_expr.kind.call.args[0].mode);
}

test "HIR call args adopt function ownership modes" {
    const source =
        \\pub struct Test {
        \\  pub fn apply(f :: (String -> String), x :: String) -> String {
        \\    f(x)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    const apply_clause = program.structs[0].items[0].function.clauses[0];
    const clause_scope = collector.graph.resolveClauseScope(apply_clause.meta) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const param_ownerships = try alloc.alloc(Ownership, original_fn_type.params.len);
    for (param_ownerships, 0..) |*ownership, idx| {
        ownership.* = original_fn_type.param_ownerships.?[idx];
    }
    param_ownerships[0] = .unique;
    checker.store.types.items[f_type_id] = .{
        .function = .{
            .params = original_fn_type.params,
            .return_type = original_fn_type.return_type,
            .param_ownerships = param_ownerships,
            .return_ownership = original_fn_type.return_ownership,
        },
    };

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const call_expr = hir_program.structs[0].functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(@as(usize, 1), call_expr.kind.call.args.len);
    try std.testing.expectEqual(ValueMode.move, call_expr.kind.call.args[0].mode);
}

test "HIR named calls use resolved parameter ownership" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn take(handle :: Handle) -> Handle {
        \\    handle
        \\  }
        \\
        \\  pub fn run(handle :: Handle) -> Handle {
        \\    take(handle)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const run_clause = hir_program.structs[0].functions[1].clauses[0];
    const call_expr = run_clause.body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(@as(usize, 1), call_expr.kind.call.args.len);
    try std.testing.expectEqual(ValueMode.move, call_expr.kind.call.args[0].mode);
}

test "HIR closure calls adopt borrowed ownership mode" {
    const source =
        \\pub struct Test {
        \\  pub fn apply(f :: (String -> String), x :: String) {
        \\    f(x)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    const apply_clause = program.structs[0].items[0].function.clauses[0];
    const clause_scope = collector.graph.resolveClauseScope(apply_clause.meta) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const ownerships = try alloc.alloc(Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .borrowed;
    checker.store.types.items[f_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const call_expr = hir_program.structs[0].functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(call_expr.kind == .call);
    try std.testing.expectEqual(ValueMode.borrow, call_expr.kind.call.args[0].mode);
}

test "HIR function_ref lowers to first-class Function struct init" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn run() -> Function {
        \\    &double/1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const expr = hir_program.structs[2].functions[1].clauses[0].body.stmts[0].expr;
    try std.testing.expect(expr.kind == .struct_init);

    const function_name = parser.interner.lookupExisting("Function") orelse return error.TestUnexpectedResult;
    const function_type = checker.store.name_to_type.get(function_name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(function_type, expr.type_id);

    const function_init = expr.kind.struct_init;
    try std.testing.expectEqual(@as(usize, 3), function_init.fields.len);

    const struct_field = function_init.fields[0];
    try std.testing.expectEqualStrings("struct", parser.interner.get(struct_field.name));
    try std.testing.expect(struct_field.value.kind == .struct_init);
    const type_value = struct_field.value.kind.struct_init;
    try std.testing.expectEqual(@as(usize, 1), type_value.fields.len);
    try std.testing.expect(type_value.fields[0].value.kind == .atom_lit);
    try std.testing.expectEqualStrings("Test", parser.interner.get(type_value.fields[0].value.kind.atom_lit));

    const name_field = function_init.fields[1];
    try std.testing.expectEqualStrings("name", parser.interner.get(name_field.name));
    try std.testing.expect(name_field.value.kind == .atom_lit);
    try std.testing.expectEqualStrings("double", parser.interner.get(name_field.value.kind.atom_lit));

    const arity_field = function_init.fields[2];
    try std.testing.expectEqualStrings("arity", parser.interner.get(arity_field.name));
    try std.testing.expect(arity_field.value.kind == .int_lit);
    try std.testing.expectEqual(@as(i64, 1), arity_field.value.kind.int_lit);
    try std.testing.expectEqual(types_mod.TypeStore.U8, arity_field.value.type_id);
}

test "HIR bare struct ref lowers to first-class Type struct init" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Arena {
        \\}
        \\
        \\pub struct Test {
        \\  pub fn run() -> Type {
        \\    Arena
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const expr = hir_program.structs[2].functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(expr.kind == .struct_init);
    const type_name = parser.interner.lookupExisting("Type") orelse return error.TestUnexpectedResult;
    const type_type = checker.store.name_to_type.get(type_name) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(type_type, expr.type_id);

    const type_init = expr.kind.struct_init;
    try std.testing.expectEqual(@as(usize, 1), type_init.fields.len);
    try std.testing.expectEqualStrings("name", parser.interner.get(type_init.fields[0].name));
    try std.testing.expect(type_init.fields[0].value.kind == .atom_lit);
    try std.testing.expectEqualStrings("Arena", parser.interner.get(type_init.fields[0].value.kind.atom_lit));
}

test "HIR direct function_ref call lowers without closure dispatch" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn double(x :: i64) -> i64 {
        \\    x * 2
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    &double/1(21)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const expr = hir_program.structs[2].functions[1].clauses[0].body.stmts[0].expr;
    try std.testing.expect(expr.kind == .call);
    try std.testing.expect(expr.kind.call.target == .direct);
    try std.testing.expectEqual(@as(usize, 1), expr.kind.call.args.len);
    try std.testing.expectEqual(types_mod.TypeStore.I64, expr.type_id);
}

test "HIR static manual Function struct call lowers without closure dispatch" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn target(args :: Nil) -> Nil {
        \\    nil
        \\  }
        \\
        \\  pub fn run() -> Nil {
        \\    %Function{struct: Test, name: :target, arity: 1}(nil)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const expr = hir_program.structs[2].functions[1].clauses[0].body.stmts[0].expr;
    try std.testing.expect(expr.kind == .call);
    try std.testing.expect(expr.kind.call.target == .direct);
    try std.testing.expectEqual(@as(usize, 1), expr.kind.call.args.len);
    try std.testing.expectEqual(types_mod.TypeStore.NIL, expr.type_id);
}

test "HIR function_ref arity literal is narrowed to u8" {
    const source =
        \\pub struct Type {
        \\  name :: Atom
        \\}
        \\
        \\pub struct Function {
        \\  struct :: Type
        \\  name :: Atom
        \\  arity :: u8
        \\}
        \\
        \\pub struct Test {
        \\  pub fn run() -> Function {
        \\    &Test.run/257
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    _ = checker.checkProgram(&program) catch {};

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const expr = hir_program.structs[2].functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(expr.kind == .struct_init);
    const typ = checker.store.getType(expr.type_id);
    try std.testing.expect(typ == .struct_type);
    const arity_field = expr.kind.struct_init.fields[2];
    try std.testing.expectEqualStrings("arity", parser.interner.get(arity_field.name));
    try std.testing.expect(arity_field.value.kind == .int_lit);
    try std.testing.expectEqual(@as(i64, 1), arity_field.value.kind.int_lit);
    try std.testing.expectEqual(types_mod.TypeStore.U8, arity_field.value.type_id);
}

test "HIR assignment rebinding shadows parameter (Elixir-style scope)" {
    // Regression: prior to the shadow fix, `buildBindingReference`
    // checked parameters BEFORE assignment bindings, so a rebind
    // (`x = expr`) would silently leave every later `x` reference
    // pointing at the original `param_get` rather than the new
    // `local_get`. Once COW-mutable ARC-managed containers join
    // the ARC-managed set, the IR retains
    // the receiver across the call, the runtime's COW path produces
    // a fresh buffer, and that fresh buffer flows into a new local —
    // the rebinding. Without this fix every later read of `x` would
    // observe the pre-call buffer instead of the post-call buffer
    // (silent miscompile, no crash).
    //
    // The test checks the resolution at HIR build time: after
    // building `x = x + 100; x` for a parameter `x`, the function's
    // body must contain a `local_set` followed by a `local_get`
    // that targets the SAME local index (the rebinding) — NOT a
    // `param_get` referencing slot 0 (the parameter).
    const source =
        \\pub struct Test {
        \\  pub fn rebind(x :: i64) -> i64 {
        \\    x = x + 100
        \\    x
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const stmts = hir_program.structs[0].functions[0].clauses[0].body.stmts;
    // Expected lowering shape:
    //   stmts[0] = local_set { index = N, value = (param_get 0) + 100 }
    //   stmts[1] = expr { local_get N }
    try std.testing.expect(stmts.len == 2);
    try std.testing.expect(stmts[0] == .local_set);
    try std.testing.expect(stmts[1] == .expr);

    const rebind_index = stmts[0].local_set.index;
    const final_expr = stmts[1].expr;
    // The final expression must resolve to a `local_get` of the
    // rebound local — NOT a `param_get`. Pre-fix this would have
    // been `.param_get = 0` (the parameter slot), which is the
    // exact silent miscompile the fix eliminates.
    try std.testing.expect(final_expr.kind == .local_get);
    try std.testing.expectEqual(rebind_index, final_expr.kind.local_get);
}

test "HIR chained assignment rebinds resolve most-recent-wins" {
    // Chained rebindings: `x = x + 100; x = x + 1; x`. The third
    // statement (the bare `x` reference) must resolve to the LATEST
    // rebinding's local, not the parameter and not the first
    // rebinding. This validates that `current_assignment_bindings`
    // is walked in reverse so the most recently appended binding
    // wins. Without reverse iteration the second rebinding would
    // still resolve correctly (the first `x = x + 100` is also a
    // local_get for the parameter, since at that point only the
    // parameter is in scope), but the third reference would pick
    // up the FIRST rebinding's local instead of the second's.
    const source =
        \\pub struct Test {
        \\  pub fn chain(x :: i64) -> i64 {
        \\    x = x + 100
        \\    x = x + 1
        \\    x
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const stmts = hir_program.structs[0].functions[0].clauses[0].body.stmts;
    try std.testing.expect(stmts.len == 3);
    try std.testing.expect(stmts[0] == .local_set);
    try std.testing.expect(stmts[1] == .local_set);
    try std.testing.expect(stmts[2] == .expr);

    const second_rebind_index = stmts[1].local_set.index;
    const final_expr = stmts[2].expr;
    try std.testing.expect(final_expr.kind == .local_get);
    // The final reference must resolve to the SECOND rebinding,
    // not the first — most-recent-wins semantics.
    try std.testing.expectEqual(second_rebind_index, final_expr.kind.local_get);

    // The second rebinding's RHS reads the FIRST rebinding (not the
    // parameter), since that was the most recent binding at the
    // time the second `x = x + 1` was lowered. We walk the RHS
    // looking for a `local_get` reference and assert it points at
    // the first rebinding's local — the exact shape of `+` lowering
    // (call vs. native primitive) varies by typed-arith path, so
    // we don't assert on the outer expression kind.
    const first_rebind_index = stmts[0].local_set.index;
    const second_rebind_rhs = stmts[1].local_set.value;
    const found_first_rebind = walkForLocalGet(second_rebind_rhs, first_rebind_index);
    try std.testing.expect(found_first_rebind);
}

/// Test helper: returns true iff `expr` (or any sub-expression
/// reachable through call/binary/unary operands) contains a
/// `local_get` referencing `target`. Used by the shadow-rebinding
/// regression tests to ignore the exact lowering of `+` (which can
/// be a `binary` for typed-arith primitives or a `call` for the
/// Kernel-routed path, depending on the operand types).
fn walkForLocalGet(expr: *const Expr, target: u32) bool {
    switch (expr.kind) {
        .local_get => |idx| return idx == target,
        .call => |c| {
            for (c.args) |arg| {
                if (walkForLocalGet(arg.expr, target)) return true;
            }
            return false;
        },
        .binary => |b| {
            if (walkForLocalGet(b.lhs, target)) return true;
            if (walkForLocalGet(b.rhs, target)) return true;
            return false;
        },
        .unary => |u| return walkForLocalGet(u.operand, target),
        else => return false,
    }
}

// ============================================================
// Parametric struct/union literal threading (Phase 1.1.5.c)
// ============================================================

test "HIR threads applied TypeId for parametric struct literal with explicit type args" {
    // `%Box(i64){value: 42}` must lower to a `struct_init` whose
    // `type_id` is the canonical `.applied { base = Box, args = [i64] }`
    // TypeId — NOT the bare declaration TypeId. The monomorphizer keys
    // specializations off the applied form, and downstream IR/ZIR
    // emission depends on seeing per-instantiation TypeIds.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn build() -> Box {
        \\    %Box(i64){value: 42}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const demo_struct = hir_program.structs[1];
    const build_clause = demo_struct.functions[0].clauses[0];
    const result_expr = build_clause.body.stmts[0].expr;

    try std.testing.expect(result_expr.kind == .struct_init);

    const applied_typ = checker.store.getType(result_expr.type_id);
    try std.testing.expect(applied_typ == .applied);
    try std.testing.expectEqual(@as(usize, 1), applied_typ.applied.args.len);
    try std.testing.expectEqual(types_mod.TypeStore.I64, applied_typ.applied.args[0]);

    // Same TypeId must live on the inner struct_init too, since IR
    // lowering reads it from there for per-instantiation emission.
    try std.testing.expectEqual(result_expr.type_id, result_expr.kind.struct_init.type_id);
}

test "HIR threads distinct applied TypeIds for two instantiations of the same struct" {
    // `%Box(i64){...}` and `%Box(String){...}` must lower to two
    // *different* TypeIds — both `.applied`, both with `base = Box`,
    // but with different `args`. This is the keying property the
    // monomorphizer relies on.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn build_int() -> Box {
        \\    %Box(i64){value: 42}
        \\  }
        \\  pub fn build_str() -> Box {
        \\    %Box(String){value: "hello"}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const demo_struct = hir_program.structs[1];
    const int_expr = demo_struct.functions[0].clauses[0].body.stmts[0].expr;
    const str_expr = demo_struct.functions[1].clauses[0].body.stmts[0].expr;

    try std.testing.expect(int_expr.type_id != str_expr.type_id);

    const int_typ = checker.store.getType(int_expr.type_id);
    const str_typ = checker.store.getType(str_expr.type_id);
    try std.testing.expect(int_typ == .applied);
    try std.testing.expect(str_typ == .applied);
    try std.testing.expectEqual(int_typ.applied.base, str_typ.applied.base);
}

test "HIR infers applied TypeId for %Box{...} from function return type" {
    // `pub fn build() -> Box(i64) { %Box{value: 42} }` — the function
    // return-type annotation provides the expected `.applied` so the
    // tail expression's literal adopts the same instantiation.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn build() -> Box(i64) {
        \\    %Box{value: 42}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const demo_struct = hir_program.structs[1];
    const build_clause = demo_struct.functions[0].clauses[0];
    const result_expr = build_clause.body.stmts[0].expr;
    try std.testing.expect(result_expr.kind == .struct_init);
    const typ = checker.store.getType(result_expr.type_id);
    try std.testing.expect(typ == .applied);
    try std.testing.expectEqual(types_mod.TypeStore.I64, typ.applied.args[0]);
}

test "HIR substitutes field-access type for applied parametric struct receiver" {
    // For `obj :: Box(i64)` followed by `obj.value`, the field-access
    // result type must be `i64` (the substituted form of `T`) — not
    // the raw type-var that lives on the Box declaration's field.
    // This is what downstream IR/ZIR sees when picking storage and
    // emitting field-get instructions per instantiation.
    const source =
        \\pub struct Box(T) {
        \\  value :: T
        \\}
        \\pub struct Demo {
        \\  pub fn unbox(b :: Box(i64)) -> i64 {
        \\    b.value
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const demo_struct = hir_program.structs[1];
    const unbox_clause = demo_struct.functions[0].clauses[0];
    const result_expr = unbox_clause.body.stmts[0].expr;
    try std.testing.expect(result_expr.kind == .field_get);
    try std.testing.expectEqual(types_mod.TypeStore.I64, result_expr.type_id);
}

test "HIR keeps declaration TypeId for concrete (non-parametric) struct literals" {
    // Existing behaviour: a non-parametric struct literal still
    // carries the bare declaration TypeId. The .applied threading is
    // additive for parametric instantiations only.
    const source =
        \\pub struct Point {
        \\  x :: i64
        \\  y :: i64
        \\}
        \\pub struct Demo {
        \\  pub fn origin() -> Point {
        \\    %Point{x: 0, y: 0}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var builder = HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    const demo_struct = hir_program.structs[1];
    const origin_expr = demo_struct.functions[0].clauses[0].body.stmts[0].expr;
    try std.testing.expect(origin_expr.kind == .struct_init);
    const typ = checker.store.getType(origin_expr.type_id);
    try std.testing.expect(typ == .struct_type);
}

/// Map a TypeId to a human-readable name string for synthesized type naming.
/// Must produce the same strings as TypeChecker.typeToString for deterministic matching.
fn typeIdToName(type_id: types_mod.TypeId, type_store: *const types_mod.TypeStore) []const u8 {
    return switch (type_id) {
        types_mod.TypeStore.BOOL => "Bool",
        types_mod.TypeStore.STRING => "String",
        types_mod.TypeStore.ATOM => "Atom",
        types_mod.TypeStore.NIL => "Nil",
        types_mod.TypeStore.NEVER => "Never",
        types_mod.TypeStore.I128 => "i128",
        types_mod.TypeStore.I64 => "i64",
        types_mod.TypeStore.I32 => "i32",
        types_mod.TypeStore.I16 => "i16",
        types_mod.TypeStore.I8 => "i8",
        types_mod.TypeStore.U128 => "u128",
        types_mod.TypeStore.U64 => "u64",
        types_mod.TypeStore.U32 => "u32",
        types_mod.TypeStore.U16 => "u16",
        types_mod.TypeStore.U8 => "u8",
        types_mod.TypeStore.F128 => "f128",
        types_mod.TypeStore.F80 => "f80",
        types_mod.TypeStore.F64 => "f64",
        types_mod.TypeStore.F32 => "f32",
        types_mod.TypeStore.F16 => "f16",
        types_mod.TypeStore.USIZE => "usize",
        types_mod.TypeStore.ISIZE => "isize",
        types_mod.TypeStore.UNKNOWN => "{unknown}",
        types_mod.TypeStore.ERROR => "{error}",
        else => {
            if (type_id < type_store.types.items.len) {
                const typ = type_store.types.items[type_id];
                return switch (typ) {
                    .tagged_union => |tu| type_store.interner.get(tu.name),
                    .struct_type => |st| type_store.interner.get(st.name),
                    else => "{type}",
                };
            }
            return "{type}";
        },
    };
}
