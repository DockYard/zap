const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const hir_mod = @import("hir.zig");
const scope_mod = @import("scope.zig");

// ============================================================
// Zig-shaped IR (spec §19)
//
// A low-level IR that sits between typed HIR and Zig emission.
// Represents explicit control flow, locals, calls, closures,
// and ARC operations.
// ============================================================

pub const FunctionId = u32;
pub const BlockId = u32;
pub const LocalId = u32;
pub const LabelId = u32;
pub const ValueMode = hir_mod.ValueMode;

// ============================================================
// IR Program
// ============================================================

pub const TypeDef = struct {
    name: []const u8,
    kind: TypeDefKind,
};

pub const TypeDefKind = union(enum) {
    struct_def: StructDef,
    enum_def: EnumDef,
    union_def: UnionDef,
};

pub const StructDef = struct {
    fields: []const StructFieldDef,
};

/// How a struct field is laid out at the runtime/Zig level. Only
/// matters for nominal struct fields whose type creates a layout
/// cycle: a self-referential `Tree { left :: ?Tree }` has infinite
/// size if every `Tree` value contains another `Tree` value, so
/// the compiler must internally indirect the recursive edge with
/// a pointer. Source nullability stays source-driven — `?Tree`
/// stays optional at the source level, but its storage is
/// `?*Tree` (optional pointer); `Tree` (non-optional) is rejected
/// as uninhabited if no terminating constructor is reachable.
pub const FieldStorage = enum {
    /// Field is laid out by value at its declared type. The default
    /// for every primitive, every nominal struct type that doesn't
    /// participate in a recursion cycle, and every container of
    /// either of those.
    direct,
    /// Field is laid out via a hidden pointer indirection that
    /// breaks an otherwise-infinite layout cycle. Source-level
    /// access still returns the deref'd value; construction
    /// auto-promotes the value to the heap. Triggered only for
    /// fields whose type transitively references the struct that
    /// owns them (self-recursion today; mutual recursion through
    /// SCC analysis is the next step).
    indirect,
};

pub const StructFieldDef = struct {
    name: []const u8,
    /// Field type as a structured `ZigType`. The previous string
    /// representation collapsed every non-primitive type to a printable
    /// name and forced the ZIR builder to round-trip through string
    /// matching that only handled scalars — every other shape silently
    /// fell through to `Zir.Inst.Ref` discriminant 0 (`u0_type`,
    /// not `void_type`), producing `expected type 'u0', found 'X'`
    /// at every literal site.
    type_expr: ZigType,
    default_value: ?DefaultValue = null,
    /// Storage strategy for this field. `.direct` is the default and
    /// applies to everything except recursive edges; `.indirect`
    /// inserts a hidden pointer to break a layout cycle (see
    /// `FieldStorage`). Computed by `analyzeStructFieldStorage`
    /// during IR construction.
    storage: FieldStorage = .direct,
};

pub const EnumDef = struct {
    variants: []const []const u8,
};

pub const UnionDef = struct {
    variants: []const UnionVariant,
};

pub const UnionVariant = struct {
    name: []const u8,
    type_name: ?[]const u8 = null, // null = unit variant (void)
};

pub const Program = struct {
    functions: []const Function,
    type_defs: []const TypeDef,
    entry: ?FunctionId,
};

/// Per-value ownership classification at IR sites that produce or
/// reference ARC-managed cells (parameters, locals, call results,
/// aggregate arm results, captures, and return values).
///
/// Phase A of the Phase 6 redux plan introduces this enum as pure
/// metadata. Phases C and E will use it to drive borrow/copy
/// classification (`borrow_value` vs `copy_value`) and verifier
/// invariants. The classification is the property the ownership
/// verifier checks: every ARC value site has exactly one class, and
/// drop insertion only emits `release` for `owned` values.
///
/// - `trivial`: Non-ARC values (i64, Bool, Atom, ...). No ARC
///   operations. Stored in `Function.local_ownership` for every
///   non-ARC local so the table is dense across `LocalId`.
/// - `owned`: Owns one refcount unit. Must be destroyed exactly once
///   on every CFG path that reaches a function exit. Owners are
///   produced by: function entry of owned-convention parameters,
///   `copy_value` of any ARC value, return values of calls whose
///   convention transfers ownership, aggregate initializers
///   (`map_init`, `list_init`, `struct_init`), and freshly-allocated
///   values. Must NOT be destroyed twice.
/// - `borrowed`: Borrowed reference scoped to a borrow region. Must
///   NOT be destroyed within the region. Cannot escape into owned
///   storage without an explicit `copy_value` to promote.
///   Produced by: function entry of borrowed-convention parameters
///   (the default for ARC-managed parameter types), `borrow_value`
///   of any owner, and capture access in closures.
pub const OwnershipClass = enum {
    trivial,
    owned,
    borrowed,
};

/// Per-parameter calling convention recorded on every
/// `Function.params` slot.
///
/// Three variants cover every parameter shape, which is cleaner than
/// pairing a binary `borrowed|owned` enum with a separate
/// `is_arc_managed` predicate: the dense form lets a single look-up
/// answer "what should drop insertion do at scope exit for this
/// parameter?" without consulting the type table again.
///
/// - `trivial`: The parameter's type is not ARC-managed. No retain
///   is performed by the caller, and drop insertion never targets
///   the parameter local at scope exit. This is the catch-all for
///   primitive scalar types, atoms, and structurally trivial types.
/// - `borrowed`: The default for ARC-managed parameter types. The
///   caller has already balanced retain (`share_value`) and release
///   (post-call `release`) around the call site, so the callee
///   merely *borrows* the value within its body. Drop insertion
///   must NOT emit a destroy on the parameter local at scope exit.
/// - `owned`: The callee takes ownership of the value. The caller
///   does NOT release after the call, and the callee is responsible
///   for emitting a `destroy_value` on every CFG path. Reserved for
///   explicitly-annotated consuming functions; today's stdlib
///   surface uses no `owned` parameters, so this variant exists for
///   forward compatibility with Phase H's consume-mode work.
pub const ParamConvention = enum {
    trivial,
    borrowed,
    owned,
};

/// Calling convention for the function's result value.
///
/// - `trivial`: The return type is not ARC-managed. Default for
///   primitive scalar types. The caller binds the result in a
///   trivial local with no retain/release tracking.
/// - `owned`: The callee returns an owner. The caller binds the
///   result in an owned local and is responsible for destroying it
///   on every CFG path. Default for ARC-managed return types.
/// - `borrowed`: The callee returns a borrow scoped to one of its
///   parameters (lifetime polymorphism). Currently unused; reserved
///   for a future extension that lets a function return a borrowed
///   alias to one of its inputs without bumping the refcount.
pub const ResultConvention = enum {
    trivial,
    owned,
    borrowed,
};

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    /// When this is a compiler-generated typed-clause entrypoint, these
    /// identify the source function group and source clause it lowers.
    source_group_id: ?FunctionId = null,
    source_clause_index: ?u32 = null,
    /// Struct this function belongs to (e.g., "IO", "Zest_Runtime"). Null for top-level.
    struct_name: ?[]const u8 = null,
    /// Function name within its struct, with arity suffix (e.g., "puts__1"). Used for per-struct ZIR emission.
    local_name: []const u8 = "",
    scope_id: scope_mod.ScopeId,
    arity: u32,
    params: []const Param,
    return_type: ZigType,
    /// Original TypeStore TypeId for the return type, preserved for list type detection.
    return_type_id: ?types_mod.TypeId = null,
    body: []const Block,
    is_closure: bool,
    captures: []const Capture,
    local_count: u32 = 0,
    /// Default parameter values. defaults[i] is the default for params[full_arity - defaults.len + i].
    /// Empty when no defaults exist.
    defaults: []const DefaultValue = &.{},
    /// True when at least one self-tail-call survives in this function
    /// AND the by-value parameter ABI would reject `musttail`. Set by
    /// `rewriteTailCalls` after observing both. The ZIR backend reads
    /// this flag and lowers tail-position self-calls as a `loop` +
    /// stack-slot recurrence (loopification) instead of `musttail`.
    /// Loopification has zero hot-path allocation and bypasses LLVM's
    /// tail-call legality entirely, so byref-shaped state recurses
    /// in bounded stack.
    loopify: bool = false,
    /// Per-parameter calling convention, one entry per `params` slot.
    /// Phase A of the Phase 6 redux plan populates this with the
    /// default classification: ARC-managed parameter types get
    /// `.borrowed`, every other parameter type gets `.trivial`.
    /// Phase H may flip individual entries to `.owned` for explicit
    /// consume-mode callees. The slice must always have the same
    /// length as `params` so call sites can index by parameter
    /// position.
    param_conventions: []const ParamConvention = &.{},
    /// Per-local ownership class indexed by `LocalId`. Phase A
    /// populates this with the trivial baseline classification:
    /// every non-ARC local is `.trivial`, every ARC-managed local
    /// (the value held in the local is ARC-cell-typed) defaults to
    /// `.owned` at this stage. Phase C's `arc_ownership` pass
    /// refines ARC entries into `.borrowed` vs `.owned` based on
    /// the local's definition site (parameter binding, alias of an
    /// existing value, fresh allocation, etc.) and the verifier in
    /// Phase E checks invariants against the refined classification.
    /// The slice has length `local_count` so look-ups by `LocalId`
    /// never need a bounds-tolerant fallback.
    local_ownership: []OwnershipClass = &.{},
    /// Calling convention for the result. Defaults to `.owned` for
    /// ARC-managed return types and `.trivial` for everything else.
    /// Phase E's verifier checks every `ret` instruction's source
    /// against this convention.
    result_convention: ResultConvention = .trivial,
};

pub const DefaultValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
    nil,
};

pub const Param = struct {
    name: []const u8,
    type_expr: ZigType,
    /// Original TypeStore TypeId, preserved for list type detection.
    type_id: ?types_mod.TypeId = null,
};

pub const Capture = struct {
    name: []const u8,
    type_expr: ZigType,
    ownership: hir_mod.Ownership,
};

pub const Block = struct {
    label: LabelId,
    instructions: []const Instruction,
};

// ============================================================
// Instructions (spec §19.2)
// ============================================================

pub const Instruction = union(enum) {
    // Constants
    const_int: ConstInt,
    const_float: ConstFloat,
    const_string: ConstString,
    const_bool: ConstBool,
    const_atom: ConstAtom,
    const_nil: LocalId,

    // Locals
    local_get: LocalGet,
    local_set: LocalSet,
    move_value: MoveValue,
    share_value: ShareValue,
    param_get: ParamGet,
    /// Phase C of the Phase 6 redux plan: produce a borrow alias of an
    /// ARC-managed source. Result is `.borrowed`. No retain on `dest`,
    /// no scope-exit destroy on `dest`. The arc_ownership pass produces
    /// this opcode by classifying a `.local_get` whose dest's only use
    /// is a borrowing-convention call argument or a borrow-only alias.
    /// Phase D's verifier ensures `dest` is not destroyed within its
    /// borrow scope and does not escape into owned storage.
    borrow_value: BorrowValue,
    /// Phase C of the Phase 6 redux plan: produce an independent owner
    /// from an ARC-managed source. Lowering emits a runtime retain on
    /// the source's cell. Result is `.owned`. Pairs with a scope-exit
    /// destroy (modeled as `.release` until Phase E renames). Produced
    /// by the arc_ownership pass when a `.local_get` flows into owned
    /// storage (struct/list/map/tuple init), is captured by a closure,
    /// or returns a borrowed parameter (return-source borrow promotion).
    copy_value: CopyValue,

    // Aggregates
    tuple_init: AggregateInit,
    list_init: ListInit,
    list_cons: ListCons,
    map_init: MapInit,
    struct_init: StructInit,
    union_init: UnionInit,
    enum_literal: EnumLiteral,
    field_get: FieldGet,
    field_set: FieldSet,
    index_get: IndexGet,
    list_len_check: ListLenCheck,
    list_get: ListGet,
    list_is_not_empty: ListIsNotEmpty,
    list_head: ListHeadTail,
    list_tail: ListHeadTail,
    map_has_key: MapHasKey,
    map_get: MapGet,

    // Arithmetic / logic
    binary_op: BinaryOp,
    unary_op: UnaryOp,

    // Calls
    call_direct: CallDirect,
    call_named: CallNamed,
    call_closure: CallClosure,
    call_dispatch: CallDispatch,
    call_builtin: CallBuiltin,
    tail_call: TailCall,
    /// Call a __try function variant (returns error union).
    /// Used in ~> catch basin pipe chains.
    try_call_named: TryCallNamed,
    /// Unwrap an error union result from try_call_named.
    /// On success: dest = unwrapped value.
    /// On error: dest = catch_value (handler result applied to the input that failed).
    error_catch: ErrorCatch,

    // Safety control
    set_safety: bool, // true = enable, false = disable

    // Control flow
    if_expr: IfExpr,
    guard_block: GuardBlock,
    case_block: CaseBlock,
    branch: Branch,
    cond_branch: CondBranch,
    switch_tag: SwitchTag,
    switch_literal: SwitchLiteral,
    switch_return: SwitchReturn,
    union_switch_return: UnionSwitchReturn,
    union_switch: UnionSwitch,
    optional_dispatch: OptionalDispatch,
    match_atom: MatchAtom,
    match_int: MatchInt,
    match_float: MatchFloat,
    match_string: MatchString,
    match_type: MatchType,
    match_fail: MatchFail,
    match_error_return: MatchErrorReturn,
    ret: Return,
    cond_return: CondReturn,
    case_break: CaseBreak,
    jump: Jump,

    // Closures
    make_closure: MakeClosure,
    capture_get: CaptureGet,

    // Optional unwrap
    optional_unwrap: OptionalUnwrap,

    // Binary pattern matching
    bin_len_check: BinLenCheck,
    bin_read_int: BinReadInt,
    bin_read_float: BinReadFloat,
    bin_slice: BinSlice,
    bin_read_utf8: BinReadUtf8,
    bin_match_prefix: BinMatchPrefix,

    // Memory / ARC
    retain: Retain,
    release: Release,

    // Perceus reuse (Koka-inspired)
    reset: Reset,
    reuse_alloc: ReuseAlloc,

    // Numeric widening
    int_widen: NumericWiden,
    float_widen: NumericWiden,

    // Phi
    phi: Phi,
};

pub const ConstInt = struct {
    dest: LocalId,
    value: i64,
    type_hint: ?ZigType = null,
};

pub const ConstFloat = struct {
    dest: LocalId,
    value: f64,
    type_hint: ?ZigType = null,
};

pub const ConstString = struct {
    dest: LocalId,
    value: []const u8,
};

pub const ConstBool = struct {
    dest: LocalId,
    value: bool,
};

pub const ConstAtom = struct {
    dest: LocalId,
    value: []const u8,
};

pub const LocalGet = struct {
    dest: LocalId,
    source: LocalId,
};

/// Payload for the `.borrow_value` instruction. Produced by the
/// arc_ownership pass when classifying a `.local_get` whose
/// destination is used only as a borrow alias (e.g., a borrowing
/// call argument). Lowers to a plain assignment in ZIR with no
/// retain on `dest`. The borrow is valid until the enclosing
/// borrow scope ends; Phase D's verifier checks no destroy fires
/// on `dest` within the scope.
pub const BorrowValue = struct {
    dest: LocalId,
    source: LocalId,
};

/// Payload for the `.copy_value` instruction. Produced by the
/// arc_ownership pass when classifying a `.local_get` whose
/// destination flows into owned storage, escapes via a closure
/// capture, or promotes a borrowed parameter to ownership at a
/// `ret` site. Lowers to assignment + `retainAny` in ZIR. The
/// caller is responsible for matching this with a scope-exit
/// destroy on `dest` (drop insertion handles this today).
pub const CopyValue = struct {
    dest: LocalId,
    source: LocalId,
};

pub const LocalSet = struct {
    dest: LocalId,
    value: LocalId,
};

pub const MoveValue = struct {
    dest: LocalId,
    source: LocalId,
};

/// Ownership semantics of a `share_value` instruction. Distinguishes
/// retain-style sharing (two live references after the share) from
/// consume-style transfer (caller relinquishes ownership). The default
/// is `.retain` so existing IR sites stay byte-identical until the ARC
/// liveness pass (phase 4) explicitly upgrades selected sites.
pub const ShareMode = enum {
    /// Default. Emits assign + retain. Caller's local stays live;
    /// callee's slot gets an independent ownership reference.
    /// Pairs with a release at scope exit (unless suppressed by
    /// `arc_share_skipped` from the escape lattice).
    retain,
    /// Caller relinquishes the retain bump at the share site because
    /// the source local is at its last use. Emits assign only — no
    /// retain. The post-call `.release{value=dest}` IR instruction
    /// still fires: callees BORROW their arguments, they do not
    /// internally decrement the cell. The scope-exit release on the
    /// source local (emitted by the drop-insertion pass) is also still
    /// emitted; it balances the original allocation rather than the
    /// share. Net effect of consume vs retain: -1 retain on the call
    /// path. Ownership transfers naturally because the source's last
    /// use means no further reads accumulate retains the post-call
    /// release would otherwise need to pair with.
    consume,
};

pub const ShareValue = struct {
    dest: LocalId,
    source: LocalId,
    mode: ShareMode = .retain,
};

pub const ParamGet = struct {
    dest: LocalId,
    index: u32,
};

pub const AggregateInit = struct {
    dest: LocalId,
    elements: []const LocalId,
    /// Static component types (one per element) when the tuple's type is
    /// known at IR build time. Used by the ZIR backend so that components
    /// promoted to `Term` (e.g. heterogeneous keyword-list pair values
    /// like `{Atom, Term}`) wrap concrete element values via `Term.from`.
    /// `null` for tuples where component types are not statically known.
    component_types: ?[]const ZigType = null,
};

pub const MapInit = struct {
    dest: LocalId,
    entries: []const MapEntry,
    key_type: ZigType = .atom,
    value_type: ZigType = .i64,
};

pub const MapEntry = struct {
    key: LocalId,
    value: LocalId,
};

pub const StructInit = struct {
    dest: LocalId,
    type_name: []const u8,
    fields: []const StructFieldInit,
};

pub const StructFieldInit = struct {
    name: []const u8,
    value: LocalId,
};

pub const UnionInit = struct {
    dest: LocalId,
    union_type: []const u8,
    variant_name: []const u8,
    value: LocalId,
};

pub const EnumLiteral = struct {
    dest: LocalId,
    type_name: []const u8,
    variant: []const u8,
};

pub const FieldGet = struct {
    dest: LocalId,
    object: LocalId,
    field: []const u8,
    /// Struct type name owning the field, when known. Used by
    /// the ZIR emitter to look up `FieldStorage` for indirect-
    /// storage auto-deref. `null` when the receiver's struct
    /// type isn't statically known (e.g. `term`/`any` or open
    /// generics).
    struct_type: ?[]const u8 = null,
};

pub const FieldSet = struct {
    object: LocalId,
    field: []const u8,
    value: LocalId,
};

pub const IndexGet = struct {
    dest: LocalId,
    object: LocalId,
    index: u32,
    /// When set, the extracted slot's runtime type is `zap_runtime.Term`
    /// but the IR's static expected type is concrete (the declared slot
    /// type from the parent's static tuple shape). The ZIR backend
    /// inserts a `Term.toCoerced(value, default)` to recover the concrete
    /// type. Used when patterns over heterogeneous keyword lists extract
    /// values from `tuple{Atom, Term}` slots where the user expected a
    /// concrete type per the declared param signature.
    coerce_term_to: ZigType = .any,
};

pub const ListInit = struct {
    dest: LocalId,
    elements: []const LocalId,
    element_type: ZigType = .i64,
};

pub const ListCons = struct {
    dest: LocalId,
    head: LocalId,
    tail: LocalId,
    element_type: ZigType = .i64,
};

pub const ListLenCheck = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected_len: u32,
    element_type: ZigType = .i64,
    /// Route through `listLength(anytype)` helper instead of
    /// `List(element_type).length(...)`. Set when `scrutinee` is
    /// param-backed (see ListGet.via_helper for rationale).
    via_helper: bool = false,
};

pub const ListGet = struct {
    dest: LocalId,
    list: LocalId,
    index: u32,
    element_type: ZigType = .i64,
    /// When true, the ZIR backend routes through the type-derived
    /// `listGet(anytype, index)` helper instead of
    /// `List(element_type).get(list, index)`. Set when `list` is
    /// param-backed: the runtime element type may diverge from the
    /// declared type (e.g. a function declared `[{Atom, i64}]` is
    /// passed a heterogeneous keyword list whose runtime element
    /// type is `[{Atom, Term}]`). The helper's `anytype` signature
    /// reads the actual element type from `@TypeOf(list)`.
    via_helper: bool = false,
};

pub const ListIsNotEmpty = struct {
    dest: LocalId,
    list: LocalId,
    element_type: ZigType = .i64,
    /// Route through `listIsEmpty(anytype)` helper instead of
    /// `List(element_type).isEmpty(...)`. Set when `list` is
    /// param-backed (see ListGet.via_helper for rationale).
    via_helper: bool = false,
};

pub const ListHeadTail = struct {
    dest: LocalId,
    list: LocalId,
    element_type: ZigType = .i64,
    /// Route through `listGetHead(anytype)` / `listGetTail(anytype)`
    /// helper instead of the typed `List(element_type)` method.
    /// Set when `list` is param-backed (see ListGet.via_helper).
    via_helper: bool = false,
};

pub const MapHasKey = struct {
    dest: LocalId,
    map: LocalId,
    key: LocalId,
    /// Type of map keys (used by ZIR to look up the right `Map(K, V)` cell).
    key_type: ZigType = .atom,
    /// Type of map values (carried for symmetry; not strictly required by `hasKey`).
    value_type: ZigType = .i64,
};

pub const MapGet = struct {
    dest: LocalId,
    map: LocalId,
    key: LocalId,
    default: LocalId,
    /// Type of map keys (used by ZIR to look up the right `Map(K, V)` cell).
    key_type: ZigType = .atom,
    /// Type of map values (used by ZIR to look up the right `Map(K, V)` cell).
    value_type: ZigType = .i64,
};

pub const GuardBlock = struct {
    condition: LocalId,
    body: []const Instruction,
};

pub const CaseBreak = struct {
    value: ?LocalId,
};

pub const CaseBlock = struct {
    dest: LocalId,
    pre_instrs: []const Instruction, // tuple arm guards (emit before regular arms)
    arms: []const IrCaseArm,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const IrCaseArm = struct {
    cond_instrs: []const Instruction,
    condition: LocalId,
    body_instrs: []const Instruction,
    result: ?LocalId,
};

pub const IfExpr = struct {
    dest: LocalId,
    condition: LocalId,
    then_instrs: []const Instruction,
    then_result: ?LocalId,
    else_instrs: []const Instruction,
    else_result: ?LocalId,
};

pub const BinaryOp = struct {
    dest: LocalId,
    op: Op,
    lhs: LocalId,
    rhs: LocalId,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        rem_op,
        eq,
        neq,
        string_eq,
        string_neq,
        lt,
        gt,
        lte,
        gte,
        bool_and,
        bool_or,
        concat,
        in_list,
        in_range,
    };
};

pub const UnaryOp = struct {
    dest: LocalId,
    op: Op,
    operand: LocalId,

    pub const Op = enum {
        negate,
        bool_not,
    };
};

pub const CallDirect = struct {
    dest: LocalId,
    function: FunctionId,
    clause_index: ?u32 = null,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

pub const CallNamed = struct {
    dest: LocalId,
    name: []const u8,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

pub const TailCall = struct {
    name: []const u8,
    args: []const LocalId,
};

pub const CallClosure = struct {
    dest: LocalId,
    callee: LocalId,
    args: []const LocalId,
    arg_modes: []const ValueMode,
    return_type: ZigType,
};

pub const CallDispatch = struct {
    dest: LocalId,
    group_id: u32,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

pub const CallBuiltin = struct {
    dest: LocalId,
    name: []const u8,
    args: []const LocalId,
    arg_modes: []const ValueMode,
};

/// Call a __try function variant. The result is an error union:
/// error{NoMatchingClause}!ReturnType.
///
/// Lowering invariant: the catch-basin pipeline is short-circuited at the
/// FIRST failing dispatched step. To express that without forcing a
/// `ret` (which would hijack the enclosing function's return), each
/// `try_call_named` carries the REST of the pipe in `success_instrs` /
/// `success_result`. The ZIR backend lowers the instruction as a single
/// if-else block whose value is the catch-basin expression value:
///   * then-branch: unwrap payload, run `success_instrs`, yield
///     `success_result` (which itself may be the dest of a nested
///     try_call_named for deeper pipelines).
///   * else-branch: run `handler_instrs`, yield `handler_result`.
/// When `success_instrs` is empty, the success value is simply the
/// unwrapped payload — the simple terminal-step case.
pub const TryCallNamed = struct {
    dest: LocalId, // holds the optional result (?ReturnType)
    name: []const u8, // the __try function name (already suffixed)
    args: []const LocalId,
    arg_modes: []const ValueMode,
    input_local: LocalId, // the pipe input — passed to handler on null
    handler_instrs: []const Instruction, // handler body instructions
    handler_result: ?LocalId, // handler result local
    /// Instructions to run in the success branch AFTER unwrapping the
    /// optional payload. When empty the success value is the payload itself.
    success_instrs: []const Instruction = &.{},
    /// Local that holds the value of the success branch after
    /// `success_instrs` runs. When `null`, the unwrapped payload is used
    /// directly (terminal step in the pipe).
    success_result: ?LocalId = null,
    /// Local that the unwrapped payload is bound to so that
    /// `success_instrs` can reference it. When `null`, the success
    /// branch does not need access to the payload.
    payload_local: ?LocalId = null,
};

/// Unwrap an error union from try_call_named.
/// dest = if source is success: unwrapped value, else: catch_value.
pub const ErrorCatch = struct {
    dest: LocalId, // the final unwrapped result
    source: LocalId, // the error union (from try_call_named)
    catch_value: LocalId, // value to use on error (handler result for the failed input)
};

pub const Branch = struct {
    target: LabelId,
};

pub const CondBranch = struct {
    condition: LocalId,
    then_target: LabelId,
    else_target: LabelId,
};

pub const SwitchTag = struct {
    scrutinee: LocalId,
    cases: []const TagCase,
    default: LabelId,
};

pub const TagCase = struct {
    tag: []const u8,
    target: LabelId,
};

pub const SwitchLiteral = struct {
    dest: LocalId,
    scrutinee: LocalId,
    cases: []const LitCase,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const LitCase = struct {
    value: LiteralValue,
    body_instrs: []const Instruction,
    result: ?LocalId,
};

pub const SwitchReturn = struct {
    scrutinee_param: u32,
    cases: []const ReturnCase,
    default_instrs: []const Instruction,
    default_result: ?LocalId,
};

pub const ReturnCase = struct {
    value: LiteralValue,
    body_instrs: []const Instruction,
    return_value: ?LocalId,
};

pub const UnionSwitchReturn = struct {
    scrutinee_param: u32,
    cases: []const UnionCase,
};

pub const UnionSwitch = struct {
    dest: LocalId,
    scrutinee: LocalId,
    cases: []const UnionCase,
};

/// Multi-clause `f(nil) / f(t :: T)` dispatch on an optional parameter.
/// Generated when `canOptionalDispatch` succeeds at function-group
/// lowering. The ZIR emitter expands this into:
///
///   if (param == null) { nil_instrs; ret nil_result }
///   else { payload_local = param.?; struct_instrs; ret struct_result }
///
/// `payload_local` is a fresh `LocalId` allocated by the IR builder.
/// References to the optional param inside the struct clause body still
/// emit `param_get(scrutinee_param)`; the ZIR emitter redirects those
/// reads to `payload_local` for the duration of the struct branch so
/// the user-visible `n :: T` binding sees the unwrapped value, not the
/// optional storage shape.
pub const OptionalDispatch = struct {
    scrutinee_param: u32,
    payload_local: LocalId,
    nil_instrs: []const Instruction,
    nil_result: ?LocalId,
    struct_instrs: []const Instruction,
    struct_result: ?LocalId,
};

pub const UnionCase = struct {
    variant_name: []const u8,
    field_bindings: []const FieldBinding,
    body_instrs: []const Instruction,
    return_value: ?LocalId,
};

pub const FieldBinding = struct {
    field_name: []const u8,
    local_name: []const u8,
    local_index: LocalId,
};

pub const NumericWiden = struct {
    dest: LocalId,
    source: LocalId,
    dest_type: ZigType,
};

pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool_val: bool,
};

pub const MatchAtom = struct {
    dest: LocalId,
    scrutinee: LocalId,
    atom_name: []const u8,
    skip_type_check: bool = false,
};

pub const MatchInt = struct {
    dest: LocalId,
    scrutinee: LocalId,
    value: i64,
    skip_type_check: bool = false,
};

pub const MatchFloat = struct {
    dest: LocalId,
    scrutinee: LocalId,
    value: f64,
    skip_type_check: bool = false,
};

pub const MatchString = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected: []const u8,
    skip_type_check: bool = false,
};

pub const MatchType = struct {
    dest: LocalId,
    scrutinee: LocalId,
    expected_type: ZigType,
    skip_type_check: bool = false,
    expected_arity: ?u32 = null,
};

pub const MatchFail = struct {
    message: []const u8,
    /// For panic expressions, the local holding the runtime message string.
    message_local: ?LocalId = null,
};

/// Like match_fail but returns error.NoMatchingClause instead of panicking.
/// Used in __try function variants for the ~> catch basin operator.
pub const MatchErrorReturn = struct {
    scrutinee: LocalId, // the unmatched value
};

pub const Return = struct {
    value: ?LocalId,
};

pub const CondReturn = struct {
    condition: LocalId,
    value: ?LocalId,
};

pub const Jump = struct {
    target: LabelId,
    value: ?LocalId = null,
    bind_dest: ?LocalId = null,
};

pub const MakeClosure = struct {
    dest: LocalId,
    function: FunctionId,
    captures: []const LocalId,
};

pub const CaptureGet = struct {
    dest: LocalId,
    index: u32,
};

pub const OptionalUnwrap = struct {
    dest: LocalId,
    source: LocalId,
};

pub const BinLenCheck = struct {
    dest: LocalId,
    scrutinee: LocalId,
    min_len: u32,
};

pub const BinReadInt = struct {
    dest: LocalId,
    source: LocalId,
    offset: BinOffset,
    bits: u16,
    signed: bool,
    endianness: ast.Endianness,
    bit_offset: u8 = 0, // bit offset within byte for sub-byte extractions
};

pub const BinReadFloat = struct {
    dest: LocalId,
    source: LocalId,
    offset: BinOffset,
    bits: u16,
    endianness: ast.Endianness,
};

pub const BinSlice = struct {
    dest: LocalId,
    source: LocalId,
    offset: BinOffset,
    length: ?BinOffset, // null = rest of data
};

pub const BinReadUtf8 = struct {
    dest_codepoint: LocalId,
    dest_len: LocalId,
    source: LocalId,
    offset: BinOffset,
};

pub const BinMatchPrefix = struct {
    dest: LocalId,
    source: LocalId,
    expected: []const u8,
};

pub const BinOffset = union(enum) {
    static: u32,
    dynamic: LocalId,
};

pub const Retain = struct {
    value: LocalId,
};

pub const Release = struct {
    value: LocalId,
};

/// Perceus: if RC=1, make memory available for reuse and return a reuse token.
/// If RC>1, decrement RC and return null token.
pub const Reset = struct {
    dest: LocalId, // reuse token
    source: LocalId, // value being deconstructed
};

/// Perceus: if reuse token is non-null, reuse memory for new allocation.
/// If token is null, allocate fresh.
pub const ReuseAlloc = struct {
    dest: LocalId, // newly allocated value
    token: ?LocalId, // reuse token from Reset (null = fresh alloc)
    constructor_tag: u32, // constructor tag for tagged unions
    dest_type: ZigType = .any,
};

pub const Phi = struct {
    dest: LocalId,
    sources: []const PhiSource,
};

pub const PhiSource = struct {
    from_block: LabelId,
    value: LocalId,
};

// ============================================================
// Zig types (for codegen)
// ============================================================

pub const ZigType = union(enum) {
    void,
    bool_type,
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,
    f16,
    f32,
    f64,
    f80,
    f128,
    usize,
    isize,
    string, // []const u8
    atom, // enum literal or interned string
    nil, // void or optional
    /// `runtime.Term` — heterogeneous value wrapper. Used as the
    /// element type of collections whose components have disagreeing
    /// static types (e.g. `%{name: "Alice", age: 30}`). Construction
    /// sites wrap via `Term.from(value)` and consumption sites unwrap
    /// via `Term.to(T, term, default)`.
    term,
    /// `?*const zap_runtime.MArrayOf(i64)` — concrete instantiation of
    /// the mutable, ARC-managed, pool-backed contiguous array. The
    /// runtime owns the cell layout (`Inner = { header, len, items }`);
    /// the source-Arc ABI sees `?*const Inner` everywhere and
    /// `@constCast`s once at write boundaries. Distinct from
    /// `marray_f64` because `MArrayOf(i64)` and `MArrayOf(f64)` are
    /// different Zig generic instantiations.
    marray_i64,
    /// `?*const zap_runtime.MArrayOf(f64)` — see `marray_i64`.
    marray_f64,
    tuple: []const ZigType,
    list: *const ZigType,
    map: MapType,
    struct_ref: []const u8,
    function: FnType,
    tagged_union: []const u8,
    optional: *const ZigType,
    ptr: *const ZigType,
    never, // noreturn — function that never returns (e.g., raise)
    any, // for generics

    pub const MapType = struct {
        key: *const ZigType,
        value: *const ZigType,
    };

    pub const FnType = struct {
        params: []const ZigType,
        return_type: *const ZigType,
    };
};

// ============================================================
// Public IR helpers — used by analysis passes (e.g. arc_liveness).
// ============================================================

/// Recognises the "default" ARC-managed-type set, mirroring
/// `IrBuilder.isArcManagedType`. Phase 6 of the k-nucleotide RSS gap
/// plan extends this to include `.map`. Exposed here so analysis
/// passes can share a single source of truth without instantiating
/// an IrBuilder.
pub fn isArcManagedTypeId(type_store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= type_store.types.items.len) return false;
    // Phase F (the k-nucleotide RSS gap milestone) flipped `.map` to
    // join `.opaque_type` as ARC-managed. Phases A–E.9 built the
    // substrate (param-convention inference, consume-site rewrites,
    // ownership-transfer-aware liveness, V1–V7 verifiers) so that
    // every `.map` value flows through the same retain/release ABI as
    // opaque types.
    //
    // Phase H.1 laid the runtime substrate (`List(T)` Arc-headered +
    // pool-allocated + deep retain/release). Phase H.2 closed the
    // Air/Liveness gap by scoping `guard_block` body ownership to
    // its own execution path so out-of-scope locals no longer leak
    // into the parent's `owns` set. Phase H.3 closed the runtime
    // ARC ABI gap in `List.next`, `List.getHead`, and `List.getTail`
    // (those ops returned `cell.head`/`cell.tail` without bumping
    // refcounts, which the IR's `.owned` result convention required;
    // the cell's owner-side deep-release on its zero-transition
    // raced with the caller's release of the same children and
    // produced double-frees). Phase H.4 — this flip — adds `.list`
    // to the ARC-managed-type set so List(T) values flow through
    // the same retain/release ABI as `.map` and `.opaque_type`.
    return switch (type_store.getType(type_id)) {
        .opaque_type, .map, .list => true,
        else => false,
    };
}

/// Default `ParamConvention` for a parameter of HIR type `type_id`.
/// Phase A of the Phase 6 redux plan classifies every ARC-managed
/// parameter as `.borrowed` (matching the existing caller-side
/// `share_value` + post-call `release` ABI) and every non-ARC
/// parameter as `.trivial`. When `type_store` is null (only the
/// in-process IrBuilder unit tests do this) every parameter falls
/// back to `.trivial` because we cannot determine ARC status without
/// the type table.
pub fn defaultParamConvention(
    type_store: ?*const types_mod.TypeStore,
    type_id: ?types_mod.TypeId,
) ParamConvention {
    const store = type_store orelse return .trivial;
    const tid = type_id orelse return .trivial;
    if (isArcManagedTypeId(store, tid)) return .borrowed;
    return .trivial;
}

/// Default `ResultConvention` for a return type of HIR type
/// `type_id`. ARC-managed return types receive `.owned` (the callee
/// returns an owner; the caller is responsible for destroying it on
/// every CFG path). Every other return type is `.trivial`.
pub fn defaultResultConvention(
    type_store: ?*const types_mod.TypeStore,
    type_id: ?types_mod.TypeId,
) ResultConvention {
    const store = type_store orelse return .trivial;
    const tid = type_id orelse return .trivial;
    if (isArcManagedTypeId(store, tid)) return .owned;
    return .trivial;
}

/// Walks every instruction in `function` (top-level and nested
/// inside structural sub-streams) in depth-first order, invoking
/// `visitor.visit(instruction_pointer)` for each. Used by analysis
/// passes that need to enumerate every instruction without
/// re-implementing the structural recursion.
pub fn forEachInstruction(
    function: *const Function,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), instr: *const Instruction) void,
) void {
    for (function.body) |block| {
        forEachInstructionInStream(block.instructions, context, visitFn);
    }
}

fn forEachInstructionInStream(
    stream: []const Instruction,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), instr: *const Instruction) void,
) void {
    for (stream) |*instr| {
        visitFn(context, instr);
        forEachInstructionChildren(instr, context, visitFn);
    }
}

fn forEachInstructionChildren(
    instr: *const Instruction,
    context: anytype,
    comptime visitFn: fn (ctx: @TypeOf(context), instr: *const Instruction) void,
) void {
    switch (instr.*) {
        .if_expr => |ie| {
            forEachInstructionInStream(ie.then_instrs, context, visitFn);
            forEachInstructionInStream(ie.else_instrs, context, visitFn);
        },
        .case_block => |cb| {
            forEachInstructionInStream(cb.pre_instrs, context, visitFn);
            for (cb.arms) |arm| {
                forEachInstructionInStream(arm.cond_instrs, context, visitFn);
                forEachInstructionInStream(arm.body_instrs, context, visitFn);
            }
            forEachInstructionInStream(cb.default_instrs, context, visitFn);
        },
        .switch_literal => |sl| {
            for (sl.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
            forEachInstructionInStream(sl.default_instrs, context, visitFn);
        },
        .switch_return => |sr| {
            for (sr.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
            forEachInstructionInStream(sr.default_instrs, context, visitFn);
        },
        .union_switch => |us| {
            for (us.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
        },
        .union_switch_return => |usr| {
            for (usr.cases) |c| forEachInstructionInStream(c.body_instrs, context, visitFn);
        },
        .try_call_named => |tc| {
            forEachInstructionInStream(tc.handler_instrs, context, visitFn);
            forEachInstructionInStream(tc.success_instrs, context, visitFn);
        },
        .guard_block => |gb| {
            forEachInstructionInStream(gb.body, context, visitFn);
        },
        .optional_dispatch => |od| {
            // Phase D (Phase 6 redux plan §3.D): recurse into both
            // arm bodies so any visitor — use-summary walker, drop
            // counter, verifier, IR dumper — sees every instruction
            // regardless of nesting. The arc-liveness analyzer and
            // arc-drop-insertion rebuilder use a separate region-tree
            // walk with their own InstructionId assignment, so this
            // helper's traversal order is orthogonal to theirs; it
            // is only required to be consistent (which it is — nil
            // first, then struct, mirroring the structural shape).
            forEachInstructionInStream(od.nil_instrs, context, visitFn);
            forEachInstructionInStream(od.struct_instrs, context, visitFn);
        },
        else => {},
    }
}

// ============================================================
// IR Builder — lowers HIR to IR
// ============================================================

pub const IrBuilder = struct {
    allocator: std.mem.Allocator,
    functions: std.ArrayList(Function),
    /// Separate ID counter for __try variants. Initialized in `buildProgram`
    /// to `max(group.id) + 1` over the input HIR groups so the variant IDs
    /// never collide with HIR-allocated group IDs regardless of program size.
    next_try_id: FunctionId = 0,
    next_local: LocalId,
    current_blocks: std.ArrayList(Block),
    current_instrs: std.ArrayList(Instruction),
    interner: *const ast.StringInterner,
    type_store: ?*const types_mod.TypeStore,
    /// Optional scope graph reference. Used to consult the native-type
    /// registry (`isNativeTypeName`, `nativeTypeStructName`) at IR-emit
    /// time — e.g. deciding whether `in` should lower to `in_range` or
    /// `in_list` based on whether the rhs is the registered Range type.
    /// The IR builder unit tests construct an IrBuilder without a
    /// scope graph, so call sites must guard for null.
    scope_graph: ?*const scope_mod.ScopeGraph = null,
    known_local_types: std.AutoHashMap(LocalId, ZigType),
    /// Maps `LocalId` -> the HIR `TypeId` of the value held in that
    /// local. Distinct from `known_local_types`, which carries the
    /// post-monomorphization Zig-level type. The HIR-level type is
    /// what `isArcManagedType` consults, so any analysis that needs
    /// to ask "is this local's value ARC-managed?" — including the
    /// `emitLocalGet` helper that decides whether a `.local_get`
    /// requires a follow-up `.retain` for independent ownership —
    /// must use this table. Populated at every site that produces a
    /// new local: param entries, `local_set`, every dest computed by
    /// `lowerExpr`, `local_get` aliases, and the four pattern-binding
    /// `local_get` sites in case / decision-tree lowering. Saved and
    /// restored across nested `function_group` blocks alongside
    /// `known_local_types`.
    local_hir_types: std.AutoHashMap(LocalId, hir_mod.TypeId),
    /// Locals whose value originated from a `param_get` instruction.
    /// Used by the call-builtin encoder to detect bridge calls inside
    /// generic Zap functions — those have `param: anytype` in the
    /// emitted Zig, so any post-monomorph nominal type (e.g.
    /// `Map(atom, string)`) cannot be safely burned into the call name
    /// because the runtime value may carry a different generic
    /// instantiation (e.g. `Map(atom, term)`). Locals in this set
    /// route through the runtime's type-derived helpers instead.
    param_backed_locals: std.AutoHashMap(LocalId, void),
    /// Tuple-typed locals whose components may have been Term-promoted
    /// because they were extracted via a `via_helper` list operation
    /// (heterogeneous keyword list flowing through `anytype`). When a
    /// later `index_get` reads from one of these locals, the IR emits
    /// `Term.toCoerced` to recover the declared concrete component type.
    term_tuple_locals: std.AutoHashMap(LocalId, ZigType),
    current_struct_prefix: ?[]const u8,
    known_function_names: std.StringHashMap(void),
    synthesized_type_defs: std.ArrayList(TypeDef),
    /// Maps function name → union dispatch info for call-site wrapping
    union_dispatch_map: std.StringHashMap(UnionDispatchInfo),
    /// When true, decision tree failure nodes emit match_error_return instead of match_fail.
    /// Used when generating __try function variants for the ~> catch basin operator.
    try_mode: bool = false,
    /// The original function's arity (number of params excluding the handler).
    /// The handler param is at index current_try_arity in the __try variant.
    current_try_arity: u32 = 0,
    /// Set of function names that need __try variants (populated by error pipe analysis).
    /// Only functions in this set will get __try variants generated.
    try_variant_names: std.StringHashMap(void),
    /// Optional whole-program HIR view used only for registering callable
    /// names during per-struct IR lowering. Emission still uses the
    /// `hir_program` passed to `buildProgram`.
    known_name_program: ?*const hir_mod.Program = null,
    /// HIR program currently being lowered. Used to recover concrete
    /// parameter types after monomorphization rewrites call targets to
    /// specialized function groups.
    current_hir_program: ?*const hir_mod.Program = null,
    /// Current function's declared param types (for param_get fallback when expr type is UNKNOWN).
    current_param_types: std.ArrayListUnmanaged(ZigType) = .empty,
    /// Current function's declared parameter HIR types, indexed by
    /// parameter position. Populated alongside `current_param_types`
    /// at clause prelude. Phase E.5 Gap 2: the body's `param_get`
    /// HIR-expression lowering consults this list to populate
    /// `local_hir_types[dest]` with the canonical param HIR type
    /// even when the source HIR expression's `type_id` was set to
    /// `UNKNOWN` (which happens for some monomorphized / type-erased
    /// signatures). Without this fallback `local_ownership` for the
    /// param-bound dest local is `.trivial` and the verifier never
    /// classifies the param read as ARC-managed.
    current_param_hir_types: std.ArrayListUnmanaged(hir_mod.TypeId) = .empty,
    /// Contextual type supplied by a call argument slot while lowering the
    /// argument expression. Used for empty container literals whose own HIR
    /// type is intentionally underconstrained.
    current_expected_type: ?types_mod.TypeId = null,

    pub const UnionDispatchInfo = struct {
        param_idx: u32,
        union_type_name: []const u8,
        /// Maps variant type name → variant name in the union
        variants: std.StringHashMap(void),
    };

    const TypedClauseResolution = struct {
        declared_arity: u32,
        clause_index: u32,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) IrBuilder {
        return .{
            .allocator = allocator,
            .functions = .empty,
            .next_local = 0,
            .current_blocks = .empty,
            .current_instrs = .empty,
            .interner = interner,
            .type_store = null,
            .known_local_types = std.AutoHashMap(LocalId, ZigType).init(allocator),
            .local_hir_types = std.AutoHashMap(LocalId, hir_mod.TypeId).init(allocator),
            .param_backed_locals = std.AutoHashMap(LocalId, void).init(allocator),
            .term_tuple_locals = std.AutoHashMap(LocalId, ZigType).init(allocator),
            .current_struct_prefix = null,
            .known_function_names = std.StringHashMap(void).init(allocator),
            .synthesized_type_defs = .empty,
            .union_dispatch_map = std.StringHashMap(UnionDispatchInfo).init(allocator),
            .try_variant_names = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        self.functions.deinit(self.allocator);
        self.current_blocks.deinit(self.allocator);
        self.current_instrs.deinit(self.allocator);
        self.known_local_types.deinit();
        self.local_hir_types.deinit();
        self.param_backed_locals.deinit();
        self.term_tuple_locals.deinit();
        self.synthesized_type_defs.deinit(self.allocator);
        self.union_dispatch_map.deinit();
        self.known_function_names.deinit();
    }

    fn localBackedByParam(self: *const IrBuilder, local: LocalId) bool {
        return self.param_backed_locals.contains(local);
    }

    fn hirFunctionGroupById(self: *const IrBuilder, group_id: FunctionId) ?*const hir_mod.FunctionGroup {
        const program = self.current_hir_program orelse return null;
        for (program.structs) |*struct_info| {
            for (struct_info.functions) |*function_group| {
                if (function_group.id == group_id) return function_group;
            }
        }
        for (program.top_functions) |*function_group| {
            if (function_group.id == group_id) return function_group;
        }
        return null;
    }

    fn resolveNamedHirGroup(self: *const IrBuilder, named: hir_mod.NamedCall, arity: u32) ?*const hir_mod.FunctionGroup {
        const target_struct = named.struct_name orelse return null;
        const program = self.current_hir_program orelse return null;
        for (program.structs) |*struct_info| {
            if (struct_info.name.parts.len == 0) continue;
            const last_part = self.interner.get(struct_info.name.parts[struct_info.name.parts.len - 1]);
            if (!std.mem.eql(u8, last_part, target_struct)) continue;
            for (struct_info.functions) |*function_group| {
                if (function_group.arity == arity and
                    std.mem.eql(u8, self.interner.get(function_group.name), named.name))
                {
                    return function_group;
                }
            }
        }
        return null;
    }

    fn callTargetExpectedType(
        self: *const IrBuilder,
        target: hir_mod.CallTarget,
        arg_count: usize,
        arg_index: usize,
    ) ?types_mod.TypeId {
        const group_id = switch (target) {
            .direct => |direct| direct.function_group_id,
            .dispatch => |dispatch| dispatch.function_group_id,
            .named => |named| blk: {
                const resolved = self.resolveNamedHirGroup(named, @intCast(arg_count)) orelse return null;
                break :blk resolved.id;
            },
            else => return null,
        };
        const group = self.hirFunctionGroupById(group_id) orelse return null;
        if (group.clauses.len == 0) return null;
        if (arg_index >= group.clauses[0].params.len) return null;
        return group.clauses[0].params[arg_index].type_id;
    }

    fn listElementTypeFromHirMaybe(self: *const IrBuilder, type_id: types_mod.TypeId) ?ZigType {
        const ts = self.type_store orelse return .i64;
        if (type_id >= ts.types.items.len) return .i64;
        const typ = ts.types.items[type_id];
        return switch (typ) {
            .list => |lt| typeIdToZigTypeWithStore(lt.element, self.type_store),
            else => null,
        };
    }

    /// Extract the list element ZigType from an HIR expression's type_id.
    /// Returns .i64 as default when type info is unavailable or not a list type.
    fn listElementTypeFromHir(self: *const IrBuilder, type_id: types_mod.TypeId) ZigType {
        return self.listElementTypeFromHirMaybe(type_id) orelse .i64;
    }

    fn listTypeFromElement(self: *const IrBuilder, element_type: ZigType) !ZigType {
        const element_ptr = try self.allocator.create(ZigType);
        element_ptr.* = element_type;
        return .{ .list = element_ptr };
    }

    fn listTypeFromHirOrElement(self: *const IrBuilder, type_id: types_mod.TypeId, element_type: ZigType) !ZigType {
        if (self.listElementTypeFromHirMaybe(type_id)) |hir_element_type| {
            if (hir_element_type != .any or element_type == .any) {
                return typeIdToZigTypeWithStore(type_id, self.type_store);
            }
        }
        if (self.current_expected_type) |expected_type| {
            if (self.listElementTypeFromHirMaybe(expected_type)) |expected_element_type| {
                if (expected_element_type != .any or element_type == .any) {
                    return typeIdToZigTypeWithStore(expected_type, self.type_store);
                }
            }
        }
        return try self.listTypeFromElement(element_type);
    }

    fn chooseListElementType(self: *const IrBuilder, hir_type_id: types_mod.TypeId, fallback_type: ZigType) ZigType {
        if (self.listElementTypeFromHirMaybe(hir_type_id)) |hir_element_type| {
            if (hir_element_type != .any or fallback_type == .any) {
                return hir_element_type;
            }
        }
        if (self.current_expected_type) |expected_type| {
            if (self.listElementTypeFromHirMaybe(expected_type)) |expected_element_type| {
                if (expected_element_type != .any or fallback_type == .any) {
                    return expected_element_type;
                }
            }
        }
        return fallback_type;
    }

    fn listElementTypeFromLocal(self: *const IrBuilder, local: LocalId) ?ZigType {
        if (self.known_local_types.get(local)) |local_type| {
            return local_type;
        }
        return null;
    }

    fn listElementTypeFromTailLocal(self: *const IrBuilder, tail: LocalId) ?ZigType {
        if (self.known_local_types.get(tail)) |tail_type| {
            if (tail_type == .list) {
                return tail_type.list.*;
            }
        }
        return null;
    }

    fn closureReturnType(self: *const IrBuilder, expr_type: types_mod.TypeId, callee: LocalId) ZigType {
        const expr_zig_type = typeIdToZigTypeWithStore(expr_type, self.type_store);
        if (expr_zig_type != .any) return expr_zig_type;
        if (self.known_local_types.get(callee)) |callee_type| {
            if (callee_type == .function) {
                return callee_type.function.return_type.*;
            }
        }
        return expr_zig_type;
    }

    /// Extract the list element ZigType from a local's known type.
    /// Falls back to .i64 when the local's type is unknown or not a list.
    fn listElementTypeForLocal(self: *const IrBuilder, local: LocalId) ZigType {
        const known = self.known_local_types.get(local) orelse return .i64;
        return switch (std.meta.activeTag(known)) {
            .list => known.list.*,
            else => .i64,
        };
    }

    /// Resolve the nominal struct type name owning a `field_get`'s
    /// receiver, when the local's static type is a struct (or an
    /// optional/pointer to one). Returns the struct name string the
    /// ZIR emitter can hand to `findStructDef`. `null` means the
    /// receiver's struct identity isn't statically known — fall back
    /// to the un-derefed `field_val` path.
    fn structTypeForFieldReceiver(self: *const IrBuilder, local: LocalId) ?[]const u8 {
        const known = self.known_local_types.get(local) orelse return null;
        return zigTypeStructName(known);
    }

    /// Look up the source-level field type and storage strategy for a
    /// field on a struct whose def already lives in the TypeStore.
    /// Returns null when the struct or field can't be resolved (e.g.
    /// generic shapes, missing TypeStore). The ZIR emitter uses the
    /// returned `ZigType` to drive the source-level type the indirect
    /// auto-deref must produce.
    fn fieldZigTypeAndStorage(self: *const IrBuilder, struct_name: []const u8, field_name: []const u8) ?struct {
        type_expr: ZigType,
        storage: FieldStorage,
    } {
        const ts = self.type_store orelse return null;
        for (ts.types.items) |typ| {
            if (typ != .struct_type) continue;
            const st = typ.struct_type;
            const owner = self.interner.get(st.name);
            if (!std.mem.eql(u8, owner, struct_name)) continue;
            for (st.fields) |f| {
                const fname = self.interner.get(f.name);
                if (!std.mem.eql(u8, fname, field_name)) continue;
                const field_zig_type = typeIdToZigTypeWithStore(f.type_id, self.type_store);
                // Use the SCC-aware walker so mutual recursion (`A
                // → B → A`) gets the same `.indirect` storage that
                // self-recursion already does.
                const reaches_cycle = zigTypeReachesStructInCycle(self.allocator, field_zig_type, owner, ts, self.interner) catch
                    zigTypeReachesStruct(field_zig_type, owner);
                const storage: FieldStorage = if (reaches_cycle) .indirect else .direct;
                return .{ .type_expr = field_zig_type, .storage = storage };
            }
        }
        return null;
    }

    /// True iff `name_id` (a struct's StringId) refers to the stdlib
    /// struct that opted in to `@native_type = "range"`. Used by `in_op`
    /// lowering to choose between `in_range` and `in_list`. Returns
    /// false when no scope graph is attached (IR unit-test path) — in
    /// that case the caller falls back to `in_list`, which is the safe
    /// default for non-Range right-hand sides.
    fn isNativeRangeStruct(self: *const IrBuilder, name_id: ast.StringId) bool {
        const graph = self.scope_graph orelse return false;
        const registered = graph.nativeTypeStructName(.range) orelse return false;
        return registered == name_id or std.mem.eql(u8, self.interner.get(registered), self.interner.get(name_id));
    }

    pub fn buildProgram(self: *IrBuilder, hir_program: *const hir_mod.Program) !Program {
        const saved_hir_program = self.current_hir_program;
        self.current_hir_program = hir_program;
        defer self.current_hir_program = saved_hir_program;

        // First pass: register all qualified function names for bare call resolution.
        // Mangle the raw symbol so operator-named functions (`+`, `<>`, etc.) become
        // valid Zig identifiers; downstream lookups always go through the same mangler
        // so call sites and declarations see the same string. Also compute the upper
        // bound on HIR group IDs so `__try` variant IDs can be assigned past the
        // largest existing group without collision (regardless of program size).
        var max_group_id: FunctionId = 0;
        const name_program = self.known_name_program orelse hir_program;
        for (name_program.structs) |mod| {
            const struct_prefix = self.structNameToPrefix(mod.name);
            for (mod.functions) |func_group| {
                if (func_group.id > max_group_id) max_group_id = func_group.id;
                const func_name = self.interner.get(func_group.name);
                const mangled_func_name = try mangleSymbolForZig(self.allocator, func_name);
                if (self.type_store != null and self.isTypeOnlyOverloadGroup(&func_group)) {
                    for (func_group.clauses, 0..) |_, clause_index| {
                        const qualified = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}__{s}__{d}__clause_{d}",
                            .{ struct_prefix, mangled_func_name, func_group.arity, clause_index },
                        );
                        try self.known_function_names.put(qualified, {});
                    }
                } else {
                    const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ struct_prefix, mangled_func_name, func_group.arity });
                    try self.known_function_names.put(qualified, {});
                }
            }
        }
        for (name_program.top_functions) |func_group| {
            if (func_group.id > max_group_id) max_group_id = func_group.id;
            const func_name = self.interner.get(func_group.name);
            const mangled_func_name = try mangleSymbolForZig(self.allocator, func_name);
            if (self.type_store != null and self.isTypeOnlyOverloadGroup(&func_group)) {
                for (func_group.clauses, 0..) |_, clause_index| {
                    const qualified = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}__{d}__clause_{d}",
                        .{ mangled_func_name, func_group.arity, clause_index },
                    );
                    try self.known_function_names.put(qualified, {});
                }
            } else {
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled_func_name, func_group.arity });
                try self.known_function_names.put(qualified, {});
            }
        }
        // The per-struct IR build path computes `max_group_id` from
        // *this struct's* HIR only. To prevent `__try` IDs from
        // colliding with regular HIR IDs in *other* structs (the IR
        // eventually merges all structs' functions into one program),
        // the caller may pre-seed `next_try_id` with a globally-safe
        // offset. Only fall back to `max_group_id + 1` when the
        // caller hasn't seeded a value.
        if (self.next_try_id <= max_group_id) {
            self.next_try_id = max_group_id + 1;
        }

        // Second pass: pre-scan for ~> error pipe chains to identify functions
        // that need __try variants. This must happen before building function bodies
        // so that __try variants are generated during buildFunctionGroup.
        for (hir_program.structs) |mod| {
            const struct_prefix = self.structNameToPrefix(mod.name);
            for (mod.functions) |func_group| {
                for (func_group.clauses) |clause| {
                    try self.scanForTryVariantNames(clause.body, struct_prefix);
                }
            }
        }
        for (hir_program.top_functions) |func_group| {
            for (func_group.clauses) |clause| {
                try self.scanForTryVariantNames(clause.body, null);
            }
        }

        // Fourth pass: build function bodies
        for (hir_program.structs) |mod| {
            const struct_prefix = self.structNameToPrefix(mod.name);
            self.current_struct_prefix = struct_prefix;
            for (mod.functions) |func_group| {
                try self.buildFunctionGroup(&func_group);
            }
        }
        self.current_struct_prefix = null;
        for (hir_program.top_functions) |func_group| {
            try self.buildFunctionGroup(&func_group);
        }

        // Build type definitions from TypeStore
        var type_defs: std.ArrayList(TypeDef) = .empty;
        if (self.type_store) |ts| {
            for (ts.types.items) |typ| {
                switch (typ) {
                    .struct_type => |st| {
                        const owner_name = self.interner.get(st.name);
                        var fields: std.ArrayList(StructFieldDef) = .empty;
                        for (st.fields) |field| {
                            const default_val: ?DefaultValue = if (field.default_expr) |expr| self.extractDefaultValue(expr) else null;
                            const field_zig_type = typeIdToZigTypeWithStore(field.type_id, self.type_store);
                            // Use the SCC-aware walker so mutual recursion
                            // (`A → B → A`) gets `.indirect` storage just
                            // like self-recursion does. Falls back to the
                            // shallow check on allocator failure.
                            const reaches_cycle = zigTypeReachesStructInCycle(self.allocator, field_zig_type, owner_name, ts, self.interner) catch
                                zigTypeReachesStruct(field_zig_type, owner_name);
                            const storage: FieldStorage = if (reaches_cycle) .indirect else .direct;
                            try fields.append(self.allocator, .{
                                .name = self.interner.get(field.name),
                                .type_expr = field_zig_type,
                                .default_value = default_val,
                                .storage = storage,
                            });
                        }
                        try type_defs.append(self.allocator, .{
                            .name = self.interner.get(st.name),
                            .kind = .{ .struct_def = .{
                                .fields = try fields.toOwnedSlice(self.allocator),
                            } },
                        });
                    },
                    .tagged_union => |tu| {
                        // Check if any variant carries data
                        var has_data = false;
                        for (tu.variants) |v| {
                            if (v.type_id != null) {
                                has_data = true;
                                break;
                            }
                        }
                        if (has_data) {
                            // Emit as union(enum) with typed variants
                            var union_variants: std.ArrayList(UnionVariant) = .empty;
                            for (tu.variants) |v| {
                                const type_str = if (v.type_id) |tid| blk: {
                                    // Use ZIR-correct type names (atoms are u32 IDs in ZIR)
                                    if (tid == types_mod.TypeStore.ATOM) break :blk @as([]const u8, "u32");
                                    break :blk typeIdToZigTypeStrWithStore(tid, self.type_store);
                                } else "void";
                                try union_variants.append(self.allocator, .{
                                    .name = self.interner.get(v.name),
                                    .type_name = type_str,
                                });
                            }
                            try type_defs.append(self.allocator, .{
                                .name = self.interner.get(tu.name),
                                .kind = .{ .union_def = .{
                                    .variants = try union_variants.toOwnedSlice(self.allocator),
                                } },
                            });
                        } else {
                            // All unit variants — emit as plain enum
                            var variants: std.ArrayList([]const u8) = .empty;
                            for (tu.variants) |v| {
                                try variants.append(self.allocator, self.interner.get(v.name));
                            }
                            try type_defs.append(self.allocator, .{
                                .name = self.interner.get(tu.name),
                                .kind = .{ .enum_def = .{
                                    .variants = try variants.toOwnedSlice(self.allocator),
                                } },
                            });
                        }
                    },
                    else => {},
                }
            }
        }

        // Append synthesized union type definitions
        for (self.synthesized_type_defs.items) |synth_td| {
            try type_defs.append(self.allocator, synth_td);
        }

        return .{
            .functions = try self.functions.toOwnedSlice(self.allocator),
            .type_defs = try type_defs.toOwnedSlice(self.allocator),
            .entry = null,
        };
    }

    /// Extract a compile-time constant from an AST default expression.
    fn extractDefaultValue(self: *IrBuilder, expr: *const @import("ast.zig").Expr) ?DefaultValue {
        return switch (expr.*) {
            .int_literal => |il| .{ .int = il.value },
            .float_literal => |fl| .{ .float = fl.value },
            .bool_literal => |bl| .{ .bool_val = bl.value },
            .string_literal => |sl| .{ .string = self.interner.get(sl.value) },
            .nil_literal => .nil,
            else => null,
        };
    }

    fn isTypeOnlyOverloadGroup(self: *const IrBuilder, group: *const hir_mod.FunctionGroup) bool {
        if (group.clauses.len < 2) return false;
        for (group.clauses) |clause| {
            if (clause.refinement != null) return false;
            for (clause.params) |param| {
                if (param.pattern) |pattern| {
                    switch (pattern.*) {
                        .bind, .wildcard => {},
                        else => return false,
                    }
                }
            }
        }
        for (0..group.arity) |param_index| {
            const first_type = group.clauses[0].params[param_index].type_id;
            for (group.clauses[1..]) |clause| {
                if (param_index >= clause.params.len) continue;
                if (!self.type_store.?.typeEquals(first_type, clause.params[param_index].type_id)) return true;
            }
        }
        return false;
    }

    fn typeOnlyClauseMatchCost(self: *const IrBuilder, clause: *const hir_mod.Clause, call_arity: usize, args: []const hir_mod.CallArg) ?u32 {
        const ts = self.type_store orelse return null;
        if (args.len < call_arity) return null;
        if (clause.params.len < call_arity) return null;

        var total: u32 = 0;
        for (args[0..call_arity], clause.params[0..call_arity]) |arg, param| {
            const cost = ts.callMatchCost(arg.expr.type_id, param.type_id) orelse return null;
            total +|= cost;
        }
        return total;
    }

    fn selectTypeOnlyNamedClause(
        self: *IrBuilder,
        struct_prefix: []const u8,
        function_name: []const u8,
        call_arity: usize,
        args: []const hir_mod.CallArg,
        requested_clause_index: ?u32,
    ) ?TypedClauseResolution {
        _ = self.type_store orelse return null;
        const program = self.known_name_program orelse return null;

        var best: ?TypedClauseResolution = null;
        var best_cost: u32 = std.math.maxInt(u32);

        for (program.structs) |candidate_struct| {
            const candidate_prefix = self.structNameToPrefix(candidate_struct.name);
            if (!std.mem.eql(u8, candidate_prefix, struct_prefix)) continue;

            for (candidate_struct.functions) |function_group| {
                if (!std.mem.eql(u8, self.interner.get(function_group.name), function_name)) continue;
                const declared_arity: usize = @intCast(function_group.arity);
                if (declared_arity < call_arity) continue;
                if (declared_arity > call_arity + 4) continue;
                if (!self.isTypeOnlyOverloadGroup(&function_group)) continue;

                if (requested_clause_index) |clause_index| {
                    const clause_index_usize: usize = @intCast(clause_index);
                    if (clause_index_usize >= function_group.clauses.len) continue;
                    const clause = &function_group.clauses[clause_index_usize];
                    _ = self.typeOnlyClauseMatchCost(clause, call_arity, args) orelse continue;
                    return .{
                        .declared_arity = function_group.arity,
                        .clause_index = clause_index,
                    };
                }

                for (function_group.clauses, 0..) |*clause, clause_index| {
                    const cost = self.typeOnlyClauseMatchCost(clause, call_arity, args) orelse continue;
                    if (best == null or cost < best_cost) {
                        best = .{
                            .declared_arity = function_group.arity,
                            .clause_index = @intCast(clause_index),
                        };
                        best_cost = cost;
                        if (cost == 0) return best;
                    }
                }
            }
        }

        return best;
    }

    fn buildTypedClauseEntrypoint(self: *IrBuilder, group: *const hir_mod.FunctionGroup, clause: *const hir_mod.Clause, clause_index: u32) !void {
        const func_id = self.next_try_id;
        self.next_try_id += 1;

        self.next_local = 0;
        self.current_instrs = .empty;
        self.known_local_types.clearRetainingCapacity();
        self.local_hir_types.clearRetainingCapacity();
        self.param_backed_locals.clearRetainingCapacity();
        self.term_tuple_locals.clearRetainingCapacity();
        self.current_param_types = .empty;
        self.current_param_hir_types = .empty;

        var captures: std.ArrayList(Capture) = .empty;
        for (group.captures, 0..) |capture, idx| {
            const cap_name = try std.fmt.allocPrint(self.allocator, "__cap_{d}", .{idx});
            try captures.append(self.allocator, .{
                .name = cap_name,
                .type_expr = typeIdToZigTypeWithStore(capture.type_id, self.type_store),
                .ownership = capture.ownership,
            });
        }

        var params: std.ArrayList(Param) = .empty;
        for (clause.params, 0..) |param, i| {
            const name = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{i});
            const resolved_type = typeIdToZigTypeWithStore(param.type_id, self.type_store);
            try params.append(self.allocator, .{
                .name = name,
                .type_expr = resolved_type,
                .type_id = param.type_id,
            });
            try self.current_param_types.append(self.allocator, resolved_type);
            try self.current_param_hir_types.append(self.allocator, param.type_id);
        }

        const single_clause = [_]hir_mod.Clause{clause.*};
        self.next_local = computeMaxBindingLocalForClauses(single_clause[0..]);
        try self.emitTupleBindings(clause);
        try self.emitStructBindings(clause);
        try self.emitBinaryBindings(clause);
        try self.emitMapBindings(clause);
        const result_local = try self.lowerBlock(clause.body);
        try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
        const entry_instrs = try self.current_instrs.toOwnedSlice(self.allocator);

        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const mangled_raw_name = try mangleSymbolForZig(self.allocator, raw_name);
        const local_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}__clause_{d}", .{ mangled_raw_name, group.arity, clause_index });
        const name_str = if (self.current_struct_prefix) |prefix|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, local_name })
        else
            local_name;

        try self.known_function_names.put(name_str, {});
        const final_params_typed = try params.toOwnedSlice(self.allocator);
        const param_conventions = try self.computeParamConventions(final_params_typed);
        const local_ownership = try self.computeLocalOwnership(self.next_local);
        const result_convention = self.computeResultConvention(clause.return_type);
        try self.functions.append(self.allocator, .{
            .id = func_id,
            .name = name_str,
            .source_group_id = group.id,
            .source_clause_index = clause_index,
            .struct_name = self.current_struct_prefix,
            .local_name = local_name,
            .scope_id = group.scope_id,
            .arity = group.arity,
            .params = final_params_typed,
            .return_type = typeIdToZigTypeWithStore(clause.return_type, self.type_store),
            .return_type_id = clause.return_type,
            .body = try self.allocSlice(Block, &.{.{
                .label = 0,
                .instructions = entry_instrs,
            }}),
            .is_closure = group.captures.len > 0,
            .captures = try captures.toOwnedSlice(self.allocator),
            .local_count = self.next_local,
            .param_conventions = param_conventions,
            .local_ownership = local_ownership,
            .result_convention = result_convention,
        });
    }

    fn buildFunctionGroup(self: *IrBuilder, group: *const hir_mod.FunctionGroup) !void {
        if (group.clauses.len == 0) return;

        // Skip generic (unmonomorphized) functions — they contain type variables
        // that can't be lowered to concrete IR types. Only the monomorphized copies
        // (produced by the monomorphization pass) should be compiled.
        if (self.type_store) |ts| {
            if (isGenericHirGroup(ts, group)) return;
        }

        if (self.type_store != null and self.isTypeOnlyOverloadGroup(group)) {
            for (group.clauses, 0..) |*clause, clause_index| {
                try self.buildTypedClauseEntrypoint(group, clause, @intCast(clause_index));
            }
            return;
        }

        const func_id: FunctionId = group.id;
        self.next_local = 0;
        self.current_instrs = .empty;
        self.known_local_types.clearRetainingCapacity();
        self.local_hir_types.clearRetainingCapacity();
        self.param_backed_locals.clearRetainingCapacity();
        self.term_tuple_locals.clearRetainingCapacity();
        self.current_param_types = .empty;
        self.current_param_hir_types = .empty;

        // Use first clause for arity and return type
        const first_clause = &group.clauses[0];

        // Build params with generic names (__arg_N).
        // If all clauses agree on a param's type, use that type.
        // If clauses have different struct types, synthesize a union.
        // Otherwise fall back to anytype.
        var params: std.ArrayList(Param) = .empty;
        var union_param_idx: ?u32 = null;
        var optional_param_idx: ?u32 = null;
        var optional_struct_name: ?[]const u8 = null;
        var captures: std.ArrayList(Capture) = .empty;
        for (group.captures, 0..) |capture, idx| {
            const cap_name = try std.fmt.allocPrint(self.allocator, "__cap_{d}", .{idx});
            try captures.append(self.allocator, .{
                .name = cap_name,
                .type_expr = typeIdToZigTypeWithStore(capture.type_id, self.type_store),
                .ownership = capture.ownership,
            });
        }
        for (first_clause.params, 0..) |param, i| {
            const name = try std.fmt.allocPrint(self.allocator, "__arg_{d}", .{i});
            var resolved_type = typeIdToZigTypeWithStore(param.type_id, self.type_store);
            if (group.clauses.len > 1) {
                for (group.clauses[1..]) |clause| {
                    if (i < clause.params.len) {
                        const other_type = typeIdToZigTypeWithStore(clause.params[i].type_id, self.type_store);
                        const tags_differ = std.meta.activeTag(other_type) != std.meta.activeTag(resolved_type);
                        // Also check if both are struct_ref but with different names
                        const struct_names_differ = if (resolved_type == .struct_ref and other_type == .struct_ref)
                            !std.mem.eql(u8, resolved_type.struct_ref, other_type.struct_ref)
                        else
                            false;
                        if (tags_differ or struct_names_differ) {
                            // Check if this is a union synthesis candidate
                            if (try self.canUnionDispatch(group, @intCast(i))) |union_type_name| {
                                resolved_type = .{ .struct_ref = union_type_name };
                                union_param_idx = @intCast(i);
                            } else if (self.canOptionalDispatch(group, @intCast(i))) |sname| {
                                // f(nil) / f(t :: T) shape — unify the
                                // param to `?T` and route via
                                // optional_dispatch IR.
                                const inner_ptr = try self.allocator.create(ZigType);
                                inner_ptr.* = .{ .struct_ref = sname };
                                resolved_type = .{ .optional = inner_ptr };
                                optional_param_idx = @intCast(i);
                                optional_struct_name = sname;
                            } else {
                                resolved_type = .any;
                            }
                            break;
                        }
                    }
                }
            }
            try params.append(self.allocator, .{
                .name = name,
                .type_expr = resolved_type,
                .type_id = param.type_id,
            });
            try self.current_param_types.append(self.allocator, resolved_type);
            try self.current_param_hir_types.append(self.allocator, param.type_id);
        }

        // Reserve local indices used by destructure bindings across all clauses.
        // These locals are defined inside guard_blocks (separate Zig scopes),
        // so top-level code must start allocating ABOVE this range.
        self.next_local = computeMaxBindingLocalForClauses(group.clauses);

        var uses_decision_tree = false;

        if (group.clauses.len == 1) {
            // Single clause — no dispatch needed
            // Emit tuple/struct/binary/map bindings if present
            try self.emitTupleBindings(first_clause);
            try self.emitStructBindings(first_clause);
            try self.emitBinaryBindings(first_clause);
            try self.emitMapBindings(first_clause);
            const result_local = try self.lowerBlock(first_clause.body);
            try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
        } else if (self.canSwitchDispatch(group)) |switch_param| {
            // Emit switch_return for integer literal dispatch
            var return_cases: std.ArrayList(ReturnCase) = .empty;
            var default_instrs_result: []const Instruction = &.{};
            var default_result: ?LocalId = null;

            for (group.clauses, 0..) |clause, clause_idx| {
                const is_last = clause_idx == group.clauses.len - 1;

                if (is_last) {
                    // Default clause — lower body into default_instrs
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.emitTupleBindings(&clause);
                    try self.emitStructBindings(&clause);
                    const result_local = try self.lowerBlock(clause.body);
                    default_instrs_result = try self.current_instrs.toOwnedSlice(self.allocator);
                    default_result = result_local;
                    self.current_instrs = saved;
                } else {
                    // Literal case
                    const pat = clause.params[switch_param].pattern.?;
                    const lit_value: LiteralValue = switch (pat.literal) {
                        .int => |v| .{ .int = v },
                        else => unreachable,
                    };

                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    const body_result = try self.lowerBlock(clause.body);
                    const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;

                    try return_cases.append(self.allocator, .{
                        .value = lit_value,
                        .body_instrs = body_instrs,
                        .return_value = body_result,
                    });
                }
            }

            try self.current_instrs.append(self.allocator, .{
                .switch_return = .{
                    .scrutinee_param = switch_param,
                    .cases = try return_cases.toOwnedSlice(self.allocator),
                    .default_instrs = default_instrs_result,
                    .default_result = default_result,
                },
            });
        } else if (union_param_idx) |u_param_idx| {
            // Union switch dispatch for struct type patterns
            var union_cases: std.ArrayList(UnionCase) = .empty;

            for (group.clauses) |clause| {
                const param = clause.params[u_param_idx];
                const variant_name = blk: {
                    if (param.pattern) |pat| {
                        if (pat.* == .struct_match) {
                            break :blk self.interner.get(pat.struct_match.type_name);
                        }
                    }
                    break :blk self.resolveTypeName(param.type_id);
                };

                // Build field bindings from struct_bindings on the clause
                var field_bindings: std.ArrayList(FieldBinding) = .empty;
                for (clause.struct_bindings) |sb| {
                    if (sb.param_index == u_param_idx) {
                        try field_bindings.append(self.allocator, .{
                            .field_name = self.interner.get(sb.field_name),
                            .local_name = try std.fmt.allocPrint(self.allocator, "__local_{d}", .{sb.local_index}),
                            .local_index = sb.local_index,
                        });
                    }
                }

                // Lower body
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                const body_result = try self.lowerBlock(clause.body);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                try union_cases.append(self.allocator, .{
                    .variant_name = variant_name,
                    .field_bindings = try field_bindings.toOwnedSlice(self.allocator),
                    .body_instrs = body_instrs,
                    .return_value = body_result,
                });
            }

            try self.current_instrs.append(self.allocator, .{
                .union_switch_return = .{
                    .scrutinee_param = u_param_idx,
                    .cases = try union_cases.toOwnedSlice(self.allocator),
                },
            });
        } else if (optional_param_idx) |o_param_idx| {
            // f(nil) / f(t :: T) optional dispatch. Lower each clause's
            // body separately. The struct clause's body must observe the
            // param as `T`, not `?T` — track `payload_local` so the ZIR
            // emitter can redirect `param_get(o_param_idx)` reads to it
            // while emitting the struct branch.
            //
            // `payload_local` is allocated AFTER the bodies are lowered.
            // HIR resets its own `next_local` to 0 per clause, so any
            // body bindings (`one = 1 :: i64`, etc.) get IDs starting at
            // 0 and march upward. Allocating payload_local up front
            // would collide with that range — `setLocal(payload_local,
            // payload_ref)` and the body's `local_set dest=0 value=...`
            // would write the same slot, and the ZIR drop emitted for
            // the payload would read whichever value happened to land
            // there last (a `comptime_int` from the body's literal,
            // tripping `arcPtrChild`'s pointer assertion). Lowering
            // first lets `next_local` advance past every body binding,
            // so payload_local lands in a unique slot.
            var nil_instrs_result: []const Instruction = &.{};
            var nil_result: ?LocalId = null;
            var struct_instrs_result: []const Instruction = &.{};
            var struct_result: ?LocalId = null;

            for (group.clauses) |clause| {
                const param = clause.params[o_param_idx];
                const is_nil_clause = blk: {
                    if (param.pattern) |pat| {
                        if (pat.* == .literal and pat.literal == .nil) break :blk true;
                    }
                    break :blk param.type_id == types_mod.TypeStore.NIL;
                };

                const saved = self.current_instrs;
                self.current_instrs = .empty;
                if (!is_nil_clause) {
                    // The struct clause might destructure other params via
                    // tuple/struct/binary/map patterns. Only emit those
                    // bindings; the optional-param itself is handled by
                    // the ZIR redirect rather than an explicit binding.
                    try self.emitTupleBindings(&clause);
                    try self.emitStructBindings(&clause);
                    try self.emitBinaryBindings(&clause);
                    try self.emitMapBindings(&clause);
                }
                const body_result = try self.lowerBlock(clause.body);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                if (is_nil_clause) {
                    nil_instrs_result = body_instrs;
                    nil_result = body_result;
                } else {
                    struct_instrs_result = body_instrs;
                    struct_result = body_result;
                }
            }

            const payload_local = self.next_local;
            self.next_local += 1;
            if (optional_struct_name) |sname| {
                try self.known_local_types.put(payload_local, .{ .struct_ref = sname });
            }

            try self.current_instrs.append(self.allocator, .{
                .optional_dispatch = .{
                    .scrutinee_param = o_param_idx,
                    .payload_local = payload_local,
                    .nil_instrs = nil_instrs_result,
                    .nil_result = nil_result,
                    .struct_instrs = struct_instrs_result,
                    .struct_result = struct_result,
                },
            });
        } else {
            uses_decision_tree = true;
            // General multi-clause dispatch via decision tree
            // Build PatternMatrix from clause params
            var pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (group.clauses, 0..) |clause, clause_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                for (clause.params) |param| {
                    try pats.append(self.allocator, param.pattern);
                }
                try pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(clause_idx),
                    .guard = clause.refinement,
                });
            }

            // Set up scrutinee_map: param indices as scrutinee IDs
            var scrutinee_ids: std.ArrayList(u32) = .empty;
            for (0..group.arity) |i| {
                try scrutinee_ids.append(self.allocator, @intCast(i));
            }

            var next_scrutinee_id: u32 = group.arity;
            const decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = group.arity,
                },
                try scrutinee_ids.toOwnedSlice(self.allocator),
                &next_scrutinee_id,
            );

            // Set up scrutinee_map: map scrutinee IDs to param_get locals
            var scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer scrutinee_map.deinit();
            for (0..group.arity) |i| {
                const param_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = param_local, .index = @intCast(i) },
                });
                // Track known types for Phase 3
                const param_type = typeIdToZigTypeWithStore(first_clause.params[i].type_id, self.type_store);
                if (param_type != .any) {
                    try self.known_local_types.put(param_local, param_type);
                }
                // Track HIR type so `emitLocalGet` can decide whether a
                // pattern-binding `.local_get` from this param requires a
                // follow-up `.retain`.
                try self.local_hir_types.put(param_local, first_clause.params[i].type_id);
                try self.param_backed_locals.put(param_local, {});
                try scrutinee_map.put(@intCast(i), param_local);
            }

            try self.lowerDecisionTreeForDispatch(decision, group.clauses, &scrutinee_map);
        }

        var entry_instrs: []const Instruction = try self.current_instrs.toOwnedSlice(self.allocator);

        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const mangled_raw_name = try mangleSymbolForZig(self.allocator, raw_name);
        const local_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled_raw_name, group.arity });
        const name_str = if (self.current_struct_prefix) |prefix|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, local_name })
        else
            local_name;

        const return_type = typeIdToZigTypeWithStore(first_clause.return_type, self.type_store);

        // Register union dispatch info for call-site wrapping
        if (union_param_idx) |u_idx| {
            for (params.items) |p| {
                if (p.type_expr == .struct_ref) {
                    var variants = std.StringHashMap(void).init(self.allocator);
                    for (group.clauses) |clause| {
                        const clause_type = typeIdToZigTypeWithStore(clause.params[u_idx].type_id, self.type_store);
                        if (clause_type == .struct_ref) {
                            try variants.put(clause_type.struct_ref, {});
                        }
                    }
                    try self.union_dispatch_map.put(name_str, .{
                        .param_idx = u_idx,
                        .union_type_name = p.type_expr.struct_ref,
                        .variants = variants,
                    });
                    break;
                }
            }
        }

        // Rewrite tail-recursive self-calls into `tail_call` IR. The
        // ZIR backend's tail_call lowering picks musttail (TCO-safe
        // signatures) vs loopification (byref) — see `rewriteTailCalls`
        // doc for the dispatch rationale.
        entry_instrs = try self.rewriteTailCalls(entry_instrs, name_str, func_id, params.items, return_type);

        const has_tail_call = containsTailCall(entry_instrs);
        const tco_safe = isTcoEligible(params.items, return_type);
        const loopify = has_tail_call and !tco_safe;

        const entry_block = Block{
            .label = 0,
            .instructions = entry_instrs,
        };

        const final_params = try params.toOwnedSlice(self.allocator);

        // Collect default parameter values for call-site inlining
        var defaults_list: std.ArrayList(DefaultValue) = .empty;
        if (group.clauses.len == 1) {
            const clause = &group.clauses[0];
            var di: usize = clause.params.len;
            while (di > 0) {
                di -= 1;
                if (clause.params[di].default) |default_expr| {
                    const dv: DefaultValue = switch (default_expr.kind) {
                        .int_lit => |v| .{ .int = v },
                        .float_lit => |v| .{ .float = v },
                        .string_lit => |v| .{ .string = self.interner.get(v) },
                        .bool_lit => |v| .{ .bool_val = v },
                        .nil_lit => .nil,
                        else => break, // Non-constant default, can't inline
                    };
                    try defaults_list.insert(self.allocator, 0, dv); // prepend to maintain order
                } else break;
            }
        }

        const param_conventions = try self.computeParamConventions(final_params);
        const local_ownership = try self.computeLocalOwnership(self.next_local);
        const result_convention = self.computeResultConvention(first_clause.return_type);
        try self.functions.append(self.allocator, .{
            .id = func_id,
            .name = name_str,
            .struct_name = self.current_struct_prefix,
            .local_name = local_name,
            .scope_id = group.scope_id,
            .arity = group.arity,
            .params = final_params,
            .return_type = return_type,
            .return_type_id = first_clause.return_type,
            .body = try self.allocSlice(Block, &.{entry_block}),
            .is_closure = group.captures.len > 0,
            .captures = try captures.toOwnedSlice(self.allocator),
            .local_count = self.next_local,
            .defaults = try defaults_list.toOwnedSlice(self.allocator),
            .loopify = loopify,
            .param_conventions = param_conventions,
            .local_ownership = local_ownership,
            .result_convention = result_convention,
        });

        // Generate a `__try` variant whenever the catch-basin pipeline asked
        // for one (i.e. the original function name is in `try_variant_names`).
        //
        // For multi-clause functions we go through the decision-tree dispatch
        // path. Single-clause functions are regularly emitted without
        // dispatch — but if the single clause has a non-trivial pattern
        // (literal, struct, tuple, refinement, etc.) the call can still fail
        // to match, and `~>` callers need a `__try` variant to detect that.
        // We synthesise one here using the same decision-tree machinery used
        // for multi-clause functions.
        const single_clause_has_dispatch = blk: {
            if (group.clauses.len != 1) break :blk false;
            const c = group.clauses[0];
            if (c.refinement != null) break :blk true;
            for (c.params) |p| {
                if (p.pattern) |pat| {
                    if (!isTotalMatchPattern(pat)) break :blk true;
                }
            }
            break :blk false;
        };
        const want_try_variant =
            self.try_variant_names.contains(name_str) and
            ((uses_decision_tree and group.clauses.len > 1) or single_clause_has_dispatch);
        if (want_try_variant) {
            // Use a high ID offset for __try variants to avoid colliding with
            // normal function group IDs (which come from HIR and are sequential).
            const try_func_id = self.next_try_id;
            self.next_try_id += 1;
            self.next_local = 0;
            self.current_instrs = .empty;
            self.known_local_types.clearRetainingCapacity();
            self.local_hir_types.clearRetainingCapacity();
            self.param_backed_locals.clearRetainingCapacity();
            self.term_tuple_locals.clearRetainingCapacity();

            // Reserve binding locals (same as normal function)
            self.next_local = computeMaxBindingLocalForClauses(group.clauses);

            // Re-build the decision tree with try_mode enabled
            self.try_mode = true;
            self.current_try_arity = group.arity;
            defer self.try_mode = false;

            var try_pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (group.clauses, 0..) |clause, clause_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                for (clause.params) |param| {
                    try pats.append(self.allocator, param.pattern);
                }
                try try_pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(clause_idx),
                    .guard = clause.refinement,
                });
            }

            var try_scrutinee_ids: std.ArrayList(u32) = .empty;
            for (0..group.arity) |i| {
                try try_scrutinee_ids.append(self.allocator, @intCast(i));
            }

            var try_next_scrutinee_id: u32 = group.arity;
            const try_decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try try_pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = group.arity,
                },
                try try_scrutinee_ids.toOwnedSlice(self.allocator),
                &try_next_scrutinee_id,
            );

            var try_scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer try_scrutinee_map.deinit();
            for (0..group.arity) |i| {
                const param_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = param_local, .index = @intCast(i) },
                });
                const param_type = typeIdToZigTypeWithStore(first_clause.params[i].type_id, self.type_store);
                if (param_type != .any) {
                    try self.known_local_types.put(param_local, param_type);
                }
                // Track HIR type for ARC-managed pattern-binding decisions.
                try self.local_hir_types.put(param_local, first_clause.params[i].type_id);
                try self.param_backed_locals.put(param_local, {});
                try try_scrutinee_map.put(@intCast(i), param_local);
            }

            try self.lowerDecisionTreeForDispatch(try_decision, group.clauses, &try_scrutinee_map);

            const try_entry_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            const try_entry_block = Block{
                .label = 0,
                .instructions = try_entry_instrs,
            };

            // Re-build captures for the __try variant
            var try_captures: std.ArrayList(Capture) = .empty;
            for (group.captures, 0..) |capture, idx| {
                const cap_name = try std.fmt.allocPrint(self.allocator, "__cap_{d}", .{idx});
                try try_captures.append(self.allocator, .{
                    .name = cap_name,
                    .type_expr = typeIdToZigTypeWithStore(capture.type_id, self.type_store),
                    .ownership = capture.ownership,
                });
            }

            // __try variant has the same params as the original (no handler param)
            var try_params: std.ArrayList(Param) = .empty;
            for (final_params) |p| try try_params.append(self.allocator, p);

            const try_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{name_str});
            const try_local_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{local_name});
            const try_final_params = try try_params.toOwnedSlice(self.allocator);
            const try_param_conventions = try self.computeParamConventions(try_final_params);
            const try_local_ownership = try self.computeLocalOwnership(self.next_local);
            const try_result_convention = self.computeResultConvention(first_clause.return_type);
            try self.functions.append(self.allocator, .{
                .id = try_func_id,
                .name = try_name,
                .struct_name = self.current_struct_prefix,
                .local_name = try_local_name,
                .scope_id = group.scope_id,
                .arity = group.arity,
                .params = try_final_params,
                .return_type = return_type,
                .body = try self.allocSlice(Block, &.{try_entry_block}),
                .is_closure = group.captures.len > 0,
                .captures = try try_captures.toOwnedSlice(self.allocator),
                .local_count = self.next_local,
                .param_conventions = try_param_conventions,
                .local_ownership = try_local_ownership,
                .result_convention = try_result_convention,
            });
        }
    }

    /// Whether a given Zig type is safe to pass through an LLVM
    /// `musttail` call site without breaking the no-caller-frame-
    /// references invariant. Only types that fastcc passes/returns
    /// purely in registers qualify. Anything that the Zig backend
    /// classifies as `byref` (the `isByRef` predicate at
    /// `codegen/llvm/FuncGen.zig:7223`) — every non-zero struct,
    /// tuple, slice, list, map, optional-of-byref, tagged union, or
    /// `runtime.Term` — would force the caller to allocate on its own
    /// frame and pass a pointer; LLVM then rejects `musttail` because
    /// the callee retains a pointer into the caller's frame past the
    /// jump. The conservative approach: emit `tail_call` only when
    /// every parameter and the return type are scalar-by-value.
    fn isTcoSafeType(t: ZigType) bool {
        return switch (t) {
            .void,
            .bool_type,
            .nil,
            .i8,
            .i16,
            .i32,
            .i64,
            .i128,
            .u8,
            .u16,
            .u32,
            .u64,
            .u128,
            .f16,
            .f32,
            .f64,
            .f80,
            .f128,
            .usize,
            .isize,
            .atom,
            .never,
            .ptr,
            // `?*const MArrayOf(T)` is a single pointer-size optional —
            // Zig passes it in registers like any other `?*T`, so it
            // satisfies the by-value requirement for `musttail`.
            .marray_i64,
            .marray_f64,
            => true,
            // Anything routed through Zig's by-ref ABI is unsafe for
            // `musttail`. Strings (slices), structs, tuples, lists,
            // maps, tagged unions, optionals, term, function values,
            // and `any` all fall here.
            .string,
            .struct_ref,
            .tuple,
            .list,
            .map,
            .function,
            .tagged_union,
            .optional,
            .term,
            .any,
            => false,
        };
    }

    fn isTcoEligible(params: []const Param, return_type: ZigType) bool {
        if (!isTcoSafeType(return_type)) return false;
        for (params) |p| {
            if (!isTcoSafeType(p.type_expr)) return false;
        }
        return true;
    }

    /// Rewrite tail-recursive calls in a function's instruction list.
    /// Scans for patterns where the last operation before a return/break is a
    /// recursive call to the same function, and replaces them with tail_call.
    ///
    /// Bails out without rewriting whenever any parameter or the
    /// return type is by-ref (struct, slice, list, map, …). Marking
    /// such a call as LLVM `musttail` is unsupportable on AArch64
    /// fastcc — the caller-frame allocas backing those args would
    /// have to survive the tail jump and LLVM rejects the IR with
    /// `failed to perform tail call elimination on a call site
    /// marked musttail`. Falling back to ordinary `call_named + ret`
    /// here is correctness-preserving (the recursion just builds a
    /// real frame). Restoring TCO for byref-shaped state is a
    /// separate, larger ABI design effort.
    /// Walk `instrs` (and any nested bodies the IR carries — switch
    /// cases, optional-dispatch branches) and report whether a
    /// `tail_call` instruction reaches the surface anywhere. Used to
    /// decide if a function's signature needs the loopification
    /// lowering path: `loopify = !isTcoEligible AND containsTailCall`.
    fn containsTailCall(instrs: []const Instruction) bool {
        for (instrs) |instr| {
            switch (instr) {
                .tail_call => return true,
                .switch_return => |sr| {
                    for (sr.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                    if (containsTailCall(sr.default_instrs)) return true;
                },
                .union_switch_return => |usr| {
                    for (usr.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                },
                .union_switch => |us| {
                    for (us.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                },
                .optional_dispatch => |od| {
                    if (containsTailCall(od.nil_instrs)) return true;
                    if (containsTailCall(od.struct_instrs)) return true;
                },
                .switch_literal => |sl| {
                    for (sl.cases) |c| if (containsTailCall(c.body_instrs)) return true;
                    if (containsTailCall(sl.default_instrs)) return true;
                },
                .case_block => |cb| {
                    if (containsTailCall(cb.pre_instrs)) return true;
                    for (cb.arms) |arm| {
                        if (containsTailCall(arm.cond_instrs)) return true;
                        if (containsTailCall(arm.body_instrs)) return true;
                    }
                    if (containsTailCall(cb.default_instrs)) return true;
                },
                .guard_block => |gb| {
                    if (containsTailCall(gb.body)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    /// Phase E.6: classify a trailing instruction sitting between a
    /// recursive `call_named` and its `ret` as "tail-mappable" — i.e.,
    /// an instruction the tail-call rewriter can reorder around the
    /// rewrite without changing semantics.
    ///
    /// The set of tail-mappable instructions covers the no-op /
    /// refcount-only opcodes that ARC infrastructure may emit between
    /// the call and the return:
    ///   * `.release` — post-call ARC release for a shared arg local,
    ///     or a forward-dataflow scope-exit drop synthesized by
    ///     ownership analysis.
    ///   * `.retain` — refcount bump that pairs with a downstream
    ///     release; semantically a no-op when paired but must be
    ///     preserved for accounting.
    ///   * `.borrow_value` — Phase C alias instruction; lowers to a
    ///     plain assignment with no runtime effect.
    ///   * `.copy_value` — Phase C copy instruction; lowers to
    ///     assignment + retain.
    ///   * `.move_value` — ownership transfer; lowers to assignment.
    ///
    /// Any other instruction between `call_named` and `ret` blocks
    /// the rewrite — the verifier's V6 invariant rejects such IR
    /// because the runtime stack would grow unboundedly on deep
    /// recursion.
    fn isTailMappableTrailingInstr(instr: Instruction) bool {
        return switch (instr) {
            .release, .retain, .borrow_value, .copy_value, .move_value => true,
            else => false,
        };
    }

    /// Phase E.6: a trailing instruction sitting between the recursive
    /// `call_named` and its `ret` is dropped on rewrite iff it is a
    /// `.release` whose target is one of the call's argument locals.
    /// Once the call becomes a `tail_call`, the callee inherits
    /// ownership of every arg through the tail jump — there is no
    /// "after the call" for that release to fire in (control transfers
    /// out of the function), and the next iteration's matching
    /// parameter already accounts for the refcount unit. Eliminating
    /// the per-arg releases is therefore the correct ownership-
    /// transfer accounting.
    ///
    /// Every other tail-mappable instruction (non-arg releases, retains,
    /// borrow_value, copy_value, move_value) is preserved before the
    /// new `tail_call` so it observes pre-tail refcounts and fires
    /// before control leaves the function.
    fn isTailReleaseOfArg(instr: Instruction, args: []const LocalId) bool {
        switch (instr) {
            .release => |r| {
                for (args) |arg_local| {
                    if (arg_local == r.value) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Phase E.8 orphan-share fix: when the tail-call rewriter drops a
    /// trailing `.release{value=X}` of a call-arg slot, it must also
    /// drop the matching `.share_value{dest=X, source=Y}` earlier in
    /// the body and substitute the call's arg `X` with `Y`. Otherwise
    /// the share_value's retain becomes orphaned (no matching release
    /// after the rewrite, since the callee inherits ownership through
    /// the tail jump) and accumulates +1 refcount per iteration —
    /// exactly the leak signature observed in Phase F retry-3.
    ///
    /// Builds the drop-set + substitution table by scanning the
    /// trailing instructions for arg-cleanup releases. Returns:
    ///   * `dropped_share_dests` — LocalIds of `.share_value`
    ///     instructions to elide from the prelude (caller-allocated
    ///     hash set populated here; caller frees).
    ///   * `arg_substitutions` — for each call arg, the source local
    ///     to substitute (caller-allocated hash map populated here).
    ///
    /// Lookup of the matching share_value walks the prelude (the
    /// instructions BEFORE the call slot) and finds the most recent
    /// `.share_value{dest=X, source=Y}`. If no match is found, only
    /// the release is dropped (existing E.6 behaviour); the call's
    /// arg stays as-is.
    fn collectOrphanShareRewrites(
        prelude: []const Instruction,
        trailing: []const Instruction,
        call_args: []const LocalId,
        dropped_share_dests: *std.AutoHashMap(LocalId, void),
        arg_substitutions: *std.AutoHashMap(LocalId, LocalId),
    ) !void {
        for (trailing) |trailing_instr| {
            const released_local = switch (trailing_instr) {
                .release => |r| r.value,
                else => continue,
            };
            // Only match arg-cleanup releases — those whose target
            // is one of the call's argument locals.
            var is_arg_release = false;
            for (call_args) |arg_local| {
                if (arg_local == released_local) {
                    is_arg_release = true;
                    break;
                }
            }
            if (!is_arg_release) continue;

            // Walk the prelude backward to find the most recent
            // `.share_value{dest=released_local, source=Y}`. The
            // backward scan matches the one share-per-arg produced
            // by `lowerExpr`'s arg-shape lowering; multiple shares
            // for the same dest cannot occur at the IR-builder
            // level (each share allocates a fresh `next_local`).
            var idx: usize = prelude.len;
            while (idx > 0) {
                idx -= 1;
                switch (prelude[idx]) {
                    .share_value => |sv| {
                        if (sv.dest == released_local) {
                            try dropped_share_dests.put(sv.dest, {});
                            try arg_substitutions.put(sv.dest, sv.source);
                            break;
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Phase E.8: apply the substitution table to the call's arg
    /// list, producing a fresh slice when any arg changes. When no
    /// substitutions apply, returns the original slice (no copy).
    fn applyArgSubstitutions(
        allocator: std.mem.Allocator,
        args: []const LocalId,
        arg_substitutions: *const std.AutoHashMap(LocalId, LocalId),
    ) ![]const LocalId {
        if (arg_substitutions.count() == 0) return args;
        var any_change = false;
        for (args) |arg_local| {
            if (arg_substitutions.contains(arg_local)) {
                any_change = true;
                break;
            }
        }
        if (!any_change) return args;
        const new_args = try allocator.alloc(LocalId, args.len);
        for (args, 0..) |arg_local, i| {
            new_args[i] = arg_substitutions.get(arg_local) orelse arg_local;
        }
        return new_args;
    }

    fn rewriteTailCalls(
        self: *IrBuilder,
        instrs: []const Instruction,
        func_name: []const u8,
        enclosing_function_id: FunctionId,
        params: []const Param,
        return_type: ZigType,
    ) ![]const Instruction {
        // Self-tail-calls are always rewritten to `tail_call` IR. The
        // ZIR backend chooses between two strategies at lowering time:
        //
        //   * `isTcoEligible(params, return_type)` true → emit
        //     `musttail call + ret`, the existing fast path. LLVM
        //     reuses the current frame.
        //   * `isTcoEligible` false → emit a loopification body —
        //     stack-slot stores plus `repeat` to the function-level
        //     `loop` block — so by-ref state recurses without growing
        //     the stack and without triggering LLVM's `musttail`
        //     legality check (which rejects byref signatures on
        //     fastcc-bound argument shapes).
        //
        // Earlier passes used to bail out here for byref signatures;
        // that left the recursion as a regular `call_named + ret`,
        // which compiled cleanly but blew the stack at scale. The
        // ZIR-level loopification dispatch makes the byref case work
        // correctly, so the IR rewrite always runs.
        _ = params;
        _ = return_type;

        var result: std.ArrayList(Instruction) = .empty;
        for (instrs) |instr| {
            switch (instr) {
                .switch_return => |sr| {
                    // Rewrite tail calls inside switch_return cases
                    var new_cases: std.ArrayList(ReturnCase) = .empty;
                    for (sr.cases) |case| {
                        const new_body = try self.rewriteTailCallsInBody(case.body_instrs, case.return_value, func_name, enclosing_function_id);
                        if (new_body.rewritten) {
                            try new_cases.append(self.allocator, .{
                                .value = case.value,
                                .body_instrs = new_body.instrs,
                                .return_value = null, // tail_call handles the return
                            });
                        } else {
                            try new_cases.append(self.allocator, case);
                        }
                    }
                    // Also check default arm
                    const new_default = try self.rewriteTailCallsInBody(sr.default_instrs, sr.default_result, func_name, enclosing_function_id);
                    try result.append(self.allocator, .{
                        .switch_return = .{
                            .scrutinee_param = sr.scrutinee_param,
                            .cases = try new_cases.toOwnedSlice(self.allocator),
                            .default_instrs = if (new_default.rewritten) new_default.instrs else sr.default_instrs,
                            .default_result = if (new_default.rewritten) null else sr.default_result,
                        },
                    });
                },
                .ret => |r| {
                    // Walk backward in `result` past any tail-mappable
                    // trailing instructions (releases, retains, and the
                    // Phase C alias/copy/move opcodes) to find the
                    // matching `call_named`. Several distinct sources
                    // can interleave instructions between the recursive
                    // call and the `ret`:
                    //
                    //   * Phase 6.2b's IR drop-insertion pass appends
                    //     `.release` instructions before terminator
                    //     returns for owned-at-ret locals.
                    //   * The share_value call-arg lowering emits per-
                    //     call cleanup `.release` IR immediately after
                    //     the call (every entry in
                    //     `shared_release_locals` becomes a post-call
                    //     release on the per-call shared dest local).
                    //   * Phase C's `arc_ownership` pass may rewrite
                    //     trailing `local_get` reads into
                    //     `.borrow_value` or `.copy_value`.
                    //   * Move/retain instructions can also surface
                    //     between the call and the ret as forward-
                    //     dataflow ownership normalisation evolves.
                    //
                    // When any of these fire on a tail-position
                    // recursive call, the naive "is the immediately-
                    // preceding instruction a call_named?" check
                    // fails. Walking past every tail-mappable trailing
                    // instruction restores the rewrite for the k-
                    // nucleotide hot loop and any other ARC-arg tail-
                    // recursive function. The verifier's V6 invariant
                    // (in `arc_verifier.zig`) catches the converse: any
                    // non-tail-mappable instruction sitting between a
                    // self-recursive call and its `ret` is rejected at
                    // compile time so deep recursion never silently
                    // blows the stack.
                    if (result.items.len > 0 and r.value != null) {
                        var probe: usize = result.items.len;
                        while (probe > 0 and isTailMappableTrailingInstr(result.items[probe - 1])) : (probe -= 1) {}
                        if (probe > 0 and result.items[probe - 1] == .call_named) {
                            const cn = result.items[probe - 1].call_named;
                            if (std.mem.eql(u8, cn.name, func_name) and r.value.? == cn.dest) {
                                // Phase E.8 orphan-share fix: scan
                                // the trailing arg-cleanup releases
                                // and find their matching prelude
                                // `.share_value` instructions. We
                                // will drop both the trailing
                                // release AND the matching
                                // `.share_value` from the prelude,
                                // then substitute the call's arg with
                                // the share's source. Without this,
                                // the share_value's retain would
                                // accumulate +1 refcount per
                                // iteration (Phase F retry-3 leak).
                                var dropped_share_dests = std.AutoHashMap(LocalId, void).init(self.allocator);
                                defer dropped_share_dests.deinit();
                                var arg_substitutions = std.AutoHashMap(LocalId, LocalId).init(self.allocator);
                                defer arg_substitutions.deinit();
                                try collectOrphanShareRewrites(
                                    result.items[0 .. probe - 1],
                                    result.items[probe..],
                                    cn.args,
                                    &dropped_share_dests,
                                    &arg_substitutions,
                                );

                                // For each trailing tail-mappable
                                // instruction, decide:
                                //   * `.release{value=arg}` — drop on
                                //     rewrite (callee inherits
                                //     ownership through tail jump).
                                //   * everything else — preserve before
                                //     the new `tail_call` so the
                                //     refcount op observes pre-tail
                                //     state and fires before control
                                //     leaves the function.
                                var preserved: std.ArrayList(Instruction) = .empty;
                                defer preserved.deinit(self.allocator);
                                for (result.items[probe..]) |trailing| {
                                    std.debug.assert(isTailMappableTrailingInstr(trailing));
                                    if (isTailReleaseOfArg(trailing, cn.args)) continue;
                                    try preserved.append(self.allocator, trailing);
                                }

                                // Build the new prelude in a fresh
                                // ArrayList, eliding any `.share_value`
                                // whose dest is in the drop set. We
                                // can't mutate `result.items[0..probe-1]`
                                // in place because shrinking it would
                                // require a memmove; collecting into
                                // a temp slice keeps the code clear.
                                var rebuilt_prelude: std.ArrayList(Instruction) = .empty;
                                defer rebuilt_prelude.deinit(self.allocator);
                                for (result.items[0 .. probe - 1]) |prelude_instr| {
                                    switch (prelude_instr) {
                                        .share_value => |sv| {
                                            if (dropped_share_dests.contains(sv.dest)) continue;
                                        },
                                        else => {},
                                    }
                                    try rebuilt_prelude.append(self.allocator, prelude_instr);
                                }

                                // Truncate result and re-emit the
                                // rebuilt prelude, preserved
                                // trailing instructions, and the new
                                // `tail_call` (with substituted args).
                                // The original `ret` is dropped — the
                                // tail_call is itself the terminator.
                                const substituted_args = try applyArgSubstitutions(self.allocator, cn.args, &arg_substitutions);
                                result.clearRetainingCapacity();
                                for (rebuilt_prelude.items) |kept| {
                                    try result.append(self.allocator, kept);
                                }
                                for (preserved.items) |kept| {
                                    try result.append(self.allocator, kept);
                                }
                                try result.append(self.allocator, .{ .tail_call = .{
                                    .name = cn.name,
                                    .args = substituted_args,
                                } });
                                continue; // skip the ret
                            }
                        }

                        // Phase E.7: structural tail-call through `if_expr`
                        // / `switch_literal` arms.
                        //
                        // Zap's `if-else` surface lowers to `switch_literal`
                        // (literal arms on a Bool scrutinee) or `if_expr`,
                        // and the value flowing out of the construct (the
                        // arms' merged result) is what feeds the function's
                        // `ret`. When each arm's last instruction is a
                        // self-recursive `call_named` whose `dest` is the
                        // arm's `result`, the recursion is genuinely in
                        // tail position — every CFG path from the construct
                        // to the function exit is `arm body -> recursive
                        // call -> arm result -> if/switch dest -> ret`. The
                        // top-level rewriter above only handles the case
                        // where the `call_named + ret` pair is already
                        // adjacent in the same stream; the structural case
                        // requires recursing INTO each arm and rewriting
                        // its tail position.
                        //
                        // Match the construct walking past trailing tail-
                        // mappable instructions exactly like the linear
                        // case. When the construct's `dest` matches the
                        // outer `ret`'s value, rewrite each arm via the
                        // existing `rewriteTailCallsInBody` helper. Arms
                        // whose body does NOT end in a self-recursive call
                        // (e.g., a base case returning a constant) are left
                        // alone — `rewriteTailCallsInBody` returns `null`
                        // for the rewritten flag and the original arm is
                        // preserved verbatim. This is correct: only the
                        // recursive arm needs the tail-call rewrite; the
                        // base case completes its arm body, joins at the
                        // construct's `dest`, and flows into the outer
                        // `ret` normally. The outer `ret` itself stays in
                        // place — it remains the terminator for non-
                        // rewritten arms; for rewritten arms the `tail_call`
                        // inside the arm jumps out of the function before
                        // control would have rejoined the merge.
                        // Only fire the structural rewrite when the
                        // branch is IMMEDIATELY followed by the outer
                        // `ret` (no intervening tail-mappable
                        // instructions). Tail-mappable instructions in
                        // the gap would be ARC bookkeeping on the
                        // merge value (e.g., a post-merge retain
                        // before ret); after the rewrite no merge
                        // value exists, so those instructions would
                        // have nothing to operate on. Keeping the
                        // gate strict avoids that ambiguity. The k-
                        // nucleotide hot loop falls in this strict
                        // window.
                        if (probe == result.items.len and probe > 0) {
                            const branch_instr = result.items[probe - 1];
                            const rewritten_branch = try self.tryRewriteTailThroughBranch(branch_instr, r.value.?, func_name, enclosing_function_id);
                            if (rewritten_branch) |new_branch| {
                                // The rewritten branch subsumes the
                                // outer `ret`: every arm now terminates
                                // itself (either via `tail_call` or via
                                // the `ret arm_result` pushed by
                                // `tryRewriteTailThroughBranch`). Drop
                                // the outer `ret` — control never
                                // reaches a merge. The shape mirrors
                                // `switch_return`'s self-terminating
                                // arms, which the ZIR backend already
                                // handles correctly under both musttail
                                // and loopify lowering.
                                result.items.len = probe - 1;
                                try result.append(self.allocator, new_branch);
                                continue;
                            }
                        }
                    }
                    try result.append(self.allocator, instr);
                },
                else => try result.append(self.allocator, instr),
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }

    const TailCallRewrite = struct {
        instrs: []const Instruction,
        rewritten: bool,
    };

    fn rewriteTailCallsInBody(
        self: *IrBuilder,
        body: []const Instruction,
        return_value: ?LocalId,
        func_name: []const u8,
        enclosing_function_id: FunctionId,
    ) !TailCallRewrite {
        if (body.len == 0 or return_value == null) return .{ .instrs = body, .rewritten = false };

        // Walk backward past trailing tail-mappable instructions
        // (releases, retains, and the Phase C alias/copy/move opcodes)
        // to find the call. Mirrors the behaviour in
        // `rewriteTailCalls`: ARC infrastructure (share_value cleanup
        // releases, drop insertion, and the Phase C ownership
        // normalisation) interleaves no-op / refcount-only
        // instructions between the recursive call and the implicit
        // return; without walking past them the naive "is the last
        // instruction a call?" check fails. See `rewriteTailCalls` for
        // the full reasoning, including why per-arg releases must be
        // dropped on rewrite (the callee inherits ownership through
        // the tail jump) and how every other tail-mappable trailing
        // instruction is preserved before the new `tail_call`.
        var call_index: usize = body.len;
        while (call_index > 0 and isTailMappableTrailingInstr(body[call_index - 1])) : (call_index -= 1) {}
        if (call_index == 0) return .{ .instrs = body, .rewritten = false };
        const call_instr = body[call_index - 1];

        const trailing = body[call_index..];

        const TailCallShape = struct {
            args: []const LocalId,
            tail_name: []const u8,
            dest_matches: bool,
        };
        const shape: ?TailCallShape = blk: {
            switch (call_instr) {
                .call_direct => |cd| break :blk .{
                    .args = cd.args,
                    .tail_name = func_name,
                    // A `call_direct` only counts as a tail-recursive
                    // self-call when its `function` field references the
                    // enclosing function. Without this guard, a sibling-
                    // function call (e.g., `add_ten(0)` in a `case` arm
                    // of `compute`) would be rewritten into
                    // `tail_call name=compute`, producing unbounded
                    // self-recursion at runtime. The dest-equality
                    // check alone is insufficient: every direct call
                    // whose result becomes the arm's value satisfies
                    // it, regardless of which function was actually
                    // invoked.
                    .dest_matches = cd.function == enclosing_function_id and cd.dest == return_value.?,
                },
                .call_named => |cn| break :blk .{
                    .args = cn.args,
                    .tail_name = cn.name,
                    .dest_matches = std.mem.eql(u8, cn.name, func_name) and cn.dest == return_value.?,
                },
                else => break :blk null,
            }
        };
        if (shape == null or !shape.?.dest_matches) {
            return .{ .instrs = body, .rewritten = false };
        }
        const sh = shape.?;

        // Phase E.8 orphan-share fix — see `rewriteTailCalls` for
        // full reasoning. Mirror the same scan-and-substitute logic
        // here so structural tail-calls through `if_expr` /
        // `switch_literal` arms also benefit from the leak fix.
        var dropped_share_dests = std.AutoHashMap(LocalId, void).init(self.allocator);
        defer dropped_share_dests.deinit();
        var arg_substitutions = std.AutoHashMap(LocalId, LocalId).init(self.allocator);
        defer arg_substitutions.deinit();
        try collectOrphanShareRewrites(
            body[0 .. call_index - 1],
            trailing,
            sh.args,
            &dropped_share_dests,
            &arg_substitutions,
        );

        var preserved: std.ArrayList(Instruction) = .empty;
        defer preserved.deinit(self.allocator);
        for (trailing) |trailing_instr| {
            std.debug.assert(isTailMappableTrailingInstr(trailing_instr));
            if (isTailReleaseOfArg(trailing_instr, sh.args)) continue;
            try preserved.append(self.allocator, trailing_instr);
        }

        var new_body: std.ArrayList(Instruction) = .empty;
        for (body[0 .. call_index - 1]) |bi| {
            switch (bi) {
                .share_value => |sv| {
                    if (dropped_share_dests.contains(sv.dest)) continue;
                },
                else => {},
            }
            try new_body.append(self.allocator, bi);
        }
        for (preserved.items) |kept| {
            try new_body.append(self.allocator, kept);
        }
        const substituted_args = try applyArgSubstitutions(self.allocator, sh.args, &arg_substitutions);
        try new_body.append(self.allocator, .{
            .tail_call = .{ .name = sh.tail_name, .args = substituted_args },
        });
        return .{ .instrs = try new_body.toOwnedSlice(self.allocator), .rewritten = true };
    }

    /// Phase E.7: rewrite an `if_expr` / `switch_literal` whose `dest`
    /// flows into a function-level tail-position `ret`, descending into
    /// each arm and rewriting per-arm `call_named + arm_result == call.dest`
    /// shapes into `tail_call`. Returns the rewritten branch instruction
    /// when at least one arm was rewritten, otherwise `null` (so the
    /// caller leaves the original branch in place).
    ///
    /// `dest_local` is the LocalId that the outer `ret` consumes; the
    /// rewrite is gated on the branch's `dest` matching it. A mismatch
    /// (the branch's value flows somewhere else before reaching `ret`)
    /// means the arms are NOT in tail position and the rewrite would
    /// be unsound.
    ///
    /// Branch lowering: a `switch_literal` / `if_expr` is a value-
    /// producing expression. The ZIR backend lowers it to nested
    /// `if_else_bodies` whose merge produces `dest`. Without further
    /// changes, a single arm being rewritten to `tail_call` would
    /// leave the OTHER arm producing a typed value into the merge —
    /// in loopify mode (the ARC-managed/byref shape) the merge would
    /// be Map vs void, which Sema rejects. To make the construct
    /// type-uniform we push the outer `ret` INTO each non-recursive
    /// arm: append `ret arm_result` to the arm body and clear the
    /// arm's `result` field. The arm becomes noreturn (matching
    /// `switch_return`'s shape). The outer `ret` is left in place by
    /// the caller — it becomes dead code that Zig's ZIR/Sema accept
    /// without complaint, and it remains the explicit terminator if
    /// any arm bodies happen not to be rewritten or pushed (e.g., an
    /// empty arm, which today is an unreachable IR shape).
    ///
    /// In musttail mode every rewritten arm ends in `tail_call` →
    /// `musttail call + ret` (noreturn at ZIR level). Pushed-ret arms
    /// also end in `ret` (noreturn). The merge is never reached.
    ///
    /// In loopify mode the rewritten arm ends in `tail_call` → stores
    /// + fall-through to the wrapping `loop`'s trailing `repeat`.
    /// Pushed-ret arms end in `ret` (noreturn → exits the function,
    /// bypassing the loop). Both shapes are valid block-body
    /// terminators inside `if_else_bodies` because Sema treats
    /// fall-through-and-repeat the same as any normal break_inline.
    fn tryRewriteTailThroughBranch(
        self: *IrBuilder,
        branch_instr: Instruction,
        dest_local: LocalId,
        func_name: []const u8,
        enclosing_function_id: FunctionId,
    ) !?Instruction {
        switch (branch_instr) {
            .if_expr => |ie| {
                if (ie.dest != dest_local) return null;
                const new_then = try self.rewriteTailCallsInBody(ie.then_instrs, ie.then_result, func_name, enclosing_function_id);
                const new_else = try self.rewriteTailCallsInBody(ie.else_instrs, ie.else_result, func_name, enclosing_function_id);
                if (!new_then.rewritten and !new_else.rewritten) return null;

                const final_then_instrs = if (new_then.rewritten)
                    new_then.instrs
                else
                    try self.appendRetToBody(ie.then_instrs, ie.then_result);
                const final_else_instrs = if (new_else.rewritten)
                    new_else.instrs
                else
                    try self.appendRetToBody(ie.else_instrs, ie.else_result);

                return Instruction{ .if_expr = .{
                    .dest = ie.dest,
                    .condition = ie.condition,
                    .then_instrs = final_then_instrs,
                    .then_result = null,
                    .else_instrs = final_else_instrs,
                    .else_result = null,
                } };
            },
            .switch_literal => |sl| {
                if (sl.dest != dest_local) return null;
                var any_rewritten = false;
                // First pass: discover whether any arm gets rewritten.
                // The pushed-ret transformation is gated on this
                // (arms only need to push the outer ret if at least
                // one sibling arm is taking the tail-call path).
                var rewrite_results: std.ArrayList(TailCallRewrite) = .empty;
                defer rewrite_results.deinit(self.allocator);
                for (sl.cases) |case| {
                    const r = try self.rewriteTailCallsInBody(case.body_instrs, case.result, func_name, enclosing_function_id);
                    if (r.rewritten) any_rewritten = true;
                    try rewrite_results.append(self.allocator, r);
                }
                const new_default = try self.rewriteTailCallsInBody(sl.default_instrs, sl.default_result, func_name, enclosing_function_id);
                if (new_default.rewritten) any_rewritten = true;
                if (!any_rewritten) return null;

                // Second pass: emit each arm in its final shape —
                // either the rewritten body (tail_call terminated) or
                // the original body with `ret arm_result` appended.
                var new_cases: std.ArrayList(LitCase) = .empty;
                for (sl.cases, 0..) |case, idx| {
                    const r = rewrite_results.items[idx];
                    const final_body = if (r.rewritten)
                        r.instrs
                    else
                        try self.appendRetToBody(case.body_instrs, case.result);
                    try new_cases.append(self.allocator, .{
                        .value = case.value,
                        .body_instrs = final_body,
                        .result = null,
                    });
                }
                const final_default = if (new_default.rewritten)
                    new_default.instrs
                else
                    try self.appendRetToBody(sl.default_instrs, sl.default_result);
                return Instruction{ .switch_literal = .{
                    .dest = sl.dest,
                    .scrutinee = sl.scrutinee,
                    .cases = try new_cases.toOwnedSlice(self.allocator),
                    .default_instrs = final_default,
                    .default_result = null,
                } };
            },
            else => return null,
        }
    }

    /// Phase E.7 helper: append a `ret arm_result` instruction to
    /// `body`, returning a freshly-allocated slice. Used by
    /// `tryRewriteTailThroughBranch` to push the outer `ret` into
    /// arms that did NOT get the tail-call rewrite, so every arm
    /// becomes noreturn and the if/switch construct type-merges
    /// uniformly under both musttail and loopify lowering.
    ///
    /// If `result` is `null`, the body is returned unchanged — the
    /// arm is already noreturn (e.g., it ends in `match_fail`) and
    /// adding a `ret` would emit an unreachable instruction after a
    /// noreturn terminator.
    fn appendRetToBody(
        self: *IrBuilder,
        body: []const Instruction,
        result: ?LocalId,
    ) ![]const Instruction {
        const ret_value = result orelse return body;
        // Detect bodies that already end in a noreturn terminator
        // (e.g., `match_fail`, `match_error_return`, `ret`, or a
        // tail_call). Such bodies should not have an extra `ret`
        // appended — the appended instruction would be unreachable.
        if (body.len > 0) {
            switch (body[body.len - 1]) {
                .ret, .match_fail, .match_error_return, .tail_call, .switch_return, .union_switch_return => return body,
                else => {},
            }
        }
        var new_body: std.ArrayList(Instruction) = .empty;
        for (body) |bi| try new_body.append(self.allocator, bi);
        try new_body.append(self.allocator, .{ .ret = .{ .value = ret_value } });
        return try new_body.toOwnedSlice(self.allocator);
    }

    /// Check if multi-clause function can emit switch_return for integer literals.
    /// Returns the param index to switch on if eligible.
    fn canSwitchDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup) ?u32 {
        if (group.clauses.len < 2) return null;

        var switch_param_idx: ?u32 = null;

        for (group.clauses, 0..) |clause, clause_idx| {
            const is_last = clause_idx == group.clauses.len - 1;

            if (is_last) {
                // Last clause must be wildcard/bind fallback (no literal pattern)
                for (clause.params) |param| {
                    if (param.pattern) |pat| {
                        if (pat.* == .literal) return null;
                    }
                }
                break;
            }

            // Non-last clauses must have literal pattern with no refinement
            if (clause.refinement != null) return null;

            // Find the literal param
            var found_literal_param: ?u32 = null;
            for (clause.params, 0..) |param, i| {
                if (param.pattern) |pat| {
                    if (pat.* == .literal) {
                        // Only integer literals can use switch
                        switch (pat.literal) {
                            .int => {},
                            else => return null,
                        }
                        found_literal_param = @intCast(i);
                    }
                }
            }

            if (found_literal_param == null) return null;

            if (switch_param_idx) |idx| {
                if (idx != found_literal_param.?) return null; // different param positions
            } else {
                // Check that the param type is a known integer type
                const param_type = typeIdToZigType(clause.params[found_literal_param.?].type_id);
                switch (param_type) {
                    .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => {},
                    else => return null,
                }
                switch_param_idx = found_literal_param;
            }
        }

        return switch_param_idx orelse {
            _ = self; // suppress unused
            return null;
        };
    }

    /// Check if all clauses have distinct named struct types for a given param position.
    /// Returns the synthesized union type name if eligible, null otherwise.
    /// Detect the multi-clause `f(nil) / f(t :: T)` shape where every
    /// clause for `param_idx` is either the `nil` literal pattern or a
    /// non-nil pattern (typed bind / struct match) over the same nominal
    /// struct. The unified parameter type is `?T` so the call site can
    /// pass either `nil` or a `T` value, and the dispatcher routes on
    /// is-null. Returns the single struct name on success — caller
    /// promotes the param's `ZigType` to `optional(struct_ref T)` and
    /// emits an `optional_dispatch` IR.
    ///
    /// Reasons to return null:
    ///  - fewer than two clauses
    ///  - no `TypeStore` (unit-test path with raw IR)
    ///  - any clause has a non-nil / non-struct type for this param
    ///  - more than one distinct struct type among the non-nil clauses
    ///  - all clauses are nil (degenerate) or all struct (no optional)
    fn canOptionalDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup, param_idx: u32) ?[]const u8 {
        if (group.clauses.len < 2) return null;
        const ts = self.type_store orelse return null;

        var struct_name: ?[]const u8 = null;
        var saw_nil = false;
        var saw_struct = false;

        for (group.clauses) |clause| {
            if (param_idx >= clause.params.len) return null;
            const param = clause.params[param_idx];
            const tid = param.type_id;

            // Match nil either by type or by literal pattern. Source
            // code like `pub fn count(nil)` parses with a `literal nil`
            // pattern and a still-unresolved param type_id; the
            // pattern is the authoritative signal.
            const is_nil_pattern = blk: {
                if (param.pattern) |pat| {
                    if (pat.* == .literal and pat.literal == .nil) break :blk true;
                }
                break :blk false;
            };

            if (is_nil_pattern or tid == types_mod.TypeStore.NIL) {
                saw_nil = true;
                continue;
            }

            if (tid >= ts.types.items.len) return null;
            const typ = ts.types.items[tid];
            switch (typ) {
                .struct_type => |st| {
                    const sname = self.interner.get(st.name);
                    if (struct_name) |existing| {
                        if (!std.mem.eql(u8, existing, sname)) return null;
                    } else {
                        struct_name = sname;
                    }
                    saw_struct = true;
                },
                else => return null,
            }
        }

        if (!saw_nil or !saw_struct) return null;
        return struct_name;
    }

    fn canUnionDispatch(self: *IrBuilder, group: *const hir_mod.FunctionGroup, param_idx: u32) !?[]const u8 {
        if (group.clauses.len < 2) return null;
        const ts = self.type_store orelse return null;

        var type_names: std.ArrayList([]const u8) = .empty;

        for (group.clauses) |clause| {
            if (param_idx >= clause.params.len) return null;
            const param = clause.params[param_idx];

            // Check if this param has a struct_match pattern (struct pattern)
            if (param.pattern) |pat| {
                if (pat.* == .struct_match) {
                    const type_name = self.interner.get(pat.struct_match.type_name);
                    // Verify it's a known struct type
                    var found = false;
                    for (type_names.items) |existing| {
                        if (std.mem.eql(u8, existing, type_name)) return null; // duplicate type
                    }
                    // Check via type_id that it's really a struct
                    if (param.type_id < ts.types.items.len) {
                        const typ = ts.types.items[param.type_id];
                        if (typ == .struct_type) {
                            found = true;
                        }
                    }
                    if (!found) return null;
                    try type_names.append(self.allocator, type_name);
                    continue;
                }
            }

            // Also check via type_id if the param resolves to a struct type
            if (param.type_id < ts.types.items.len) {
                const typ = ts.types.items[param.type_id];
                if (typ == .struct_type) {
                    const type_name = ts.interner.get(typ.struct_type.name);
                    for (type_names.items) |existing| {
                        if (std.mem.eql(u8, existing, type_name)) return null; // duplicate
                    }
                    try type_names.append(self.allocator, type_name);
                    continue;
                }
            }

            // Not a struct type — can't do union dispatch
            return null;
        }

        if (type_names.items.len < 2) return null;

        // Build the union name from the function group name
        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const func_name = if (self.current_struct_prefix) |prefix|
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ prefix, raw_name })
        else
            raw_name;
        const union_name = try std.fmt.allocPrint(self.allocator, "{s}_Union", .{func_name});

        // Synthesize the union type definition
        var variants: std.ArrayList(UnionVariant) = .empty;
        for (type_names.items) |tn| {
            try variants.append(self.allocator, .{
                .name = tn,
                .type_name = tn,
            });
        }

        try self.synthesized_type_defs.append(self.allocator, .{
            .name = union_name,
            .kind = .{ .union_def = .{
                .variants = try variants.toOwnedSlice(self.allocator),
            } },
        });

        return union_name;
    }

    /// Emit binary extraction instructions to populate binary binding locals.
    fn emitBinaryBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        // Find params that have binary patterns
        for (clause.params, 0..) |param, param_idx_usize| {
            const param_idx: u32 = @intCast(param_idx_usize);
            const pat = param.pattern orelse continue;
            if (pat.* != .binary_match) continue;

            // Get param local
            const data_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = data_local, .index = param_idx },
            });

            // Calculate min byte size and emit length check
            // For sub-byte types, accumulate bits then convert to bytes
            var min_bits: u32 = 0;
            for (pat.binary_match.segments) |seg| {
                switch (seg.type_spec) {
                    .default => min_bits += 8,
                    .integer => |i| min_bits += i.bits,
                    .float => |f| min_bits += f.bits,
                    .string => {
                        // Flush any partial byte first
                        if (min_bits % 8 != 0) min_bits = (min_bits + 7) / 8 * 8;
                        if (seg.string_literal) |sl| {
                            min_bits += @as(u32, @intCast(self.interner.get(sl).len)) * 8;
                        } else if (seg.size) |sz| {
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
            const min_bytes = (min_bits + 7) / 8;
            if (min_bytes > 0) {
                const len_check = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .bin_len_check = .{ .dest = len_check, .scrutinee = data_local, .min_len = min_bytes },
                });
                // Wrap remaining extractions in a guard block
                // (for single-clause we just emit inline — the check ensures safety)
            }

            // Track running byte and bit offsets
            var byte_offset: u32 = 0;
            var bit_offset: u8 = 0; // bits consumed within current byte (for sub-byte types)
            var offset_is_dynamic = false;
            var dynamic_offset_local: LocalId = 0;

            for (pat.binary_match.segments, 0..) |seg, seg_idx_usize| {
                const seg_idx: u32 = @intCast(seg_idx_usize);

                // Find the binding for this segment (if any)
                var binding_local: ?LocalId = null;
                for (clause.binary_bindings) |binding| {
                    if (binding.param_index == param_idx and binding.segment_index == seg_idx) {
                        binding_local = binding.local_index;
                        break;
                    }
                }

                // Handle string literal prefix segments
                if (seg.string_literal) |sl| {
                    const prefix_str = self.interner.get(sl);
                    const prefix_check = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .bin_match_prefix = .{
                            .dest = prefix_check,
                            .source = data_local,
                            .expected = prefix_str,
                        },
                    });
                    byte_offset += @intCast(prefix_str.len);
                    continue;
                }

                const current_offset: BinOffset = if (offset_is_dynamic)
                    .{ .dynamic = dynamic_offset_local }
                else
                    .{ .static = byte_offset };

                switch (seg.type_spec) {
                    .default => {
                        // Flush any partial bit offset to byte boundary
                        if (bit_offset > 0) {
                            byte_offset += 1;
                            bit_offset = 0;
                        }
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_int = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = 8,
                                    .signed = false,
                                    .endianness = .big,
                                },
                            });
                        }
                        if (!offset_is_dynamic) byte_offset += 1;
                    },
                    .integer => |int_spec| {
                        if (int_spec.bits < 8) {
                            // Sub-byte: track bit offset, compute shift
                            // Bits are extracted MSB-first within a byte
                            const shift: u8 = 8 - bit_offset - @as(u8, @intCast(int_spec.bits));
                            if (binding_local) |dest| {
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_read_int = .{
                                        .dest = dest,
                                        .source = data_local,
                                        .offset = current_offset,
                                        .bits = int_spec.bits,
                                        .signed = int_spec.signed,
                                        .endianness = seg.endianness,
                                        .bit_offset = shift,
                                    },
                                });
                            }
                            bit_offset += @intCast(int_spec.bits);
                            if (bit_offset >= 8) {
                                byte_offset += bit_offset / 8;
                                bit_offset = bit_offset % 8;
                            }
                        } else {
                            // Flush any partial bit offset
                            if (bit_offset > 0) {
                                byte_offset += 1;
                                bit_offset = 0;
                            }
                            if (binding_local) |dest| {
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_read_int = .{
                                        .dest = dest,
                                        .source = data_local,
                                        .offset = current_offset,
                                        .bits = int_spec.bits,
                                        .signed = int_spec.signed,
                                        .endianness = seg.endianness,
                                    },
                                });
                            }
                            if (!offset_is_dynamic) byte_offset += (int_spec.bits + 7) / 8;
                        }
                    },
                    .float => |float_spec| {
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_float = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = float_spec.bits,
                                    .endianness = seg.endianness,
                                },
                            });
                        }
                        if (!offset_is_dynamic) byte_offset += float_spec.bits / 8;
                    },
                    .string => {
                        if (seg.size) |size| {
                            switch (size) {
                                .literal => |n| {
                                    if (binding_local) |dest| {
                                        try self.current_instrs.append(self.allocator, .{
                                            .bin_slice = .{
                                                .dest = dest,
                                                .source = data_local,
                                                .offset = current_offset,
                                                .length = .{ .static = n },
                                            },
                                        });
                                    }
                                    if (!offset_is_dynamic) byte_offset += n;
                                },
                                .variable => |var_name| {
                                    const var_local = findBinaryVarLocal(clause, var_name);
                                    if (binding_local) |dest| {
                                        try self.current_instrs.append(self.allocator, .{
                                            .bin_slice = .{
                                                .dest = dest,
                                                .source = data_local,
                                                .offset = current_offset,
                                                .length = .{ .dynamic = var_local },
                                            },
                                        });
                                    }
                                    // After a dynamic-size segment, offset becomes dynamic
                                    if (!offset_is_dynamic) {
                                        // new_offset = byte_offset + var_local
                                        const static_base = self.next_local;
                                        self.next_local += 1;
                                        try self.current_instrs.append(self.allocator, .{
                                            .const_int = .{ .dest = static_base, .value = @intCast(byte_offset) },
                                        });
                                        dynamic_offset_local = self.next_local;
                                        self.next_local += 1;
                                        try self.current_instrs.append(self.allocator, .{
                                            .binary_op = .{ .dest = dynamic_offset_local, .op = .add, .lhs = static_base, .rhs = var_local },
                                        });
                                        offset_is_dynamic = true;
                                    }
                                },
                            }
                        } else {
                            // Rest of data
                            if (binding_local) |dest| {
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_slice = .{
                                        .dest = dest,
                                        .source = data_local,
                                        .offset = current_offset,
                                        .length = null,
                                    },
                                });
                            }
                        }
                    },
                    .utf8 => {
                        if (binding_local) |dest| {
                            const len_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_utf8 = .{
                                    .dest_codepoint = dest,
                                    .dest_len = len_local,
                                    .source = data_local,
                                    .offset = current_offset,
                                },
                            });
                            // UTF-8 is variable width — offset becomes dynamic
                            if (!offset_is_dynamic) {
                                const static_base = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{
                                    .const_int = .{ .dest = static_base, .value = @intCast(byte_offset) },
                                });
                                dynamic_offset_local = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{
                                    .binary_op = .{ .dest = dynamic_offset_local, .op = .add, .lhs = static_base, .rhs = len_local },
                                });
                                offset_is_dynamic = true;
                            }
                        }
                    },
                    .utf16, .utf32 => {
                        // TODO: implement utf16/utf32
                    },
                }
            }
        }
    }

    fn findBinaryVarLocal(clause: *const hir_mod.Clause, var_name: ast.StringId) LocalId {
        for (clause.binary_bindings) |binding| {
            if (binding.name == var_name) return binding.local_index;
        }
        return 0;
    }

    /// Emit binary segment extraction instructions for case expression bindings.
    /// Iterates over the binary match segments, computes byte/bit offsets, and
    /// emits bin_read_int/bin_read_float/bin_slice instructions targeting the
    /// binding locals from the case arm's CaseBinding entries.
    fn emitBinarySegmentExtractions(
        self: *IrBuilder,
        segments: []const hir_mod.BinaryMatchSegment,
        data_local: LocalId,
        case_arms: []const hir_mod.CaseArm,
    ) !void {
        var byte_offset: u32 = 0;
        var bit_offset: u8 = 0;
        var offset_is_dynamic = false;
        var dynamic_offset_local: LocalId = 0;

        for (segments, 0..) |seg, seg_idx_usize| {
            const seg_idx: u32 = @intCast(seg_idx_usize);

            // Find the binding local for this segment (if any) from case arm bindings
            var binding_local: ?LocalId = null;
            for (case_arms) |arm| {
                for (arm.bindings) |binding| {
                    if (binding.kind == .binary_element and binding.element_index == seg_idx) {
                        binding_local = binding.local_index;
                        break;
                    }
                }
                if (binding_local != null) break;
            }

            // Handle string literal prefix segments
            if (seg.string_literal) |sl| {
                const prefix_str = self.interner.get(sl);
                byte_offset += @intCast(prefix_str.len);
                continue;
            }

            const current_offset: BinOffset = if (offset_is_dynamic)
                .{ .dynamic = dynamic_offset_local }
            else
                .{ .static = byte_offset };

            switch (seg.type_spec) {
                .default => {
                    if (bit_offset > 0) {
                        byte_offset += 1;
                        bit_offset = 0;
                    }
                    if (binding_local) |dest| {
                        try self.current_instrs.append(self.allocator, .{
                            .bin_read_int = .{
                                .dest = dest,
                                .source = data_local,
                                .offset = current_offset,
                                .bits = 8,
                                .signed = false,
                                .endianness = .big,
                            },
                        });
                    }
                    if (!offset_is_dynamic) byte_offset += 1;
                },
                .integer => |int_spec| {
                    if (int_spec.bits < 8) {
                        const shift: u8 = 8 - bit_offset - @as(u8, @intCast(int_spec.bits));
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_int = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = int_spec.bits,
                                    .signed = int_spec.signed,
                                    .endianness = seg.endianness,
                                    .bit_offset = shift,
                                },
                            });
                        }
                        bit_offset += @intCast(int_spec.bits);
                        if (bit_offset >= 8) {
                            byte_offset += bit_offset / 8;
                            bit_offset = bit_offset % 8;
                        }
                    } else {
                        if (bit_offset > 0) {
                            byte_offset += 1;
                            bit_offset = 0;
                        }
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_read_int = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .bits = int_spec.bits,
                                    .signed = int_spec.signed,
                                    .endianness = seg.endianness,
                                },
                            });
                        }
                        if (!offset_is_dynamic) byte_offset += (int_spec.bits + 7) / 8;
                    }
                },
                .float => |float_spec| {
                    if (binding_local) |dest| {
                        try self.current_instrs.append(self.allocator, .{
                            .bin_read_float = .{
                                .dest = dest,
                                .source = data_local,
                                .offset = current_offset,
                                .bits = float_spec.bits,
                                .endianness = seg.endianness,
                            },
                        });
                    }
                    if (!offset_is_dynamic) byte_offset += float_spec.bits / 8;
                },
                .string => {
                    if (seg.size) |size| {
                        switch (size) {
                            .literal => |n| {
                                if (binding_local) |dest| {
                                    try self.current_instrs.append(self.allocator, .{
                                        .bin_slice = .{
                                            .dest = dest,
                                            .source = data_local,
                                            .offset = current_offset,
                                            .length = .{ .static = n },
                                        },
                                    });
                                }
                                if (!offset_is_dynamic) byte_offset += n;
                            },
                            .variable => {
                                // Dynamic-size string segments in case patterns
                                // are not yet supported for extraction.
                            },
                        }
                    } else {
                        // Rest of data (no explicit size)
                        if (binding_local) |dest| {
                            try self.current_instrs.append(self.allocator, .{
                                .bin_slice = .{
                                    .dest = dest,
                                    .source = data_local,
                                    .offset = current_offset,
                                    .length = null,
                                },
                            });
                        }
                    }
                },
                .utf8 => {
                    if (binding_local) |dest| {
                        const len_local = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .bin_read_utf8 = .{
                                .dest_codepoint = dest,
                                .dest_len = len_local,
                                .source = data_local,
                                .offset = current_offset,
                            },
                        });
                        if (!offset_is_dynamic) {
                            const static_base = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .const_int = .{ .dest = static_base, .value = @intCast(byte_offset) },
                            });
                            dynamic_offset_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .binary_op = .{ .dest = dynamic_offset_local, .op = .add, .lhs = static_base, .rhs = len_local },
                            });
                            offset_is_dynamic = true;
                        }
                    }
                },
                .utf16, .utf32 => {},
            }
        }
    }

    /// Emit index_get instructions to populate tuple binding locals.
    ///
    /// Each binding's `local_index` carries the runtime value of one slot of
    /// the tuple-typed parameter. Downstream IR passes (container dispatch,
    /// protocol dispatch, numeric widening, generic call-name encoding) read
    /// per-local types from `known_local_types`, so both the parent tuple
    /// local and each destructured element local must be registered with
    /// their concrete types here. Without it, an in-body `Map.get(m, ...)`
    /// where `m` came from `{m, k} :: {%{K=>V}, ...}` would default to the
    /// generic `Map(u32, ...)` variant and fail to type-check at the ZIR
    /// boundary; the parallel issue affects `<>` (Concatenable) on
    /// destructured String elements.
    fn emitTupleBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.tuple_bindings) |binding| {
            // Get the param (the tuple)
            const tuple_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = tuple_local, .index = binding.param_index },
            });
            // Resolve the parent tuple's static type so we can hand the
            // backend per-element types. The clause's declared parameter
            // types are authoritative after monomorphization (mirrors the
            // `param_get` lowering at `lowerExpr`).
            const param_type: ZigType = if (binding.param_index < clause.params.len)
                typeIdToZigTypeWithStore(clause.params[binding.param_index].type_id, self.type_store)
            else
                ZigType.any;
            if (param_type != .any) {
                try self.known_local_types.put(tuple_local, param_type);
            }
            // Extract the element into the binding's local index
            try self.current_instrs.append(self.allocator, .{
                .index_get = .{
                    .dest = binding.local_index,
                    .object = tuple_local,
                    .index = binding.element_index,
                },
            });
            // Propagate the static element type so downstream lookups (e.g.
            // `Map.get`'s key/value resolution, `<>`'s Concatenable dispatch,
            // numeric widening, generic call-name encoding) see the right
            // type for the destructured local.
            if (param_type == .tuple and binding.element_index < param_type.tuple.len) {
                const elem_type = param_type.tuple[binding.element_index];
                if (elem_type != .any) {
                    try self.known_local_types.put(binding.local_index, elem_type);
                }
            }
        }
    }

    /// Emit field_get instructions to populate struct binding locals.
    fn emitStructBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.struct_bindings) |binding| {
            const struct_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = struct_local, .index = binding.param_index },
            });
            // Track the param's struct type so the field_get lookup
            // resolves the nominal type and can attach storage info.
            const struct_name = self.interner.get(binding.struct_type);
            try self.known_local_types.put(struct_local, .{ .struct_ref = struct_name });
            const field_name = self.interner.get(binding.field_name);
            const info = self.fieldZigTypeAndStorage(struct_name, field_name);
            try self.current_instrs.append(self.allocator, .{
                .field_get = .{
                    .dest = binding.local_index,
                    .object = struct_local,
                    .field = field_name,
                    .struct_type = struct_name,
                },
            });
            if (info) |i| {
                try self.known_local_types.put(binding.local_index, i.type_expr);
            }
        }
    }

    fn emitMapBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.map_bindings) |binding| {
            // Get the param (the map)
            const map_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = map_local, .index = binding.param_index },
            });
            // Resolve the map's key/value types from the clause's
            // declared parameter type so the ZIR emitter instantiates
            // the right `Map(K, V)` cell for the runtime call. Without
            // this the emitter would default to `.atom`/`.i64`.
            const param_type = if (binding.param_index < clause.params.len)
                typeIdToZigTypeWithStore(clause.params[binding.param_index].type_id, self.type_store)
            else
                ZigType.any;
            const key_type: ZigType = if (param_type == .map) param_type.map.key.* else .atom;
            const value_type: ZigType = if (param_type == .map) param_type.map.value.* else .i64;
            // Track the binding's value type so `var_ref` lookups against
            // the destructured local emit correctly-typed downstream
            // instructions (e.g. string concat, arithmetic).
            try self.known_local_types.put(binding.local_index, value_type);
            // Track the param's map type so subsequent `map_get` locals
            // resolved through this same param_get path see the right
            // K/V (e.g. for `Map.get` calls in the body).
            if (param_type != .any) {
                try self.known_local_types.put(map_local, param_type);
            }
            // Lower the key expression to get the key local
            const key_local = try self.lowerExpr(binding.key_expr);
            // Create a default value matching the map's value type. The
            // pattern destructure semantically assumes the key exists,
            // so the default is unreachable at runtime — but the
            // compiler still type-checks it against the runtime
            // `Map(K, V).get` signature, so we must produce a value of
            // the right Zig type or the call won't typecheck.
            const default_local = try self.emitDefaultValueForType(value_type);
            // Extract the value via map_get
            try self.current_instrs.append(self.allocator, .{
                .map_get = .{
                    .dest = binding.local_index,
                    .map = map_local,
                    .key = key_local,
                    .default = default_local,
                    .key_type = key_type,
                    .value_type = value_type,
                },
            });
        }
    }

    /// Emit a default value of the given Zig type for use as `Map(K, V).get`'s
    /// `default` parameter when destructuring assumes key presence. The
    /// concrete runtime never observes this value (the get hits the existing
    /// entry), but the call must still typecheck through the monomorphised
    /// `Map(K, V).get` signature.
    fn emitDefaultValueForType(self: *IrBuilder, value_type: ZigType) !LocalId {
        const default_local = self.next_local;
        self.next_local += 1;
        switch (value_type) {
            .string => {
                try self.current_instrs.append(self.allocator, .{
                    .const_string = .{ .dest = default_local, .value = "" },
                });
            },
            .bool_type => {
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = default_local, .value = false },
                });
            },
            .f32, .f64, .f16, .f80, .f128 => {
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = default_local, .value = 0.0 },
                });
            },
            .atom => {
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = default_local, .value = 0 },
                });
            },
            .nil => {
                try self.current_instrs.append(self.allocator, .{
                    .const_nil = default_local,
                });
            },
            else => {
                // Numeric or unknown — `0` works as a placeholder for
                // any integer type the runtime cell instantiates.
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = default_local, .value = 0 },
                });
            },
        }
        return default_local;
    }

    /// AND two boolean locals together.
    fn emitAnd(self: *IrBuilder, lhs: LocalId, rhs: LocalId) !LocalId {
        const result = self.next_local;
        self.next_local += 1;
        try self.current_instrs.append(self.allocator, .{
            .binary_op = .{ .dest = result, .op = .bool_and, .lhs = lhs, .rhs = rhs },
        });
        return result;
    }

    /// AND a refinement predicate with an existing condition, if present.
    fn emitRefinement(self: *IrBuilder, clause: *const hir_mod.Clause, condition: LocalId) !LocalId {
        if (clause.refinement) |ref_expr| {
            const ref_local = try self.lowerExpr(ref_expr);
            return self.emitAnd(condition, ref_local);
        }
        return condition;
    }

    /// Emit a check for a literal sub-pattern against an already-extracted element local.
    fn emitSubPatternCheck(self: *IrBuilder, elem_local: LocalId, lit: hir_mod.LiteralValue) !LocalId {
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = elem_local, .atom_name = self.interner.get(v) },
                });
                return match_local;
            },
            .int => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_int = .{ .dest = match_local, .scrutinee = elem_local, .value = v },
                });
                return match_local;
            },
            .float => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_float = .{ .dest = match_local, .scrutinee = elem_local, .value = v },
                });
                return match_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = elem_local, .expected = self.interner.get(v) },
                });
                return match_local;
            },
            else => {
                // For bool, nil sub-patterns in tuples
                const lit_local = self.next_local;
                self.next_local += 1;
                switch (lit) {
                    .bool_val => |v| try self.current_instrs.append(self.allocator, .{
                        .const_bool = .{ .dest = lit_local, .value = v },
                    }),
                    .nil => try self.current_instrs.append(self.allocator, .{ .const_nil = lit_local }),
                    else => unreachable,
                }
                const cmp_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = cmp_local, .op = .eq, .lhs = elem_local, .rhs = lit_local },
                });
                return cmp_local;
            },
        };
    }

    /// Lower a case expression: reserve binding locals, then allocate dest/scrutinee,
    /// then build the case_block. Returns the dest local ID.
    fn lowerCaseExpr(self: *IrBuilder, case_data: hir_mod.CaseData) !LocalId {
        // Reserve binding local indices FIRST so that dest and scrutinee
        // don't conflict with locals defined inside if-scoped blocks.
        {
            var max_binding_local: u32 = self.next_local;
            for (case_data.arms) |arm| {
                for (arm.bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
            }
            self.next_local = max_binding_local;
        }

        // NOW allocate dest (after reservation — no shadowing risk)
        const dest = self.next_local;
        self.next_local += 1;

        // Lower scrutinee (also after reservation)
        const scrutinee_local = try self.lowerExpr(case_data.scrutinee);

        try self.lowerCaseExprBody(dest, scrutinee_local, case_data);
        return dest;
    }

    /// Check if all non-default arms are integer or bool literals of the same type with no guards.
    const SwitchableType = enum { int, bool_val };
    fn canSwitchLiteral(arms: []const hir_mod.CaseArm) ?SwitchableType {
        if (arms.len < 2) return null;

        var switchable_type: ?SwitchableType = null;

        for (arms, 0..) |arm, arm_idx| {
            const is_last = arm_idx == arms.len - 1;
            const pat = arm.pattern orelse return null;

            // Any arm with a guard disqualifies
            if (arm.guard != null) return null;

            if (pat.* == .wildcard or pat.* == .bind) {
                // Wildcard/bind is allowed only as the last arm (default)
                if (!is_last) return null;
                // Default arm is ok
                continue;
            }

            if (pat.* != .literal) return null;

            const lit_type: SwitchableType = switch (pat.literal) {
                .int => .int,
                .bool_val => .bool_val,
                else => return null, // atoms, strings, floats can't switch
            };

            if (switchable_type) |st| {
                if (st != lit_type) return null; // mixed types
            } else {
                switchable_type = lit_type;
            }
        }

        return switchable_type;
    }

    /// Build the case_block instruction body.
    fn lowerCaseExprBody(self: *IrBuilder, dest: LocalId, scrutinee_local: LocalId, case_data: hir_mod.CaseData) !void {
        // Try to emit a switch for homogeneous integer/bool literals with no guards
        if (canSwitchLiteral(case_data.arms)) |_| {
            var lit_cases: std.ArrayList(LitCase) = .empty;

            for (case_data.arms, 0..) |arm, arm_idx| {
                const is_last = arm_idx == case_data.arms.len - 1;
                const pat = arm.pattern.?;

                if (is_last and (pat.* == .wildcard or pat.* == .bind)) {
                    // Default arm
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;

                    if (pat.* == .bind) {
                        for (arm.bindings) |binding| {
                            if (binding.kind == .scrutinee) {
                                try self.emitLocalGet(binding.local_index, scrutinee_local);
                            }
                        }
                    }

                    const body_result = try self.lowerBlock(arm.body);
                    const default_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;

                    try self.current_instrs.append(self.allocator, .{
                        .switch_literal = .{
                            .dest = dest,
                            .scrutinee = scrutinee_local,
                            .cases = try lit_cases.toOwnedSlice(self.allocator),
                            .default_instrs = default_instrs,
                            .default_result = body_result,
                        },
                    });
                    return;
                }

                // Literal case arm
                const lit_value: LiteralValue = switch (pat.literal) {
                    .int => |v| .{ .int = v },
                    .bool_val => |v| .{ .bool_val = v },
                    else => unreachable,
                };

                const saved = self.current_instrs;
                self.current_instrs = .empty;
                const body_result = try self.lowerBlock(arm.body);
                const body_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;

                try lit_cases.append(self.allocator, .{
                    .value = lit_value,
                    .body_instrs = body_instrs,
                    .result = body_result,
                });
            }

            // All arms are literal (no default) — add match_fail as default
            const saved = self.current_instrs;
            self.current_instrs = .empty;
            try self.current_instrs.append(self.allocator, .{
                .match_fail = .{ .message = "no matching case clause" },
            });
            const fail_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved;

            try self.current_instrs.append(self.allocator, .{
                .switch_literal = .{
                    .dest = dest,
                    .scrutinee = scrutinee_local,
                    .cases = try lit_cases.toOwnedSlice(self.allocator),
                    .default_instrs = fail_instrs,
                    .default_result = null,
                },
            });
            return;
        }

        // General path: compile pattern matrix and lower decision tree
        {
            var pattern_rows: std.ArrayList(hir_mod.PatternRow) = .empty;
            for (case_data.arms, 0..) |arm, arm_idx| {
                var pats: std.ArrayList(?*const hir_mod.MatchPattern) = .empty;
                try pats.append(self.allocator, arm.pattern);
                try pattern_rows.append(self.allocator, .{
                    .patterns = try pats.toOwnedSlice(self.allocator),
                    .body_index = @intCast(arm_idx),
                    .guard = arm.guard,
                });
            }

            var scrutinee_map = std.AutoHashMap(u32, LocalId).init(self.allocator);
            defer scrutinee_map.deinit();
            try scrutinee_map.put(0, scrutinee_local);

            var next_scrutinee_id: u32 = 1;
            const decision = try hir_mod.compilePatternMatrix(
                self.allocator,
                .{
                    .rows = try pattern_rows.toOwnedSlice(self.allocator),
                    .column_count = 1,
                },
                try self.allocSlice(u32, &.{0}),
                &next_scrutinee_id,
            );

            // Emit case_block wrapping the decision tree lowering
            const saved_outer = self.current_instrs;
            self.current_instrs = .empty;
            try self.lowerDecisionTreeForCase(decision, case_data.arms, &scrutinee_map, dest);
            const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
            self.current_instrs = saved_outer;

            try self.current_instrs.append(self.allocator, .{
                .case_block = .{
                    .dest = dest,
                    .pre_instrs = case_body,
                    .arms = &.{},
                    .default_instrs = &.{},
                    .default_result = null,
                },
            });
            return;
        }
    }

    /// Lower a decision tree for case expressions, emitting case_break at leaves.
    fn lowerDecisionTreeForCase(
        self: *IrBuilder,
        decision: *const hir_mod.Decision,
        case_arms: []const hir_mod.CaseArm,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
        dest: LocalId,
    ) anyerror!void {
        _ = dest;
        switch (decision.*) {
            .success => |leaf| {
                const arm = case_arms[leaf.body_index];
                // Emit only scrutinee bindings (whole-value binds like `v -> v`).
                // Extracted bindings (tuple/list/struct/map elements) are handled
                // by bind nodes in the decision tree path, which resolve to the
                // correct decomposed locals.
                for (arm.bindings) |binding| {
                    if (binding.kind == .scrutinee) {
                        const scr_local = scrutinee_map.get(0) orelse 0;
                        try self.emitLocalGet(binding.local_index, scr_local);
                    }
                }
                const body_result = try self.lowerBlock(arm.body);
                try self.current_instrs.append(self.allocator, .{
                    .case_break = .{ .value = body_result },
                });
            },
            .failure => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "no matching case clause" },
                });
            },
            .guard => |guard_node| {
                try self.current_instrs.append(self.allocator, .{ .set_safety = false });
                const guard_local = try self.lowerGuardExpr(guard_node.condition, scrutinee_map);
                try self.current_instrs.append(self.allocator, .{ .set_safety = true });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                try self.lowerDecisionTreeForCase(guard_node.success, case_arms, scrutinee_map, 0);
                const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = guard_local, .body = guard_body },
                });
                try self.lowerDecisionTreeForCase(guard_node.failure, case_arms, scrutinee_map, 0);
            },
            .switch_literal => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const check_local = try self.emitSubPatternCheck(scrutinee_local, case.value);
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, 0);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, 0);
            },
            .switch_tag => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const tag_name = self.interner.get(case.tag);
                    const match_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_atom = .{ .dest = match_local, .scrutinee = scrutinee_local, .atom_name = tag_name },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForCase(case.next, case_arms, scrutinee_map, 0);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = match_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForCase(sw.default, case_arms, scrutinee_map, 0);
            },
            .check_tuple => |ct| {
                // For case expressions in statically typed code, the tuple type
                // check always passes. Emit element extraction and inner guards
                // at the CURRENT level (no guard_block wrapper). This ensures
                // inner guard_blocks (from atom switches) appear as flat siblings
                // in the case_block's pre_instrs, enabling proper if-else nesting
                // by emitFlatCaseBlock.
                const scrutinee_local = self.resolveScrutinee(ct.scrutinee, scrutinee_map);
                // When the scrutinee is a tuple extracted from a heterogeneous
                // keyword list (param-backed list_get with `via_helper`), the
                // runtime tuple's components are Term while the declared per-
                // slot types are concrete. Tell `index_get` which concrete
                // type to coerce each slot back to via `Term.toCoerced`.
                const term_tuple_decl: ?ZigType = self.term_tuple_locals.get(scrutinee_local);
                var i: u32 = 0;
                while (i < ct.expected_arity) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    const coerce_to: ZigType = if (term_tuple_decl) |tdecl| blk: {
                        if (tdecl == .tuple and i < tdecl.tuple.len) {
                            const slot_type = tdecl.tuple[i];
                            if (slot_type != .term) break :blk slot_type;
                        }
                        break :blk .any;
                    } else .any;
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{ .dest = elem_local, .object = scrutinee_local, .index = i, .coerce_term_to = coerce_to },
                    });
                    if (coerce_to != .any) {
                        try self.known_local_types.put(elem_local, coerce_to);
                    }
                    const elem_id = if (i < ct.element_scrutinee_ids.len)
                        ct.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(ct.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                // Lower success subtree at the same level — inner guards become
                // flat guard_blocks that emitFlatCaseBlock can process
                try self.lowerDecisionTreeForCase(ct.success, case_arms, scrutinee_map, 0);
            },
            .check_list => |cl| {
                const scrutinee_local = self.resolveScrutinee(cl.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local);
                // When the scrutinee comes from a param, the runtime element
                // type may diverge from the declared one (e.g. heterogeneous
                // keyword list `[name: "x", age: 42]` passed to a function
                // declared `[{Atom, i64}]`). Route through the type-derived
                // `listLength`/`listGet` helpers so the actual element type
                // is read from `@TypeOf(list)` instead of the stale declared
                // element type.
                const dispatch_via_helper = self.localBackedByParam(scrutinee_local);
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .expected_len = cl.expected_length, .element_type = elem_type, .via_helper = dispatch_via_helper },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < cl.expected_length) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = elem_local, .list = scrutinee_local, .index = i, .element_type = elem_type, .via_helper = dispatch_via_helper },
                    });
                    try self.known_local_types.put(elem_local, elem_type);
                    // When the list is param-backed AND its declared element
                    // type is a tuple, the actual runtime element is a tuple
                    // whose components may have been Term-promoted (the param
                    // type `[{Atom, i64}]` accepts `[{Atom, Term}]` at runtime).
                    // Track this so a later `index_get` from `elem_local` can
                    // unwrap each Term slot back to the declared component
                    // type via `Term.toCoerced(value, default)`.
                    if (dispatch_via_helper and elem_type == .tuple) {
                        try self.term_tuple_locals.put(elem_local, elem_type);
                    }
                    // Use the explicit element_scrutinee_ids when available
                    // (always populated by the compiler), falling back to the
                    // legacy heuristic only for older fixtures that may have
                    // hand-constructed CheckListNodes without the field.
                    const elem_id = if (i < cl.element_scrutinee_ids.len)
                        cl.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(cl.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                try self.lowerDecisionTreeForCase(cl.success, case_arms, scrutinee_map, 0);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(cl.failure, case_arms, scrutinee_map, 0);
            },
            .check_list_cons => |clc| {
                const scrutinee_local = self.resolveScrutinee(clc.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local);
                const scrutinee_list_type = self.known_local_types.get(scrutinee_local) orelse .any;
                // Same param-backed dispatch shim as check_list — route
                // through the type-derived list helpers when the scrutinee
                // came from a param so the runtime element type is honored.
                const dispatch_via_helper = self.localBackedByParam(scrutinee_local);
                const not_empty_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_is_not_empty = .{ .dest = not_empty_local, .list = scrutinee_local, .element_type = elem_type, .via_helper = dispatch_via_helper },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                var current_list = scrutinee_local;
                while (i < clc.head_count) : (i += 1) {
                    const head_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_head = .{ .dest = head_local, .list = current_list, .element_type = elem_type, .via_helper = dispatch_via_helper },
                    });
                    try self.known_local_types.put(head_local, elem_type);
                    // Phase H.1: propagate the HIR element type so any
                    // downstream local_get/share_value chain that flows
                    // from this head into a function argument sees a
                    // consistent ARC-managed status. Without this, the
                    // chain falls back to `.trivial` and the verifier's
                    // V2 invariant rejects the matching post-call
                    // release once `.list` joins the ARC-managed set.
                    try self.recordListChildHirType(current_list, head_local, .element);
                    try scrutinee_map.put(clc.head_scrutinee_ids[i], head_local);
                    if (i + 1 < clc.head_count) {
                        const next_list = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .list_tail = .{ .dest = next_list, .list = current_list, .element_type = elem_type, .via_helper = dispatch_via_helper },
                        });
                        try self.known_local_types.put(next_list, scrutinee_list_type);
                        // Same propagation for intermediate tail locals
                        // (multi-head pattern unfolds chain into a series
                        // of list_tails feeding into the next list_head).
                        try self.recordListChildHirType(current_list, next_list, .list);
                        current_list = next_list;
                    }
                }
                const tail_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = tail_local, .list = current_list, .element_type = elem_type, .via_helper = dispatch_via_helper },
                });
                try self.known_local_types.put(tail_local, scrutinee_list_type);
                try self.recordListChildHirType(current_list, tail_local, .list);
                try scrutinee_map.put(clc.tail_scrutinee_id, tail_local);
                try self.lowerDecisionTreeForCase(clc.success, case_arms, scrutinee_map, 0);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = not_empty_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(clc.failure, case_arms, scrutinee_map, 0);
            },
            .check_binary => |cb| {
                const scrutinee_local = self.resolveScrutinee(cb.scrutinee, scrutinee_map);
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .bin_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .min_len = cb.min_byte_size },
                });

                // Emit bin_match_prefix for each string literal prefix segment
                // and AND the result with the length check condition.
                var condition_local = len_check_local;
                for (cb.segments) |seg| {
                    if (seg.string_literal) |sl| {
                        const prefix_str = self.interner.get(sl);
                        const prefix_check_local = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .bin_match_prefix = .{
                                .dest = prefix_check_local,
                                .source = scrutinee_local,
                                .expected = prefix_str,
                            },
                        });
                        condition_local = try self.emitAnd(condition_local, prefix_check_local);
                    }
                }

                const saved = self.current_instrs;
                self.current_instrs = .empty;

                // Emit binary segment extraction instructions for case arm bindings.
                // Each segment with a bind pattern needs a bin_read_int/bin_read_float/bin_slice
                // instruction to extract the value into the binding's local.
                try self.emitBinarySegmentExtractions(cb.segments, scrutinee_local, case_arms);

                try self.lowerDecisionTreeForCase(cb.success, case_arms, scrutinee_map, 0);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = condition_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(cb.failure, case_arms, scrutinee_map, 0);
            },
            .bind => |bind_node| {
                // Emit binding: resolve scrutinee and assign to binding local
                const scrutinee_local = self.resolveScrutinee(bind_node.source, scrutinee_map);
                // Find matching CaseBinding by name to get the local_index
                for (case_arms) |arm| {
                    for (arm.bindings) |binding| {
                        if (binding.name == bind_node.name) {
                            try self.emitLocalGet(binding.local_index, scrutinee_local);
                            break;
                        }
                    }
                }
                try self.lowerDecisionTreeForCase(bind_node.next, case_arms, scrutinee_map, 0);
            },
            .extract_struct => |es| {
                const scrutinee_local = self.resolveScrutinee(es.scrutinee, scrutinee_map);
                const struct_type = self.structTypeForFieldReceiver(scrutinee_local);
                for (es.fields) |fe| {
                    const field_local = self.next_local;
                    self.next_local += 1;
                    const field_name = self.interner.get(fe.field_name);
                    const field_info = if (struct_type) |sname|
                        self.fieldZigTypeAndStorage(sname, field_name)
                    else
                        null;
                    try self.current_instrs.append(self.allocator, .{
                        .field_get = .{
                            .dest = field_local,
                            .object = scrutinee_local,
                            .field = field_name,
                            .struct_type = struct_type,
                        },
                    });
                    if (field_info) |i| {
                        try self.known_local_types.put(field_local, i.type_expr);
                    }
                    try scrutinee_map.put(fe.scrutinee_id, field_local);
                }
                try self.lowerDecisionTreeForCase(es.success, case_arms, scrutinee_map, 0);
            },
            .extract_map => |em| {
                const scrutinee_local = self.resolveScrutinee(em.scrutinee, scrutinee_map);
                // Pull the map's K/V from the scrutinee's known type
                // so the ZIR emitter looks up the right `Map(K, V)`
                // cell. Falls back to atom→i64 for legacy maps that
                // don't carry concrete types.
                const map_zig_type = self.known_local_types.get(scrutinee_local) orelse ZigType.any;
                const key_type: ZigType = if (map_zig_type == .map) map_zig_type.map.key.* else .atom;
                const value_type: ZigType = if (map_zig_type == .map) map_zig_type.map.value.* else .i64;
                for (em.keys) |ke| {
                    const key_local = try self.lowerExpr(ke.key);
                    const default_local = try self.emitDefaultValueForType(value_type);
                    const value_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .map_get = .{
                            .dest = value_local,
                            .map = scrutinee_local,
                            .key = key_local,
                            .default = default_local,
                            .key_type = key_type,
                            .value_type = value_type,
                        },
                    });
                    try self.known_local_types.put(value_local, value_type);
                    try scrutinee_map.put(ke.scrutinee_id, value_local);
                }
                try self.lowerDecisionTreeForCase(em.success, case_arms, scrutinee_map, 0);
            },
        }
    }

    /// Lower a decision tree for function dispatch, emitting ret at leaves.
    fn lowerDecisionTreeForDispatch(
        self: *IrBuilder,
        decision: *const hir_mod.Decision,
        clauses: []const hir_mod.Clause,
        scrutinee_map: *std.AutoHashMap(u32, LocalId),
    ) anyerror!void {
        switch (decision.*) {
            .success => |leaf| {
                const clause = &clauses[leaf.body_index];
                for (clause.tuple_bindings) |binding| {
                    const tuple_local = scrutinee_map.get(binding.param_index) orelse blk: {
                        const pl = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .param_get = .{ .dest = pl, .index = binding.param_index },
                        });
                        break :blk pl;
                    };
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{
                            .dest = binding.local_index,
                            .object = tuple_local,
                            .index = binding.element_index,
                        },
                    });
                }
                // Emit list element bindings
                for (clause.list_bindings) |binding| {
                    const list_local = scrutinee_map.get(binding.param_index) orelse blk: {
                        const pl = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .param_get = .{ .dest = pl, .index = binding.param_index },
                        });
                        // Track fallback param's type so listElementTypeForLocal works
                        if (binding.param_index < clause.params.len) {
                            const param_type = typeIdToZigTypeWithStore(clause.params[binding.param_index].type_id, self.type_store);
                            if (param_type != .any) {
                                try self.known_local_types.put(pl, param_type);
                            }
                            // Propagate the param's HIR type so downstream
                            // chains (local_get, share_value, release) see
                            // the correct ARC-managed status. Without this,
                            // the fallback-param local's hir type stays
                            // unset and any reuse of `binding.local_index`
                            // via local_get below cannot inherit the
                            // expected list HIR type.
                            try self.local_hir_types.put(pl, clause.params[binding.param_index].type_id);
                        }
                        break :blk pl;
                    };
                    const list_elem_type = self.listElementTypeForLocal(list_local);
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{
                            .dest = binding.local_index,
                            .list = list_local,
                            .index = binding.element_index,
                            .element_type = list_elem_type,
                        },
                    });
                    try self.known_local_types.put(binding.local_index, list_elem_type);
                    // Phase H.1: propagate the HIR element type onto the
                    // binding local. Without this, the binding's
                    // `local_hir_types` entry stays at whatever the local
                    // id had been used for previously (often non-ARC),
                    // which causes `isArcManagedLocal(binding)` to return
                    // false and breaks any downstream
                    // share_value/release chain whose source flows from
                    // this binding. Pulled from the list's recorded HIR
                    // type via the type-store's `.list.element` field.
                    try self.recordListChildHirType(list_local, binding.local_index, .element);
                }
                // Emit cons tail bindings: copy decision tree tail locals to binding locals
                for (clause.cons_tail_bindings) |binding| {
                    // The tail was extracted by check_list_cons and stored in scrutinee_map.
                    // Find the tail local and copy it to the binding's local_index.
                    // The scrutinee_map maps scrutinee IDs → locals, but we need to find
                    // the tail by param_index. Look for the list param's tail local.
                    const list_local = scrutinee_map.get(binding.param_index) orelse continue;
                    // The tail is the list local itself (after head extraction, the remaining
                    // scrutinee entries represent tails). Search for a tail scrutinee.
                    // For simplicity, use list_tail on the original list to get the tail.
                    const list_elem_type = self.listElementTypeForLocal(list_local);
                    const scrutinee_list_type = self.known_local_types.get(list_local) orelse .any;
                    try self.current_instrs.append(self.allocator, .{
                        .list_tail = .{ .dest = binding.local_index, .list = list_local, .element_type = list_elem_type },
                    });
                    try self.known_local_types.put(binding.local_index, scrutinee_list_type);
                    // Phase H.1: propagate the HIR list type onto the
                    // tail binding local. The tail of a list has the
                    // same list HIR type as the source list — pull it
                    // from the source's recorded `local_hir_types`
                    // entry. Without this, the binding's hir type
                    // stays unset (or stale from a prior reuse of the
                    // local id), and the downstream
                    // share_value/release path fires on a local whose
                    // ownership class is computed as `.trivial`,
                    // tripping the verifier's V2 invariant once
                    // `.list` joins the ARC-managed type set.
                    try self.recordListChildHirType(list_local, binding.local_index, .list);
                }
                // Emit binary/struct bindings
                try self.emitBinaryBindings(clause);
                try self.emitStructBindings(clause);
                const result_local = try self.lowerBlock(clause.body);
                try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
            },
            .failure => {
                if (self.try_mode) {
                    // Return sentinel empty string — caller checks and substitutes handler
                    try self.current_instrs.append(self.allocator, .{
                        .match_error_return = .{ .scrutinee = 0 },
                    });
                } else {
                    try self.current_instrs.append(self.allocator, .{
                        .match_fail = .{ .message = "no matching clause" },
                    });
                }
            },
            .guard => |guard_node| {
                // Disable runtime safety during guard condition evaluation.
                // If the guard expression triggers a safety check (overflow,
                // bounds, etc.), the result is undefined rather than a panic,
                // causing the guard to evaluate to false and skip to the next clause.
                try self.current_instrs.append(self.allocator, .{ .set_safety = false });
                const guard_local = try self.lowerGuardExpr(guard_node.condition, scrutinee_map);
                try self.current_instrs.append(self.allocator, .{ .set_safety = true });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                try self.lowerDecisionTreeForDispatch(guard_node.success, clauses, scrutinee_map);
                const guard_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = guard_local, .body = guard_body },
                });
                try self.lowerDecisionTreeForDispatch(guard_node.failure, clauses, scrutinee_map);
            },
            .switch_literal => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const skip = self.shouldSkipTypeCheck(scrutinee_local, case.value);
                    const check_local = try self.emitSubPatternCheckWithSkip(scrutinee_local, case.value, skip);
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = check_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .switch_tag => |sw| {
                const scrutinee_local = self.resolveScrutinee(sw.scrutinee, scrutinee_map);
                for (sw.cases) |case| {
                    const tag_name = self.interner.get(case.tag);
                    const match_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .match_atom = .{ .dest = match_local, .scrutinee = scrutinee_local, .atom_name = tag_name },
                    });
                    const saved = self.current_instrs;
                    self.current_instrs = .empty;
                    try self.lowerDecisionTreeForDispatch(case.next, clauses, scrutinee_map);
                    const case_body = try self.current_instrs.toOwnedSlice(self.allocator);
                    self.current_instrs = saved;
                    try self.current_instrs.append(self.allocator, .{
                        .guard_block = .{ .condition = match_local, .body = case_body },
                    });
                }
                try self.lowerDecisionTreeForDispatch(sw.default, clauses, scrutinee_map);
            },
            .check_tuple => |ct| {
                const scrutinee_local = self.resolveScrutinee(ct.scrutinee, scrutinee_map);
                const type_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_type = .{ .dest = type_check_local, .scrutinee = scrutinee_local, .expected_type = .{ .tuple = &.{} }, .expected_arity = ct.expected_arity },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < ct.expected_arity) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .index_get = .{ .dest = elem_local, .object = scrutinee_local, .index = i },
                    });
                    const elem_id = if (i < ct.element_scrutinee_ids.len)
                        ct.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(ct.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                try self.lowerDecisionTreeForDispatch(ct.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = type_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(ct.failure, clauses, scrutinee_map);
            },
            .check_list => |cl| {
                const scrutinee_local = self.resolveScrutinee(cl.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local);
                // Emit: __local_N = scrutinee.len == expected_length
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .expected_len = cl.expected_length, .element_type = elem_type },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                // Extract list elements into locals
                var i: u32 = 0;
                while (i < cl.expected_length) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = elem_local, .list = scrutinee_local, .index = i, .element_type = elem_type },
                    });
                    try self.known_local_types.put(elem_local, elem_type);
                    try self.recordListChildHirType(scrutinee_local, elem_local, .element);
                    try scrutinee_map.put(findParamGetIdInDecision(cl.success, i), elem_local);
                }
                try self.lowerDecisionTreeForDispatch(cl.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(cl.failure, clauses, scrutinee_map);
            },
            .check_list_cons => |clc| {
                const scrutinee_local = self.resolveScrutinee(clc.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local);
                const scrutinee_list_type = self.known_local_types.get(scrutinee_local) orelse .any;
                // Emit non-empty check: List.isEmpty(list) == false
                const not_empty_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_is_not_empty = .{ .dest = not_empty_local, .list = scrutinee_local, .element_type = elem_type },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                // Extract head elements
                var i: u32 = 0;
                var current_list = scrutinee_local;
                while (i < clc.head_count) : (i += 1) {
                    const head_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_head = .{ .dest = head_local, .list = current_list, .element_type = elem_type },
                    });
                    try self.known_local_types.put(head_local, elem_type);
                    try self.recordListChildHirType(current_list, head_local, .element);
                    try scrutinee_map.put(clc.head_scrutinee_ids[i], head_local);
                    if (i + 1 < clc.head_count) {
                        const next_list = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .list_tail = .{ .dest = next_list, .list = current_list, .element_type = elem_type },
                        });
                        try self.known_local_types.put(next_list, scrutinee_list_type);
                        try self.recordListChildHirType(current_list, next_list, .list);
                        current_list = next_list;
                    }
                }
                // Extract tail
                const tail_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = tail_local, .list = current_list, .element_type = elem_type },
                });
                try self.known_local_types.put(tail_local, scrutinee_list_type);
                try self.recordListChildHirType(current_list, tail_local, .list);
                try scrutinee_map.put(clc.tail_scrutinee_id, tail_local);

                try self.lowerDecisionTreeForDispatch(clc.success, clauses, scrutinee_map);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = not_empty_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(clc.failure, clauses, scrutinee_map);
            },
            .check_binary => |cb| {
                const scrutinee_local = self.resolveScrutinee(cb.scrutinee, scrutinee_map);
                // Emit length check
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .bin_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .min_len = cb.min_byte_size },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;

                if (clauses.len > 1) {
                    // Multi-clause binary dispatch: emit per-clause guarded bodies.
                    // Each clause with a binary pattern gets its own extraction + guard.
                    // Clauses without binary patterns (wildcards) are handled by cb.failure.
                    for (clauses) |clause| {
                        // Skip clauses that don't have binary patterns (handled by cb.failure)
                        var has_binary = false;
                        for (clause.params) |param| {
                            if (param.pattern) |pat| {
                                if (pat.* == .binary_match) {
                                    has_binary = true;
                                    break;
                                }
                            }
                        }
                        if (!has_binary) continue;

                        const inner_saved = self.current_instrs;
                        self.current_instrs = .empty;
                        try self.emitBinaryBindings(&clause);
                        const result_local = try self.lowerBlock(clause.body);
                        try self.current_instrs.append(self.allocator, .{ .ret = .{ .value = result_local } });
                        const all_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                        self.current_instrs = inner_saved;

                        // Find any guard condition (bin_match_prefix or bin_len_check)
                        // and split instructions: pre-guard setup vs guarded body.
                        var guard_cond: ?LocalId = null;
                        var split_idx: usize = 0;
                        for (all_instrs, 0..) |instr, idx| {
                            switch (instr) {
                                .bin_match_prefix => |bmp| {
                                    guard_cond = bmp.dest;
                                    split_idx = idx + 1;
                                    break;
                                },
                                else => {},
                            }
                        }

                        if (guard_cond) |cond| {
                            // Emit setup instructions, then wrap body in guard
                            for (all_instrs[0..split_idx]) |instr| {
                                try self.current_instrs.append(self.allocator, instr);
                            }
                            try self.current_instrs.append(self.allocator, .{
                                .guard_block = .{ .condition = cond, .body = all_instrs[split_idx..] },
                            });
                        } else {
                            // No string-literal prefix guard — wrap the whole body
                            // in a length check guard to differentiate from fallback
                            var clause_min_bits: u32 = 0;
                            for (clause.params) |param| {
                                if (param.pattern) |pat| {
                                    if (pat.* == .binary_match) {
                                        for (pat.binary_match.segments) |seg| {
                                            clause_min_bits += switch (seg.type_spec) {
                                                .default => 8,
                                                .integer => |i| i.bits,
                                                .float => |f| f.bits,
                                                .string => 0,
                                                .utf8 => 8,
                                                .utf16 => 16,
                                                .utf32 => 32,
                                            };
                                        }
                                    }
                                }
                            }
                            const clause_min_bytes = (clause_min_bits + 7) / 8;
                            if (clause_min_bytes > 0) {
                                const clause_len_check = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{
                                    .bin_len_check = .{ .dest = clause_len_check, .scrutinee = scrutinee_local, .min_len = clause_min_bytes },
                                });
                                try self.current_instrs.append(self.allocator, .{
                                    .guard_block = .{ .condition = clause_len_check, .body = all_instrs },
                                });
                            } else {
                                // Zero min bytes — just emit inline
                                for (all_instrs) |instr| {
                                    try self.current_instrs.append(self.allocator, instr);
                                }
                            }
                        }
                    }
                } else {
                    // Single-clause binary: use normal decision tree
                    try self.lowerDecisionTreeForDispatch(cb.success, clauses, scrutinee_map);
                }

                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = len_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForDispatch(cb.failure, clauses, scrutinee_map);
            },
            .bind => |bind_node| {
                try self.lowerDecisionTreeForDispatch(bind_node.next, clauses, scrutinee_map);
            },
            .extract_struct => |es| {
                const scrutinee_local = self.resolveScrutinee(es.scrutinee, scrutinee_map);
                const struct_type = self.structTypeForFieldReceiver(scrutinee_local);
                for (es.fields) |fe| {
                    const field_local = self.next_local;
                    self.next_local += 1;
                    const field_name = self.interner.get(fe.field_name);
                    const field_info = if (struct_type) |sname|
                        self.fieldZigTypeAndStorage(sname, field_name)
                    else
                        null;
                    try self.current_instrs.append(self.allocator, .{
                        .field_get = .{
                            .dest = field_local,
                            .object = scrutinee_local,
                            .field = field_name,
                            .struct_type = struct_type,
                        },
                    });
                    if (field_info) |i| {
                        try self.known_local_types.put(field_local, i.type_expr);
                    }
                    try scrutinee_map.put(fe.scrutinee_id, field_local);
                }
                try self.lowerDecisionTreeForDispatch(es.success, clauses, scrutinee_map);
            },
            .extract_map => |em| {
                const scrutinee_local = self.resolveScrutinee(em.scrutinee, scrutinee_map);
                // Pull the map's K/V from the scrutinee's known type
                // so the ZIR emitter looks up the right `Map(K, V)`
                // cell. Falls back to atom→i64 for legacy maps that
                // don't carry concrete types.
                const map_zig_type = self.known_local_types.get(scrutinee_local) orelse ZigType.any;
                const key_type: ZigType = if (map_zig_type == .map) map_zig_type.map.key.* else .atom;
                const value_type: ZigType = if (map_zig_type == .map) map_zig_type.map.value.* else .i64;
                for (em.keys) |ke| {
                    const key_local = try self.lowerExpr(ke.key);
                    const default_local = try self.emitDefaultValueForType(value_type);
                    const value_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .map_get = .{
                            .dest = value_local,
                            .map = scrutinee_local,
                            .key = key_local,
                            .default = default_local,
                            .key_type = key_type,
                            .value_type = value_type,
                        },
                    });
                    try self.known_local_types.put(value_local, value_type);
                    try scrutinee_map.put(ke.scrutinee_id, value_local);
                }
                try self.lowerDecisionTreeForDispatch(em.success, clauses, scrutinee_map);
            },
        }
    }

    /// Resolve a scrutinee expression from the decision tree to an IR local.
    fn resolveScrutinee(self: *IrBuilder, expr: *const hir_mod.Expr, scrutinee_map: *std.AutoHashMap(u32, LocalId)) LocalId {
        _ = self;
        if (expr.kind == .param_get) {
            if (scrutinee_map.get(expr.kind.param_get)) |local| {
                return local;
            }
        }
        return 0;
    }

    /// Lower a guard expression from the decision tree, resolving param_get
    /// indices through the scrutinee map. In the decision tree, param_get
    /// indices are scrutinee IDs (not raw parameter indices), so they must be
    /// resolved to the IR locals that hold the corresponding values.
    fn lowerGuardExpr(self: *IrBuilder, expr: *const hir_mod.Expr, scrutinee_map: *std.AutoHashMap(u32, LocalId)) !LocalId {
        switch (expr.kind) {
            .param_get => |idx| {
                // Resolve through scrutinee map first (scrutinee IDs from decision tree)
                if (scrutinee_map.get(idx)) |local| {
                    const dest = self.next_local;
                    self.next_local += 1;
                    try self.emitLocalGet(dest, local);
                    return dest;
                }
                // Fall back to raw param_get for actual parameter references
                const dest = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = dest, .index = idx },
                });
                return dest;
            },
            .binary => |bin| {
                const lhs = try self.lowerGuardExpr(bin.lhs, scrutinee_map);
                const rhs = try self.lowerGuardExpr(bin.rhs, scrutinee_map);
                const dest = self.next_local;
                self.next_local += 1;
                const ir_op: BinaryOp.Op = switch (bin.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .rem_op => .rem_op,
                    .equal => .eq,
                    .not_equal => .neq,
                    .less => .lt,
                    .greater => .gt,
                    .less_equal => .lte,
                    .greater_equal => .gte,
                    .and_op => .bool_and,
                    .or_op => .bool_or,
                    .concat => .concat,
                    .in_op => blk: {
                        if (bin.rhs.kind == .struct_init) {
                            if (self.type_store) |ts| {
                                if (bin.rhs.type_id < ts.types.items.len) {
                                    const rhs_type = ts.getType(bin.rhs.type_id);
                                    if (rhs_type == .struct_type) {
                                        if (self.isNativeRangeStruct(rhs_type.struct_type.name)) break :blk .in_range;
                                    }
                                }
                            }
                        }
                        break :blk .in_list;
                    },
                };
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = dest, .op = ir_op, .lhs = lhs, .rhs = rhs },
                });
                return dest;
            },
            .call => {
                // In guard context, fall through to the generic lowerExpr which
                // handles all call targets correctly. The guard-specific handling
                // only needs to be in lowerGuardExpr for param_get (scrutinee
                // resolution) and binary ops (guard-specific comparison lowering).
                return self.lowerExpr(expr);
            },
            else => {
                // For other expression kinds, fall through to generic lowerExpr
                return self.lowerExpr(expr);
            },
        }
    }

    /// Check if a scrutinee has a known type that allows skipping runtime type checks (Phase 3).
    fn shouldSkipTypeCheck(self: *IrBuilder, scrutinee: LocalId, lit: hir_mod.LiteralValue) bool {
        const known_type = self.known_local_types.get(scrutinee) orelse return false;
        return switch (lit) {
            .int => switch (known_type) {
                .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .isize, .usize => true,
                else => false,
            },
            .float => switch (known_type) {
                .f16, .f32, .f64, .f80, .f128 => true,
                else => false,
            },
            .atom => known_type == .atom,
            .string => known_type == .string,
            .bool_val => known_type == .bool_type,
            .nil => known_type == .nil,
        };
    }

    /// Emit a sub-pattern check with optional skip_type_check flag (Phase 3).
    fn emitSubPatternCheckWithSkip(self: *IrBuilder, elem_local: LocalId, lit: hir_mod.LiteralValue, skip: bool) !LocalId {
        if (!skip) return self.emitSubPatternCheck(elem_local, lit);
        return switch (lit) {
            .atom => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_atom = .{ .dest = match_local, .scrutinee = elem_local, .atom_name = self.interner.get(v), .skip_type_check = true },
                });
                return match_local;
            },
            .int => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_int = .{ .dest = match_local, .scrutinee = elem_local, .value = v, .skip_type_check = true },
                });
                return match_local;
            },
            .float => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_float = .{ .dest = match_local, .scrutinee = elem_local, .value = v, .skip_type_check = true },
                });
                return match_local;
            },
            .string => |v| {
                const match_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .match_string = .{ .dest = match_local, .scrutinee = elem_local, .expected = self.interner.get(v), .skip_type_check = true },
                });
                return match_local;
            },
            else => self.emitSubPatternCheck(elem_local, lit),
        };
    }

    fn lowerBlock(self: *IrBuilder, block: *const hir_mod.Block) anyerror!?LocalId {
        var last_local: ?LocalId = null;
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| last_local = try self.lowerExpr(expr),
                .local_set => |ls| {
                    const val = try self.lowerExpr(ls.value);
                    // Skip redundant self-assignment (e.g., struct init already in the right local)
                    if (val != ls.index) {
                        try self.current_instrs.append(self.allocator, .{
                            .local_set = .{ .dest = ls.index, .value = val },
                        });
                    }
                    // Propagate type from value to assignment target
                    if (self.known_local_types.get(val)) |src_type| {
                        try self.known_local_types.put(ls.index, src_type);
                    }
                    // Propagate HIR type as well so subsequent `.local_get`
                    // sites reading `ls.index` know whether the value is
                    // ARC-managed and need a retain on alias.
                    if (self.local_hir_types.get(val)) |src_hir_type| {
                        try self.local_hir_types.put(ls.index, src_hir_type);
                    }
                    last_local = ls.index;
                },
                .function_group => |group| {
                    const saved_instrs = self.current_instrs;
                    const saved_next_local = self.next_local;
                    const saved_known_local_types = self.known_local_types;
                    const saved_local_hir_types = self.local_hir_types;
                    self.current_instrs = .empty;
                    self.known_local_types = std.AutoHashMap(LocalId, ZigType).init(self.allocator);
                    self.local_hir_types = std.AutoHashMap(LocalId, hir_mod.TypeId).init(self.allocator);
                    defer {
                        self.known_local_types.deinit();
                        self.known_local_types = saved_known_local_types;
                        self.local_hir_types.deinit();
                        self.local_hir_types = saved_local_hir_types;
                    }
                    try self.buildFunctionGroup(group);
                    self.current_instrs = saved_instrs;
                    self.next_local = saved_next_local;
                },
            }
        }
        return last_local;
    }

    /// Phase H.1: kind of HIR-type relationship between a list local
    /// and a child binding produced by pattern destructuring or
    /// decision-tree extraction. Used by `recordListChildHirType` to
    /// pick the correct extraction (`.element` -> the list's element
    /// type; `.list` -> the same list type as the source).
    const ListChildKind = enum { element, list };

    /// Look up the HIR type recorded for `list_local` and propagate
    /// the appropriate child type onto `child_local`. For `.element`,
    /// the child receives the list's element TypeId; for `.list`, the
    /// child receives the same list TypeId (e.g. tail bindings whose
    /// type matches the source list).
    ///
    /// Phase H.1: this is the load-bearing fix that lets list-child
    /// bindings (head extraction, tail extraction) participate in the
    /// same ARC-managed classification as their source. Without it,
    /// the binding's `local_hir_types` entry stays unset (or stale
    /// from a prior reuse of the local id), and any downstream
    /// `share_value`/`release` chain whose source flows from this
    /// binding fires on a local whose ownership class is `.trivial`
    /// — tripping the verifier's V2 invariant the moment `.list`
    /// joins the ARC-managed type set.
    ///
    /// Silent no-op when the source's HIR type is unknown or not a
    /// list — the conservative fallback preserves existing behavior
    /// for non-list scrutinees and makes the helper safe to call from
    /// every list-extraction site.
    fn recordListChildHirType(
        self: *IrBuilder,
        list_local: LocalId,
        child_local: LocalId,
        kind: ListChildKind,
    ) !void {
        const list_hir = self.local_hir_types.get(list_local) orelse return;
        const store = self.type_store orelse return;
        if (list_hir >= store.types.items.len) return;
        const list_type = store.getType(list_hir);
        if (list_type != .list) return;
        switch (kind) {
            .element => try self.local_hir_types.put(child_local, list_type.list.element),
            .list => try self.local_hir_types.put(child_local, list_hir),
        }
    }

    fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
        const store = self.type_store orelse return false;
        // Phase F flip: `.map` joined `.opaque_type` as ARC-managed.
        // Phase H.4 flip: `.list` joins them, completing the chain
        // started by H.1's runtime substrate (Arc-headered pool-
        // allocated cells), continued by H.2's `guard_block`
        // ownership scoping fix in `arc_liveness.zig`, and closed
        // by H.3's `next`/`getHead`/`getTail` retain symmetry in
        // `runtime.zig`. Keep `isArcManagedTypeId` and this method
        // in lockstep — both must agree on every type.
        return switch (store.getType(type_id)) {
            .opaque_type, .map, .list => true,
            else => false,
        };
    }

    /// Returns whether the value held in `local` is ARC-managed at the
    /// HIR-type level, consulting `local_hir_types`. Returns `false` if
    /// no HIR type was recorded for the local — this is a conservative
    /// default that avoids spurious retains on locals whose types we
    /// genuinely don't know.
    fn isArcManagedLocal(self: *const IrBuilder, local: LocalId) bool {
        const hir_type = self.local_hir_types.get(local) orelse return false;
        return self.isArcManagedType(hir_type);
    }

    /// Allocates a `param_conventions` slice sized to `params.len` and
    /// populates each entry from its parameter's HIR type. Phase A of
    /// the Phase 6 redux plan: ARC-managed parameter types default to
    /// `.borrowed`, every other type defaults to `.trivial`. The
    /// caller owns the returned slice via `self.allocator`.
    fn computeParamConventions(self: *IrBuilder, params: []const Param) ![]ParamConvention {
        const out = try self.allocator.alloc(ParamConvention, params.len);
        for (params, 0..) |param, i| {
            out[i] = defaultParamConvention(self.type_store, param.type_id);
        }
        return out;
    }

    /// Allocates a `local_ownership` slice sized to `local_count` and
    /// populates each entry by consulting `local_hir_types`. Phase A
    /// classifies every non-ARC local as `.trivial` and every ARC-
    /// managed local as `.owned` (a stub that Phase C's classifier
    /// refines into `.borrowed` vs `.owned` based on definition
    /// site). Locals with no recorded HIR type fall back to
    /// `.trivial` — this matches the conservative `isArcManagedLocal`
    /// default and avoids labelling unknown locals as owners.
    fn computeLocalOwnership(self: *IrBuilder, local_count: u32) ![]OwnershipClass {
        const out = try self.allocator.alloc(OwnershipClass, local_count);
        var index: u32 = 0;
        while (index < local_count) : (index += 1) {
            out[index] = if (self.isArcManagedLocal(index)) .owned else .trivial;
        }
        return out;
    }

    /// Returns the default `ResultConvention` for a function whose
    /// HIR-level return type is `return_type_id`. Mirrors
    /// `defaultResultConvention`; placed on the builder so call sites
    /// can use the same `self.type_store` context.
    fn computeResultConvention(self: *const IrBuilder, return_type_id: ?hir_mod.TypeId) ResultConvention {
        return defaultResultConvention(self.type_store, return_type_id);
    }

    /// Emits a `.local_get{dest, source}` instruction and the
    /// follow-up `.retain{value=dest}` when the source's HIR type is
    /// ARC-managed. Also propagates `known_local_types`,
    /// `local_hir_types`, and `param_backed_locals` membership from
    /// `source` to `dest` so downstream passes see the new alias as
    /// equivalent to the original local.
    ///
    /// This helper is the single source of truth for `.local_get`
    /// emission — the named-binding path in `lowerExpr.local_get` and
    /// the four pattern-binding extraction sites in case / decision-
    /// tree lowering all funnel through it. Centralising the retain
    /// emission here avoids the silent mismatch that bit Phase 6:
    /// pattern bindings used to alias an ARC cell into a fresh local
    /// without bumping the cell's refcount, so the dest's own scope-
    /// exit release decremented past the source's true ownership.
    ///
    /// Without this retain, a single ARC-managed scrutinee shared into
    /// multiple binding locals would lower to multiple `.local_get`
    /// sites all aliasing the same cell, with the per-binding scope-
    /// exit releases over-decrementing. The Phase 6.2b drop-insertion
    /// pass treats each binding as owning an independent +1, so the
    /// retain restores that invariant.
    ///
    /// Phase C of the Phase 6 redux plan: this helper is now a
    /// transitional shim. The IR builder still produces `.local_get +
    /// .retain` here so that existing IR-level tests and pre-
    /// arc_ownership consumers (CTFE attribute eval is post-
    /// arc_ownership; HIR / monomorphize / arc_liveness are pre-
    /// arc_ownership and consume `.local_get`) keep their current
    /// shape. The new `arc_ownership.classifyAndNormalize` pass walks
    /// each function's body after `arc_liveness` and replaces every
    /// `.local_get` with an explicit `.borrow_value` (no retain) or
    /// `.copy_value` (lowering emits the retain at ZIR time). When
    /// the conversion is total — i.e., no consumer below
    /// `arc_ownership` reads `.local_get` anymore — this helper can
    /// be retired and the explicit forms emitted directly.
    fn emitLocalGet(self: *IrBuilder, dest: LocalId, source: LocalId) !void {
        try self.current_instrs.append(self.allocator, .{
            .local_get = .{ .dest = dest, .source = source },
        });
        if (self.isArcManagedLocal(source)) {
            try self.current_instrs.append(self.allocator, .{
                .retain = .{ .value = dest },
            });
        }
        if (self.known_local_types.get(source)) |src_type| {
            try self.known_local_types.put(dest, src_type);
        }
        if (self.local_hir_types.get(source)) |src_hir_type| {
            try self.local_hir_types.put(dest, src_hir_type);
        }
        if (self.param_backed_locals.contains(source)) {
            try self.param_backed_locals.put(dest, {});
        }
    }

    /// Pre-scan HIR block to find error_pipe expressions with
    /// is_dispatched steps, registering their function names in try_variant_names.
    /// This runs before function bodies are built so __try variants are generated.
    fn scanForTryVariantNames(self: *IrBuilder, block: *const hir_mod.Block, struct_prefix: ?[]const u8) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.scanExprForTryVariants(expr, struct_prefix),
                .local_set => |ls| try self.scanExprForTryVariants(ls.value, struct_prefix),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanForTryVariantNames(clause.body, struct_prefix);
                    }
                },
            }
        }
    }

    fn scanExprForTryVariants(self: *IrBuilder, expr: *const hir_mod.Expr, struct_prefix: ?[]const u8) error{OutOfMemory}!void {
        switch (expr.kind) {
            .error_pipe => |ep| {
                for (ep.steps) |step| {
                    if (step.is_dispatched and step.expr.kind == .call) {
                        const call = step.expr.kind.call;
                        // +1 for the piped value which becomes the first argument
                        const call_arity = call.args.len + 1;
                        const call_name_str = switch (call.target) {
                            .named => |n| blk: {
                                if (n.struct_name) |mod| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, n.name, call_arity });
                                if (struct_prefix) |prefix| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, n.name, call_arity });
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ n.name, call_arity });
                            },
                            else => continue,
                        };
                        try self.try_variant_names.put(call_name_str, {});
                    }
                    // Recurse into step expressions
                    try self.scanExprForTryVariants(step.expr, struct_prefix);
                }
                // Recurse into handler
                try self.scanExprForTryVariants(ep.handler, struct_prefix);
            },
            .call => |c| {
                for (c.args) |arg| {
                    try self.scanExprForTryVariants(arg.expr, struct_prefix);
                }
            },
            .branch => |br| {
                try self.scanExprForTryVariants(br.condition, struct_prefix);
                try self.scanBlockForTryVariants(br.then_block, struct_prefix);
                if (br.else_block) |eb| try self.scanBlockForTryVariants(eb, struct_prefix);
            },
            .case => |ce| {
                try self.scanExprForTryVariants(ce.scrutinee, struct_prefix);
                for (ce.arms) |arm| {
                    try self.scanBlockForTryVariants(arm.body, struct_prefix);
                }
            },
            .binary => |b| {
                try self.scanExprForTryVariants(b.lhs, struct_prefix);
                try self.scanExprForTryVariants(b.rhs, struct_prefix);
            },
            .unary => |u| {
                try self.scanExprForTryVariants(u.operand, struct_prefix);
            },
            .union_init => |ui| {
                try self.scanExprForTryVariants(ui.value, struct_prefix);
            },
            .block => |blk| {
                try self.scanBlockForTryVariants(&blk, struct_prefix);
            },
            else => {},
        }
    }

    fn scanBlockForTryVariants(self: *IrBuilder, block: *const hir_mod.Block, struct_prefix: ?[]const u8) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.scanExprForTryVariants(expr, struct_prefix),
                .local_set => |ls| try self.scanExprForTryVariants(ls.value, struct_prefix),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanForTryVariantNames(clause.body, struct_prefix);
                    }
                },
            }
        }
    }

    /// Build the mangled name used by error-pipe call lowering:
    /// `Mod__name__N` when there is a struct prefix, `name__N` otherwise.
    /// Mirrors what the rest of the IR uses so that the `__try` variant
    /// resolved at the call site matches the concrete function we emit.
    fn formatErrorPipeCallName(self: *IrBuilder, call: hir_mod.CallExpr, arity: usize) anyerror![]const u8 {
        return switch (call.target) {
            .named => |n| blk: {
                if (n.struct_name) |mod| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, n.name, arity });
                if (self.current_struct_prefix) |prefix| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, n.name, arity });
                break :blk try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ n.name, arity });
            },
            else => "unknown",
        };
    }

    /// Lower a non-dispatched call step inside an error pipe (a
    /// single-clause total function). The call is emitted inline at the
    /// current `current_instrs` position. Returns the local that holds the
    /// call's result so it can be threaded into the next pipe step.
    fn lowerSingleErrorPipeCall(self: *IrBuilder, step: hir_mod.ErrorPipeStep, pipe_val: LocalId) anyerror!LocalId {
        const call = step.expr.kind.call;
        var arg_locals: std.ArrayList(LocalId) = .empty;
        try arg_locals.append(self.allocator, pipe_val);
        for (call.args) |arg| {
            try arg_locals.append(self.allocator, try self.lowerExpr(arg.expr));
        }
        const call_dest = self.next_local;
        self.next_local += 1;
        const final_args = try arg_locals.toOwnedSlice(self.allocator);
        const modes = try self.allocator.alloc(ValueMode, final_args.len);
        @memset(modes, .share);
        const ep_call_arity = final_args.len;
        const call_name_str = try self.formatErrorPipeCallName(call, ep_call_arity);
        try self.current_instrs.append(self.allocator, .{
            .call_named = .{ .dest = call_dest, .name = call_name_str, .args = final_args, .arg_modes = modes },
        });
        return call_dest;
    }

    /// Lower a single dispatched error-pipe step that may fail. The rest
    /// of the pipe (`remaining`) is lowered into the step's success
    /// branch so that a dispatch failure jumps directly to the handler
    /// without running the trailing steps. Returns the local that the ZIR
    /// backend will populate with the catch-basin expression value.
    fn lowerErrorPipeTryStep(
        self: *IrBuilder,
        step: hir_mod.ErrorPipeStep,
        pipe_val: LocalId,
        remaining: []const hir_mod.ErrorPipeStep,
        err_local: ?u32,
        handler_hir: *const hir_mod.Expr,
    ) anyerror!LocalId {
        const call = step.expr.kind.call;
        var arg_locals: std.ArrayList(LocalId) = .empty;
        try arg_locals.append(self.allocator, pipe_val);
        for (call.args) |arg| {
            try arg_locals.append(self.allocator, try self.lowerExpr(arg.expr));
        }
        const call_dest = self.next_local;
        self.next_local += 1;
        const final_args = try arg_locals.toOwnedSlice(self.allocator);
        const modes = try self.allocator.alloc(ValueMode, final_args.len);
        @memset(modes, .share);
        const ep_call_arity = final_args.len;
        const call_name_str = try self.formatErrorPipeCallName(call, ep_call_arity);

        const try_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{call_name_str});
        try self.try_variant_names.put(call_name_str, {});

        // Lower the handler in a fresh instruction buffer. The handler
        // reads the failed pipe value via `__err` (block-style handlers)
        // or as a function argument (`err_local == 0`).
        const saved = self.current_instrs;
        self.current_instrs = .empty;
        if (err_local) |el| {
            if (self.next_local <= el) self.next_local = el + 1;
            try self.current_instrs.append(self.allocator, .{
                .local_set = .{ .dest = el, .value = pipe_val },
            });
        }
        const handler_result = try self.lowerExpr(handler_hir);
        const handler_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
        self.current_instrs = saved;

        // Allocate a local to hold the unwrapped payload, so the success
        // branch can refer to it as the input of subsequent steps.
        const payload_local = self.next_local;
        self.next_local += 1;

        // Build the success branch: emit any remaining steps with
        // `payload_local` as the new pipe value, recursing into another
        // try_call_named for the next dispatched step.
        const success_saved = self.current_instrs;
        self.current_instrs = .empty;
        var success_pipe_val: LocalId = payload_local;
        var rem_idx: usize = 0;
        while (rem_idx < remaining.len) : (rem_idx += 1) {
            const next_step = remaining[rem_idx];
            if (next_step.expr.kind != .call) continue;
            if (!next_step.is_dispatched) {
                const lowered = try self.lowerSingleErrorPipeCall(next_step, success_pipe_val);
                success_pipe_val = lowered;
                continue;
            }
            const inner = try self.lowerErrorPipeTryStep(
                next_step,
                success_pipe_val,
                remaining[rem_idx + 1 ..],
                err_local,
                handler_hir,
            );
            success_pipe_val = inner;
            // After a nested try_call_named, the rest of the pipe has
            // already been folded into its success branch.
            break;
        }
        const success_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
        self.current_instrs = success_saved;

        try self.current_instrs.append(self.allocator, .{
            .try_call_named = .{
                .dest = call_dest,
                .name = try_name,
                .args = final_args,
                .arg_modes = modes,
                .input_local = pipe_val,
                .handler_instrs = handler_instrs,
                .handler_result = handler_result,
                .success_instrs = success_instrs,
                .success_result = success_pipe_val,
                .payload_local = payload_local,
            },
        });
        return call_dest;
    }

    fn lowerExpr(self: *IrBuilder, expr: *const hir_mod.Expr) anyerror!LocalId {
        // Case expressions need binding locals reserved before dest allocation
        // to avoid shadowing conflicts in the generated Zig.
        if (expr.kind == .case) {
            return self.lowerCaseExpr(expr.kind.case);
        }

        const dest = self.next_local;
        self.next_local += 1;

        // Record the HIR-level type of this expression's dest local. The
        // `emitLocalGet` helper consults `local_hir_types[source]` to
        // decide whether a follow-up `.retain` is required, so this
        // population is what lets pattern-binding extraction sites see
        // the scrutinee local's ARC-managed type even though they only
        // have the scrutinee local id, not its HIR expression node. The
        // `expr.type_id` may be `UNKNOWN` for some lowered shapes; that
        // is acceptable because `isArcManagedType(UNKNOWN)` returns
        // false and conservative non-retain is correct for unknown
        // types (they cannot be ARC-managed as far as the IR knows).
        try self.local_hir_types.put(dest, expr.type_id);

        switch (expr.kind) {
            .int_lit => |v| {
                const int_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                const resolved = if (int_type == .any) .i64 else int_type;
                const hint: ?ZigType = if (resolved != .i64) resolved else null;
                try self.current_instrs.append(self.allocator, .{
                    .const_int = .{ .dest = dest, .value = v, .type_hint = hint },
                });
                try self.known_local_types.put(dest, resolved);
            },
            .float_lit => |v| {
                const float_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                const resolved = if (float_type == .any) .f64 else float_type;
                const hint: ?ZigType = if (resolved != .f64) resolved else null;
                try self.current_instrs.append(self.allocator, .{
                    .const_float = .{ .dest = dest, .value = v, .type_hint = hint },
                });
                try self.known_local_types.put(dest, resolved);
            },
            .string_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_string = .{ .dest = dest, .value = self.interner.get(v) },
                });
                try self.known_local_types.put(dest, .string);
            },
            .atom_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_atom = .{ .dest = dest, .value = self.interner.get(v) },
                });
                try self.known_local_types.put(dest, .atom);
            },
            .bool_lit => |v| {
                try self.current_instrs.append(self.allocator, .{
                    .const_bool = .{ .dest = dest, .value = v },
                });
                try self.known_local_types.put(dest, .bool_type);
            },
            .nil_lit => {
                try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
                try self.known_local_types.put(dest, .nil);
            },
            .local_get => |idx| {
                // Funnel through the unified helper so the named-binding
                // alias gets the same retain treatment as the four
                // pattern-binding extraction sites in case / decision-
                // tree lowering. The helper consults `local_hir_types`
                // so that even when the named binding's HIR type was
                // not flagged on `expr.type_id` (e.g. a stale
                // pre-monomorphization id), the source local's tracked
                // HIR type still drives the correct retain decision.
                try self.emitLocalGet(dest, idx);
            },
            .param_get => |idx| {
                try self.current_instrs.append(self.allocator, .{
                    .param_get = .{ .dest = dest, .index = idx },
                });
                // Phase 3: track known type from HIR expr type_id
                var param_zig_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                // Always prefer the declared param type from the function signature.
                // The expression's type_id may be stale (from before monomorphization)
                // or incorrectly concretized. The function's declared param types are
                // the authoritative source of truth after monomorphization.
                if (idx < self.current_param_types.items.len) {
                    param_zig_type = self.current_param_types.items[idx];
                }
                if (param_zig_type != .any) {
                    try self.known_local_types.put(dest, param_zig_type);
                }
                // Phase E.5 Gap 2: override the universal
                // `local_hir_types[dest] = expr.type_id` (set above at
                // expression entry) with the function signature's
                // declared parameter HIR type when available. The HIR
                // expression's `type_id` may be `UNKNOWN` (or stale
                // from before monomorphization) for some param_get
                // sites; the function's declared param HIR type is the
                // authoritative source. Without this override
                // `isArcManagedLocal(dest)` returns false on the param-
                // bound local in single-clause functions, so
                // `local_ownership[dest] = .trivial` and downstream
                // arc_liveness/verifier never treat the param read as
                // ARC-managed.
                if (idx < self.current_param_hir_types.items.len) {
                    const declared_hir_type = self.current_param_hir_types.items[idx];
                    try self.local_hir_types.put(dest, declared_hir_type);
                }
                // Mark this local as param-backed so call-name encoding
                // can detect bridge calls that thread function parameters
                // straight into a `:zig.<Container>.<method>` site.
                try self.param_backed_locals.put(dest, {});
            },
            .binary => |bin| {
                const lhs = try self.lowerExpr(bin.lhs);
                const rhs = try self.lowerExpr(bin.rhs);
                // Detect string comparison — Zig needs std.mem.eql, not ==
                const lhs_is_string = if (self.known_local_types.get(lhs)) |t| t == .string else (bin.lhs.type_id == types_mod.TypeStore.STRING);
                const rhs_is_string = if (self.known_local_types.get(rhs)) |t| t == .string else (bin.rhs.type_id == types_mod.TypeStore.STRING);
                const is_string_cmp = lhs_is_string or rhs_is_string;

                const ir_op: BinaryOp.Op = switch (bin.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .rem_op => .rem_op,
                    .equal => if (is_string_cmp) .string_eq else .eq,
                    .not_equal => if (is_string_cmp) .string_neq else .neq,
                    .less => .lt,
                    .greater => .gt,
                    .less_equal => .lte,
                    .greater_equal => .gte,
                    .and_op => .bool_and,
                    .or_op => .bool_or,
                    .concat => .concat,
                    .in_op => blk: {
                        // Detect if RHS is the native Range struct
                        if (bin.rhs.kind == .struct_init) {
                            if (self.type_store) |ts| {
                                if (bin.rhs.type_id < ts.types.items.len) {
                                    const rhs_type = ts.getType(bin.rhs.type_id);
                                    if (rhs_type == .struct_type) {
                                        if (self.isNativeRangeStruct(rhs_type.struct_type.name)) break :blk .in_range;
                                    }
                                }
                            }
                        }
                        break :blk .in_list;
                    },
                };
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = dest, .op = ir_op, .lhs = lhs, .rhs = rhs },
                });
            },
            .unary => |un| {
                const operand = try self.lowerExpr(un.operand);
                const ir_op: UnaryOp.Op = switch (un.op) {
                    .negate => .negate,
                    .not_op => .bool_not,
                };
                try self.current_instrs.append(self.allocator, .{
                    .unary_op = .{ .dest = dest, .op = ir_op, .operand = operand },
                });
            },
            .call => |call| {
                var args: std.ArrayList(LocalId) = .empty;
                var arg_modes: std.ArrayList(ValueMode) = .empty;
                var shared_release_locals: std.ArrayList(LocalId) = .empty;
                for (call.args, 0..) |arg, arg_index| {
                    const arg_local = blk: {
                        const saved_expected_type = self.current_expected_type;
                        const target_expected_type = self.callTargetExpectedType(call.target, call.args.len, arg_index) orelse arg.expected_type;
                        self.current_expected_type = if (target_expected_type != types_mod.TypeStore.UNKNOWN and
                            target_expected_type != types_mod.TypeStore.ERROR)
                            target_expected_type
                        else
                            null;
                        defer self.current_expected_type = saved_expected_type;
                        break :blk try self.lowerExpr(arg.expr);
                    };
                    const lowered_arg = switch (arg.mode) {
                        .move => blk: {
                            const moved_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{ .move_value = .{ .dest = moved_local, .source = arg_local } });
                            if (self.known_local_types.get(arg_local)) |src_type| {
                                try self.known_local_types.put(moved_local, src_type);
                            }
                            break :blk moved_local;
                        },
                        .share => blk: {
                            if (self.isArcManagedType(arg.expr.type_id)) {
                                const shared_local = self.next_local;
                                self.next_local += 1;
                                try self.current_instrs.append(self.allocator, .{ .share_value = .{ .dest = shared_local, .source = arg_local } });
                                if (self.known_local_types.get(arg_local)) |src_type| {
                                    try self.known_local_types.put(shared_local, src_type);
                                }
                                // Phase E.5 Gap 1: propagate the source's
                                // HIR type onto `shared_local` so the
                                // verifier's V2 invariant (release target
                                // must match the local's HIR-derived
                                // ownership class) sees the shared local
                                // as ARC-managed. Without this propagation
                                // a downstream `.release{value=shared_local}`
                                // looks like it targets a `.trivial` local
                                // (the default for unknown HIR types) and
                                // the verifier raises a spurious mismatch.
                                //
                                // Phase H.1: prefer `arg.expr.type_id` when
                                // it is ARC-managed and the source local's
                                // tracked HIR type is `UNKNOWN` or non-ARC.
                                // The for-comprehension desugaring produces
                                // call results whose `local_hir_types` entry
                                // ends up tagged with the synthetic
                                // `UNKNOWN` type, but the type checker has
                                // resolved the call's `expr.type_id` to the
                                // correct list type. Using the type-checked
                                // expression type at the share site keeps
                                // the shared-local's ownership class in
                                // sync with the runtime ABI: we already
                                // know `arg.expr.type_id` is ARC-managed
                                // (the surrounding `if` predicate gates
                                // the branch on exactly that).
                                const tracked_hir = self.local_hir_types.get(arg_local);
                                const shared_hir_type: hir_mod.TypeId = if (tracked_hir) |tid|
                                    (if (self.isArcManagedType(tid)) tid else arg.expr.type_id)
                                else
                                    arg.expr.type_id;
                                try self.local_hir_types.put(shared_local, shared_hir_type);
                                // Propagate param-backed marker so dispatch
                                // encoders that fall back to runtime type-
                                // derived helpers for `param: anytype`
                                // bridge calls still see the share'd local
                                // as param-backed. Otherwise the encoder
                                // would burn the post-monomorph nominal
                                // type into the call name, but the runtime
                                // value may carry a different instantiation
                                // (e.g. Map(K, Term)) and trip a type
                                // mismatch in the generated Zig.
                                if (self.param_backed_locals.contains(arg_local)) {
                                    try self.param_backed_locals.put(shared_local, {});
                                }
                                try shared_release_locals.append(self.allocator, shared_local);
                                break :blk shared_local;
                            }
                            break :blk arg_local;
                        },
                        .borrow => arg_local,
                    };
                    try args.append(self.allocator, lowered_arg);
                    try arg_modes.append(self.allocator, arg.mode);
                }

                // Implicit numeric widening: insert int_widen/float_widen
                // when an arg's type is narrower than the expected param type.
                if (self.type_store) |ts| {
                    for (call.args, 0..) |arg, i| {
                        if (i >= args.items.len) break;
                        const expected = arg.expected_type;
                        if (expected == types_mod.TypeStore.UNKNOWN) continue;
                        const actual = arg.expr.type_id;
                        if (actual == types_mod.TypeStore.UNKNOWN) continue;
                        if (ts.canWidenTo(actual, expected)) {
                            const widened_local = self.next_local;
                            self.next_local += 1;
                            const dest_zig_type = typeIdToZigTypeWithStore(expected, self.type_store);
                            const actual_type = ts.getType(actual);
                            if (actual_type == .int) {
                                try self.current_instrs.append(self.allocator, .{
                                    .int_widen = .{ .dest = widened_local, .source = args.items[i], .dest_type = dest_zig_type },
                                });
                            } else if (actual_type == .float) {
                                try self.current_instrs.append(self.allocator, .{
                                    .float_widen = .{ .dest = widened_local, .source = args.items[i], .dest_type = dest_zig_type },
                                });
                            } else {
                                continue;
                            }
                            args.items[i] = widened_local;
                        }
                    }
                }

                switch (call.target) {
                    .direct => |dc| {
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        try self.current_instrs.append(self.allocator, .{
                            .call_direct = .{ .dest = dest, .function = dc.function_group_id, .clause_index = dc.clause_index, .args = lowered_args, .arg_modes = lowered_modes },
                        });
                    },
                    .named => |nc| {
                        const call_arity = call.args.len;
                        // For struct-qualified calls, try exact arity first, then higher
                        // arities for functions with default parameters. The function
                        // name is mangled so operator-named functions match the
                        // declarations registered in known_function_names.
                        const resolved_name = if (nc.struct_name) |mod| blk: {
                            const mangled_call_name = try mangleSymbolForZig(self.allocator, nc.name);
                            if (self.selectTypeOnlyNamedClause(mod, nc.name, call_arity, call.args, nc.clause_index)) |selected_clause| {
                                const candidate = try std.fmt.allocPrint(
                                    self.allocator,
                                    "{s}__{s}__{d}__clause_{d}",
                                    .{ mod, mangled_call_name, selected_clause.declared_arity, selected_clause.clause_index },
                                );
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            if (nc.clause_index) |clause_index| {
                                const candidate = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}__clause_{d}", .{ mod, mangled_call_name, call_arity, clause_index });
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            var try_a: usize = call_arity;
                            while (try_a <= call_arity + 4) : (try_a += 1) {
                                const candidate = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, mangled_call_name, try_a });
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, mangled_call_name, call_arity });
                        } else try self.resolveBareCall(nc.name, @intCast(call_arity));

                        // Default params handled at ZIR call site (see zir_builder.zig call_named handler)

                        // Check if this function uses union dispatch — wrap args if needed
                        if (self.union_dispatch_map.get(resolved_name)) |info| {
                            var wrapped_args = try args.toOwnedSlice(self.allocator);
                            if (info.param_idx < wrapped_args.len) {
                                const arg_local = wrapped_args[info.param_idx];
                                // Determine the variant name from the argument's known type
                                const variant_name = blk: {
                                    if (self.known_local_types.get(arg_local)) |local_type| {
                                        if (local_type == .struct_ref) {
                                            if (info.variants.contains(local_type.struct_ref)) {
                                                break :blk local_type.struct_ref;
                                            }
                                        }
                                    }
                                    // Also check via HIR expr type_id
                                    if (info.param_idx < call.args.len) {
                                        const arg_type = typeIdToZigTypeWithStore(call.args[info.param_idx].expr.type_id, self.type_store);
                                        if (arg_type == .struct_ref) {
                                            if (info.variants.contains(arg_type.struct_ref)) {
                                                break :blk arg_type.struct_ref;
                                            }
                                        }
                                    }
                                    break :blk @as(?[]const u8, null);
                                };
                                if (variant_name) |vn| {
                                    // Emit union_init to wrap the arg
                                    const wrapped = self.next_local;
                                    self.next_local += 1;
                                    try self.current_instrs.append(self.allocator, .{
                                        .union_init = .{
                                            .dest = wrapped,
                                            .union_type = info.union_type_name,
                                            .variant_name = vn,
                                            .value = arg_local,
                                        },
                                    });
                                    try self.known_local_types.put(wrapped, .{ .struct_ref = info.union_type_name });
                                    wrapped_args[info.param_idx] = wrapped;
                                }
                            }
                            const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                            try self.current_instrs.append(self.allocator, .{
                                .call_named = .{ .dest = dest, .name = resolved_name, .args = wrapped_args, .arg_modes = lowered_modes },
                            });
                        } else {
                            const lowered_args = try args.toOwnedSlice(self.allocator);
                            const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                            try self.current_instrs.append(self.allocator, .{
                                .call_named = .{ .dest = dest, .name = resolved_name, .args = lowered_args, .arg_modes = lowered_modes },
                            });
                        }
                    },
                    .closure => |callee| {
                        const callee_local = try self.lowerExpr(callee);
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        const return_type = self.closureReturnType(expr.type_id, callee_local);
                        try self.current_instrs.append(self.allocator, .{
                            .call_closure = .{ .dest = dest, .callee = callee_local, .args = lowered_args, .arg_modes = lowered_modes, .return_type = return_type },
                        });
                        if (return_type != .any and return_type != .void) {
                            try self.known_local_types.put(dest, return_type);
                        }
                    },
                    .dispatch => |dc| {
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        try self.current_instrs.append(self.allocator, .{
                            .call_dispatch = .{ .dest = dest, .group_id = dc.function_group_id, .args = lowered_args, .arg_modes = lowered_modes },
                        });
                    },
                    .builtin => |name| {
                        const lowered_args = try args.toOwnedSlice(self.allocator);
                        const lowered_modes = try arg_modes.toOwnedSlice(self.allocator);
                        // Rewrite List builtins based on the argument's list element type.
                        // When a generic function like List.head(list :: [a]) is monomorphized
                        // with a = String, the `:zig.List.getHead(list)` call needs to
                        // become `StringList.getHead(list)` in the ZIR.
                        // Rewrite Map.method calls to the correct variant
                        // based on the first argument's map type.
                        const map_resolved = if (std.mem.startsWith(u8, name, "Map.") and lowered_args.len > 0) blk: {
                            const first_arg_type = self.known_local_types.get(lowered_args[0]) orelse .any;
                            if (std.meta.activeTag(first_arg_type) == .map) {
                                const key_zig = first_arg_type.map.key.*;
                                const val_zig = first_arg_type.map.value.*;
                                const method = name["Map.".len..];
                                // Generic-typed maps (typevars resolve to .any) cannot
                                // be encoded to a concrete `Map:K:V.method` name.
                                if (std.meta.activeTag(key_zig) == .any or std.meta.activeTag(val_zig) == .any) {
                                    break :blk name;
                                }
                                // Bridge calls inside generic functions (where `map`
                                // is a function parameter declared as `%{K=>V}`) are
                                // emitted with `param: anytype` in the Zap-generated
                                // Zig — which means the actual runtime `Map(K, V)`
                                // type at instantiation may differ from the param's
                                // post-monomorph nominal type (the canonical case is
                                // `Map(atom, term)` flowing into a `Map(atom, string)`
                                // monomorph). Detect this by checking whether the
                                // first arg's local was loaded via a `param_get`; if
                                // so, route through the runtime type-derived helpers
                                // (`mapGet`, ...) instead of burning the wrong
                                // concrete type into the call name.
                                if (self.localBackedByParam(lowered_args[0])) {
                                    break :blk name;
                                }
                                // Map(_, Term) in concrete callers (e.g. user code
                                // `Map.X(m, ...)` where m is a local with concrete
                                // `Map(atom, term)` storage) should also route
                                // through the helpers so wrap/unwrap happen.
                                if (std.meta.activeTag(val_zig) == .term or std.meta.activeTag(key_zig) == .term) {
                                    break :blk name;
                                }
                                // For struct/enum value types, encode for generic MapOf dispatch
                                if (std.meta.activeTag(val_zig) == .struct_ref) {
                                    const is_val_enum = if (self.type_store) |ts| val_enum: {
                                        for (ts.types.items) |typ| {
                                            if (typ == .tagged_union) {
                                                if (std.mem.eql(u8, ts.interner.get(typ.tagged_union.name), val_zig.struct_ref)) break :val_enum true;
                                            }
                                        }
                                        break :val_enum false;
                                    } else false;
                                    if (is_val_enum) {
                                        // Enum values lower to u32 atom IDs — route to Map(u32, u32) via the generic prefix.
                                        break :blk try std.fmt.allocPrint(self.allocator, "Map:u32:u32.{s}", .{method});
                                    } else {
                                        const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                        break :blk try std.fmt.allocPrint(self.allocator, "Map:{s}:{s}.{s}", .{ key_name, val_zig.struct_ref, method });
                                    }
                                }
                                // For nested map/list value types, encode for generic dispatch
                                if (std.meta.activeTag(val_zig) == .map or std.meta.activeTag(val_zig) == .list) {
                                    const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                    break :blk try std.fmt.allocPrint(self.allocator, "MapNested:{s}:{s}.{s}", .{ key_name, @tagName(std.meta.activeTag(val_zig)), method });
                                }
                                const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                const val_name = zigTypeToEncodedName(val_zig);
                                break :blk try std.fmt.allocPrint(self.allocator, "Map:{s}:{s}.{s}", .{ key_name, val_name, method });
                            }
                            break :blk name;
                        } else name;

                        const resolved_name = if (std.mem.startsWith(u8, map_resolved, "List.") and lowered_args.len > 0) blk: {
                            const first_arg_type = self.known_local_types.get(lowered_args[0]) orelse .any;
                            if (std.meta.activeTag(first_arg_type) == .list) {
                                const elem_zig = first_arg_type.list.*;
                                const method = map_resolved["List.".len..];
                                // Generic-typed lists (element resolves to .any) defer
                                // encoding so the ZIR backend routes the call through
                                // the type-derived `listGetHead`/... helpers.
                                if (std.meta.activeTag(elem_zig) == .any) {
                                    break :blk map_resolved;
                                }
                                // Same anytype-param caveat as Map: bridge calls
                                // inside generic functions take `list: anytype`
                                // and the runtime element type may diverge from
                                // the post-monomorph nominal type. Defer to the
                                // type-derived helpers in those cases.
                                if (self.localBackedByParam(lowered_args[0])) {
                                    break :blk map_resolved;
                                }
                                if (std.meta.activeTag(elem_zig) == .term) {
                                    break :blk map_resolved;
                                }
                                // For struct element types, encode for generic dispatch.
                                // Enums (tagged_union mapped to struct_ref) use u32 atom IDs
                                // and go through the default named alias path.
                                if (std.meta.activeTag(elem_zig) == .struct_ref) {
                                    // Check if this is actually an enum — enums use u32 atom IDs
                                    const is_enum = if (self.type_store) |ts| blk_enum: {
                                        for (ts.types.items) |typ| {
                                            if (typ == .tagged_union) {
                                                if (std.mem.eql(u8, ts.interner.get(typ.tagged_union.name), elem_zig.struct_ref)) break :blk_enum true;
                                            }
                                        }
                                        break :blk_enum false;
                                    } else false;
                                    if (is_enum) {
                                        // Enum lists lower to u32 atom IDs — route to List(u32) via the generic prefix.
                                        break :blk try std.fmt.allocPrint(self.allocator, "List:u32.{s}", .{method});
                                    } else {
                                        break :blk try std.fmt.allocPrint(self.allocator, "List:{s}.{s}", .{ elem_zig.struct_ref, method });
                                    }
                                }
                                if (std.meta.activeTag(elem_zig) == .list) {
                                    // Nested list: ListOf(?*const ListOf(T))
                                    // Use "ListNested:inner_type.method" encoding
                                    break :blk try std.fmt.allocPrint(self.allocator, "ListNested:{s}.{s}", .{ @tagName(elem_zig.list.*), method });
                                }
                                const elem_name = zigTypeToEncodedName(elem_zig);
                                break :blk try std.fmt.allocPrint(self.allocator, "List:{s}.{s}", .{ elem_name, method });
                            }
                            break :blk map_resolved;
                        } else map_resolved;
                        try self.current_instrs.append(self.allocator, .{
                            .call_builtin = .{ .dest = dest, .name = resolved_name, .args = lowered_args, .arg_modes = lowered_modes },
                        });
                    },
                }
                // Track the call result's type from the HIR expression
                const call_result_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                if (call_result_type != .any and call_result_type != .void) {
                    try self.known_local_types.put(dest, call_result_type);
                }
                for (shared_release_locals.items) |shared_local| {
                    try self.current_instrs.append(self.allocator, .{ .release = .{ .value = shared_local } });
                }
            },
            .branch => {
                // branch should be desugared to case before reaching IR
                unreachable;
            },
            .tuple_init => |elems| {
                var locals: std.ArrayList(LocalId) = .empty;
                var elem_zig_types: std.ArrayList(ZigType) = .empty;
                for (elems) |elem| {
                    const local = try self.lowerExpr(elem);
                    try locals.append(self.allocator, local);
                    try elem_zig_types.append(self.allocator, self.known_local_types.get(local) orelse .any);
                }
                const elements = try locals.toOwnedSlice(self.allocator);

                // Resolve the static tuple type for this expression (when
                // the type system inferred one). When the parent context
                // promoted some component to `Term` (heterogeneous unify),
                // the HIR-side type id reflects that — preferring it over
                // the per-element known_local_types means we can tell the
                // backend to wrap concrete values via `Term.from`.
                const inferred_tuple_type: ZigType = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                const component_types: ?[]const ZigType = blk: {
                    if (inferred_tuple_type == .tuple and inferred_tuple_type.tuple.len == elems.len) {
                        // Copy the inferred component types so this slice is
                        // owned by the IR (the type-store-derived slice is
                        // owned elsewhere and may be aliased).
                        var copy: std.ArrayList(ZigType) = .empty;
                        for (inferred_tuple_type.tuple) |comp| {
                            try copy.append(self.allocator, comp);
                        }
                        break :blk try copy.toOwnedSlice(self.allocator);
                    }
                    break :blk null;
                };

                try self.current_instrs.append(self.allocator, .{
                    .tuple_init = .{ .dest = dest, .elements = elements, .component_types = component_types },
                });
                try self.known_local_types.put(dest, .{
                    .tuple = try elem_zig_types.toOwnedSlice(self.allocator),
                });
            },
            .list_init => |elems| {
                var locals: std.ArrayList(LocalId) = .empty;
                for (elems) |elem| {
                    try locals.append(self.allocator, try self.lowerExpr(elem));
                }
                const elements = try locals.toOwnedSlice(self.allocator);
                const fallback_elem_type: ZigType = blk: {
                    if (elements.len > 0) {
                        break :blk self.listElementTypeFromLocal(elements[0]) orelse .i64;
                    }
                    break :blk ZigType.i64;
                };
                const elem_type = self.chooseListElementType(expr.type_id, fallback_elem_type);
                try self.current_instrs.append(self.allocator, .{
                    .list_init = .{ .dest = dest, .elements = elements, .element_type = elem_type },
                });
                const list_zig_type = try self.listTypeFromHirOrElement(expr.type_id, elem_type);
                try self.known_local_types.put(dest, list_zig_type);
            },
            .list_cons => |lc| {
                const head = try self.lowerExpr(lc.head);
                const tail = try self.lowerExpr(lc.tail);
                const fallback_elem_type = self.listElementTypeFromTailLocal(tail) orelse
                    self.listElementTypeFromLocal(head) orelse
                    ZigType.i64;
                const elem_type = self.chooseListElementType(expr.type_id, fallback_elem_type);
                try self.current_instrs.append(self.allocator, .{
                    .list_cons = .{ .dest = dest, .head = head, .tail = tail, .element_type = elem_type },
                });
                const list_zig_type = try self.listTypeFromHirOrElement(expr.type_id, elem_type);
                try self.known_local_types.put(dest, list_zig_type);
            },
            .panic => |msg| {
                const msg_local = try self.lowerExpr(msg);
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "panic", .message_local = msg_local },
                });
            },
            .never => {
                try self.current_instrs.append(self.allocator, .{
                    .match_fail = .{ .message = "unreachable" },
                });
            },
            .unwrap => |inner| {
                const source = try self.lowerExpr(inner);
                try self.current_instrs.append(self.allocator, .{
                    .optional_unwrap = .{ .dest = dest, .source = source },
                });
                // The unwrapped type is the inner type of the optional
                if (self.known_local_types.get(source)) |source_type| {
                    switch (source_type) {
                        .optional => |inner_type| try self.known_local_types.put(dest, inner_type.*),
                        else => try self.known_local_types.put(dest, source_type),
                    }
                }
            },
            .case => |case_data| {
                // Case expressions are handled specially — see lowerExpr early return
                // (this branch should not be reached because of the early return above)
                try self.lowerCaseExprBody(dest, try self.lowerExpr(case_data.scrutinee), case_data);
            },
            .block => |blk| {
                // Lower each statement in the block; result is the last expression value
                var last_local: ?LocalId = null;
                for (blk.stmts) |stmt| {
                    switch (stmt) {
                        .expr => |e| {
                            last_local = try self.lowerExpr(e);
                        },
                        .local_set => |ls| {
                            const val = try self.lowerExpr(ls.value);
                            try self.current_instrs.append(self.allocator, .{
                                .local_set = .{ .dest = ls.index, .value = val },
                            });
                            // Propagate the source local's type so a
                            // downstream `field_get` on this binding can
                            // still resolve its struct nominal type and
                            // run indirect-storage auto-deref.
                            if (self.known_local_types.get(val)) |t| {
                                try self.known_local_types.put(ls.index, t);
                            }
                        },
                        .function_group => |group| {
                            // Anonymous functions and nested functions defined
                            // inside block expressions must be built as IR functions.
                            const saved_instrs = self.current_instrs;
                            const saved_next_local = self.next_local;
                            const saved_known_local_types = self.known_local_types;
                            const saved_local_hir_types = self.local_hir_types;
                            self.current_instrs = .empty;
                            self.known_local_types = std.AutoHashMap(LocalId, ZigType).init(self.allocator);
                            self.local_hir_types = std.AutoHashMap(LocalId, hir_mod.TypeId).init(self.allocator);
                            defer {
                                self.known_local_types.deinit();
                                self.known_local_types = saved_known_local_types;
                                self.local_hir_types.deinit();
                                self.local_hir_types = saved_local_hir_types;
                            }
                            try self.buildFunctionGroup(group);
                            self.current_instrs = saved_instrs;
                            self.next_local = saved_next_local;
                        },
                    }
                }
                if (last_local) |ll| {
                    // Alias the block result to the destination
                    try self.current_instrs.append(self.allocator, .{
                        .local_set = .{ .dest = dest, .value = ll },
                    });
                } else {
                    try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
                }
            },
            .struct_init => |si| {
                // Lower struct initialization fields
                var ir_fields: std.ArrayList(StructFieldInit) = .empty;
                for (si.fields) |field| {
                    const val = try self.lowerExpr(field.value);
                    try ir_fields.append(self.allocator, .{
                        .name = self.interner.get(field.name),
                        .value = val,
                    });
                }
                // Resolve type name from type_id
                const type_name = self.resolveTypeName(si.type_id);
                try self.current_instrs.append(self.allocator, .{
                    .struct_init = .{
                        .dest = dest,
                        .type_name = type_name,
                        .fields = try ir_fields.toOwnedSlice(self.allocator),
                    },
                });
                // Track the constructed value's nominal type so a later
                // `field_get` on this local can resolve struct identity
                // for indirect-storage auto-deref.
                try self.known_local_types.put(dest, .{ .struct_ref = type_name });
            },
            .error_pipe => |ep| {
                // Lower the error pipe so that a failure in any dispatched
                // step short-circuits the rest of the pipeline. The catch-
                // basin expression value is either the value of the last step
                // (when every dispatched step matched) or the value of the
                // handler (when one of them did not).
                //
                // To express the short-circuit without emitting a `ret`
                // (which would hijack the enclosing function's return), every
                // dispatched step is lowered as a `try_call_named` whose
                // success branch carries the rest of the pipe inline. The
                // ZIR backend turns this into a nested if-else block whose
                // value flows through `setLocal(dest, ...)` here.
                if (ep.steps.len == 0) return dest;

                const handler_hir = ep.handler;

                // Lower the base value at the top level (no try_call wraps it).
                var pipe_val = try self.lowerExpr(ep.steps[0].expr);

                const remaining_steps = ep.steps[1..];

                // Walk the remaining steps. As soon as we hit a dispatched
                // step, the rest of the pipe must be emitted INSIDE that
                // step's success branch (so a failure jumps over them all
                // and yields the handler's value). Non-dispatched steps
                // before any dispatched step can stay at the top level.
                var idx: usize = 0;
                while (idx < remaining_steps.len) : (idx += 1) {
                    const step = remaining_steps[idx];
                    if (step.expr.kind != .call) continue;
                    if (!step.is_dispatched) {
                        // Single-clause total step: emit a regular call
                        // inline, then continue with the next step.
                        const lowered = try self.lowerSingleErrorPipeCall(step, pipe_val);
                        pipe_val = lowered;
                        continue;
                    }
                    // Dispatched step: emit a try_call_named whose success
                    // branch holds the rest of the pipe (recursively built
                    // as a nested instruction list).
                    const try_local = try self.lowerErrorPipeTryStep(
                        step,
                        pipe_val,
                        remaining_steps[idx + 1 ..],
                        ep.err_local,
                        handler_hir,
                    );
                    return try_local;
                }
                // No dispatched step appeared after the base value (or there
                // were no dispatched calls at all). The handler is dead
                // code, but we still must produce the pipe's value: it is
                // the result of the last (non-dispatched) call.
                return pipe_val;
            },
            .union_init => |ui| {
                const value_local = try self.lowerExpr(ui.value);
                const type_name = self.resolveTypeName(ui.union_type_id);
                try self.current_instrs.append(self.allocator, .{
                    .union_init = .{
                        .dest = dest,
                        .union_type = type_name,
                        .variant_name = self.interner.get(ui.variant_name),
                        .value = value_local,
                    },
                });
            },
            .field_get => |fg| {
                // Check for enum variant access (object is nil_lit placeholder with enum type)
                if (fg.object.kind == .nil_lit and self.type_store != null) {
                    const typ = self.type_store.?.getType(fg.object.type_id);
                    if (typ == .tagged_union) {
                        try self.current_instrs.append(self.allocator, .{
                            .enum_literal = .{
                                .dest = dest,
                                .type_name = self.interner.get(typ.tagged_union.name),
                                .variant = self.interner.get(fg.field),
                            },
                        });
                        return dest;
                    }
                }
                const obj = try self.lowerExpr(fg.object);
                const field_name = self.interner.get(fg.field);
                const struct_type = self.structTypeForFieldReceiver(obj);
                try self.current_instrs.append(self.allocator, .{
                    .field_get = .{
                        .dest = dest,
                        .object = obj,
                        .field = field_name,
                        .struct_type = struct_type,
                    },
                });
                if (struct_type) |sname| {
                    if (self.fieldZigTypeAndStorage(sname, field_name)) |info| {
                        try self.known_local_types.put(dest, info.type_expr);
                    }
                }
            },
            .tuple_index_get => |tig| {
                const obj = try self.lowerExpr(tig.object);
                try self.current_instrs.append(self.allocator, .{
                    .index_get = .{ .dest = dest, .object = obj, .index = tig.index },
                });
                if (self.type_store) |ts| {
                    const obj_type = ts.getType(tig.object.type_id);
                    if (obj_type == .tuple and tig.index < obj_type.tuple.elements.len) {
                        try self.known_local_types.put(dest, typeIdToZigTypeWithStore(obj_type.tuple.elements[tig.index], self.type_store));
                    }
                }
            },
            .list_index_get => |lig| {
                const list_local = try self.lowerExpr(lig.list);
                const elem_type = self.listElementTypeForLocal(list_local);
                try self.current_instrs.append(self.allocator, .{
                    .list_get = .{ .dest = dest, .list = list_local, .index = lig.index, .element_type = elem_type },
                });
                try self.known_local_types.put(dest, elem_type);
            },
            .list_head_get => |lhg| {
                const list_local = try self.lowerExpr(lhg.list);
                const elem_type = self.listElementTypeForLocal(list_local);
                try self.current_instrs.append(self.allocator, .{
                    .list_head = .{ .dest = dest, .list = list_local, .element_type = elem_type },
                });
                try self.known_local_types.put(dest, elem_type);
            },
            .list_tail_get => |ltg| {
                const list_local = try self.lowerExpr(ltg.list);
                const elem_type = self.listElementTypeForLocal(list_local);
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = dest, .list = list_local, .element_type = elem_type },
                });
                if (self.known_local_types.get(list_local)) |list_type| {
                    try self.known_local_types.put(dest, list_type);
                }
            },
            .map_value_get => |mvg| {
                const map_local = try self.lowerExpr(mvg.map);
                const key_local = try self.lowerExpr(mvg.key);
                // Pull the map's K/V from the lowered map's known
                // type so ZIR resolves the right `Map(K, V)` cell.
                // Default to atom→i64 for legacy callers.
                const map_zig_type = self.known_local_types.get(map_local) orelse ZigType.any;
                const key_type: ZigType = if (map_zig_type == .map) map_zig_type.map.key.* else .atom;
                const value_type: ZigType = if (map_zig_type == .map) map_zig_type.map.value.* else .i64;
                // Use a synthesized default matching the value type.
                // Destructure assumes the key exists, so the runtime
                // never observes this — it just has to typecheck.
                const default_local = try self.emitDefaultValueForType(value_type);
                try self.current_instrs.append(self.allocator, .{
                    .map_get = .{
                        .dest = dest,
                        .map = map_local,
                        .key = key_local,
                        .default = default_local,
                        .key_type = key_type,
                        .value_type = value_type,
                    },
                });
                try self.known_local_types.put(dest, value_type);
            },
            .map_init => |entries| {
                var ir_entries: std.ArrayList(MapEntry) = .empty;
                // Read key/value types from the unified map type computed in
                // HIR (which already collapses disagreeing scalars to TERM and
                // unifies tuple shapes component-wise). Fall back to the first
                // entry's types only when HIR couldn't fix a unified type.
                var key_type: ZigType = .atom;
                var value_type: ZigType = .i64;
                blk: {
                    if (self.type_store) |ts| {
                        if (expr.type_id < ts.types.items.len) {
                            const map_t = ts.types.items[expr.type_id];
                            if (map_t == .map) {
                                key_type = typeIdToZigTypeWithStore(map_t.map.key, self.type_store);
                                value_type = typeIdToZigTypeWithStore(map_t.map.value, self.type_store);
                                break :blk;
                            }
                        }
                    }
                    if (entries.len > 0) {
                        key_type = typeIdToZigTypeWithStore(entries[0].key.type_id, self.type_store);
                        value_type = typeIdToZigTypeWithStore(entries[0].value.type_id, self.type_store);
                    }
                }
                for (entries) |entry| {
                    const key = try self.lowerExpr(entry.key);
                    const value = try self.lowerExpr(entry.value);
                    try ir_entries.append(self.allocator, .{ .key = key, .value = value });
                }
                try self.current_instrs.append(self.allocator, .{
                    .map_init = .{
                        .dest = dest,
                        .entries = try ir_entries.toOwnedSlice(self.allocator),
                        .key_type = key_type,
                        .value_type = value_type,
                    },
                });
                // Track the map's concrete type so Map.method calls can dispatch
                const kt = try self.allocator.create(ZigType);
                kt.* = key_type;
                const vt = try self.allocator.create(ZigType);
                vt.* = value_type;
                try self.known_local_types.put(dest, .{ .map = .{ .key = kt, .value = vt } });
            },
            .capture_get => |index| {
                try self.current_instrs.append(self.allocator, .{
                    .capture_get = .{ .dest = dest, .index = index },
                });
                const capture_zig_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                if (capture_zig_type != .any) {
                    try self.known_local_types.put(dest, capture_zig_type);
                }
            },
            .closure_create => |cc| {
                var capture_locals: std.ArrayList(LocalId) = .empty;
                for (cc.captures) |capture| {
                    try capture_locals.append(self.allocator, try self.lowerExpr(capture.expr));
                }
                try self.current_instrs.append(self.allocator, .{
                    .make_closure = .{
                        .dest = dest,
                        .function = cc.function_group_id,
                        .captures = try capture_locals.toOwnedSlice(self.allocator),
                    },
                });
            },
            else => {
                // Emit a nil placeholder for unhandled expressions
                try self.current_instrs.append(self.allocator, .{ .const_nil = dest });
            },
        }

        return dest;
    }

    /// Resolve a type_id to a string name for struct/enum types.
    fn resolveTypeName(self: *IrBuilder, type_id: types_mod.TypeId) []const u8 {
        if (self.type_store) |ts| {
            const typ = ts.getType(type_id);
            switch (typ) {
                .struct_type => |st| return self.interner.get(st.name),
                .tagged_union => |tu| return self.interner.get(tu.name),
                else => {},
            }
        }
        return "UnknownType";
    }

    /// Resolve a bare function call to a qualified name with arity.
    /// Resolution order: current struct → Kernel → top-level → bare name.
    /// Also checks higher arities for functions with default parameters.
    fn resolveBareCall(self: *IrBuilder, name: []const u8, arity: u32) ![]const u8 {
        // Names containing operator characters are mangled before lookup so the
        // qualified candidates match the entries registered in
        // known_function_names (which are also mangled).
        const mangled_name = try mangleSymbolForZig(self.allocator, name);
        // Try exact arity first, then higher arities (for default params)
        var try_arity: u32 = arity;
        while (try_arity <= arity + 4) : (try_arity += 1) {
            // 1. Current struct function
            if (self.current_struct_prefix) |prefix| {
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, mangled_name, try_arity });
                if (self.known_function_names.contains(qualified)) return qualified;
            }
            // 2. Top-level function (bare name with arity)
            {
                const top_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ mangled_name, try_arity });
                if (self.known_function_names.contains(top_name)) return top_name;
            }
            // Kernel functions are resolved via auto-import in the collector —
            // they appear as regular imports in the struct scope, so steps 1-2
            // handle them. No hardcoded Kernel fallback needed.
        }
        // 4. Keep bare (unmangled) name — Zig compiler will error
        return name;
    }

    /// Convert an ast.StructName to a prefix string for function naming.
    /// Single-part: "IO". Multi-part: "IO_File".
    fn structNameToPrefix(self: *IrBuilder, name: ast.StructName) []const u8 {
        if (name.parts.len == 1) return self.interner.get(name.parts[0]);
        return name.joinedWith(self.allocator, self.interner, "_") catch self.interner.get(name.parts[0]);
    }

    fn allocSlice(self: *IrBuilder, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }
};

/// Walk a Decision tree to find the param_get index used for the N-th tuple element.
/// The decision tree's check_tuple success subtree references element scrutinee IDs
/// via param_get nodes. This scans to find the ID associated with a given element index.
/// Convert a Zap function name into a Zig-safe identifier.
///
/// Zig identifiers allow `[A-Za-z0-9_]` (plus `?`/`!` in Zap-specific
/// positions which Zig's parser tolerates in @"..." form here). Operator
/// chars (`+ - * / < > = ! | & ^ ~ % @ # $ . :`) are not Zig identifier
/// chars, so any name containing them — `+`, `==`, or composite names like
/// `Kernel_==__i64` produced by monomorphization — must be rewritten.
///
/// Strategy: per-char inline replacement. Each unsafe char becomes
/// `_<spelled-out>` (e.g., `=` → `_eq`, `+` → `_plus`). Safe chars pass
/// through verbatim. Returns the input unchanged when no mangling is needed.
pub fn mangleSymbolForZig(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return name;
    var needs_mangle = false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '?', '!' => {},
            else => {
                needs_mangle = true;
                break;
            },
        }
    }
    if (!needs_mangle) return name;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '?', '!' => try buf.append(allocator, c),
            '+' => try buf.appendSlice(allocator, "_plus"),
            '-' => try buf.appendSlice(allocator, "_minus"),
            '*' => try buf.appendSlice(allocator, "_star"),
            '/' => try buf.appendSlice(allocator, "_slash"),
            '<' => try buf.appendSlice(allocator, "_lt"),
            '>' => try buf.appendSlice(allocator, "_gt"),
            '=' => try buf.appendSlice(allocator, "_eq"),
            '|' => try buf.appendSlice(allocator, "_pipe"),
            '&' => try buf.appendSlice(allocator, "_amp"),
            '^' => try buf.appendSlice(allocator, "_caret"),
            '~' => try buf.appendSlice(allocator, "_tilde"),
            '%' => try buf.appendSlice(allocator, "_pct"),
            '@' => try buf.appendSlice(allocator, "_at"),
            '#' => try buf.appendSlice(allocator, "_hash"),
            '$' => try buf.appendSlice(allocator, "_dollar"),
            '.' => try buf.appendSlice(allocator, "_dot"),
            ':' => try buf.appendSlice(allocator, "_colon"),
            else => try buf.appendSlice(allocator, "_x"),
        }
    }
    return try buf.toOwnedSlice(allocator);
}

fn findParamGetIdInDecision(decision: *const hir_mod.Decision, target_element: u32) u32 {
    switch (decision.*) {
        .check_tuple => |ct| {
            // This is a nested tuple check. The scrutinee expr tells us the ID.
            if (ct.scrutinee.kind == .param_get) {
                return ct.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(ct.success, target_element);
        },
        .switch_literal => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                // The first switch_literal we encounter should be for element 0,
                // second for element 1, etc. But we need to trace the right one.
                // We track by counting: the decision tree puts elements in order.
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                // For other elements, look in default/cases
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .switch_tag => |sw| {
            if (sw.scrutinee.kind == .param_get) {
                if (target_element == 0) return sw.scrutinee.kind.param_get;
                if (sw.cases.len > 0) {
                    return findParamGetIdInDecision(sw.cases[0].next, target_element - 1);
                }
                return findParamGetIdInDecision(sw.default, target_element - 1);
            }
            return findParamGetIdInDecision(sw.default, target_element);
        },
        .check_list => |cl| {
            if (cl.scrutinee.kind == .param_get) {
                return cl.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(cl.success, target_element);
        },
        .check_list_cons => |clc| {
            if (clc.scrutinee.kind == .param_get) {
                return clc.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(clc.success, target_element);
        },
        .check_binary => |cb| {
            if (cb.scrutinee.kind == .param_get) {
                return cb.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(cb.success, target_element);
        },
        .extract_struct => |es| {
            if (es.scrutinee.kind == .param_get) {
                return es.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(es.success, target_element);
        },
        .extract_map => |em| {
            if (em.scrutinee.kind == .param_get) {
                return em.scrutinee.kind.param_get;
            }
            return findParamGetIdInDecision(em.success, target_element);
        },
        .guard => |g| return findParamGetIdInDecision(g.success, target_element),
        .bind => |b| {
            if (b.source.kind == .param_get) {
                if (target_element == 0) return b.source.kind.param_get;
                return findParamGetIdInDecision(b.next, target_element - 1);
            }
            return findParamGetIdInDecision(b.next, target_element);
        },
        .success => {
            // We need to derive the ID from the pattern. The compilePatternMatrix
            // allocates IDs sequentially starting from a base. The base for tuple
            // element N of scrutinee S is: the next_id at the time of tuple expansion.
            // Since we don't store that, use a heuristic: the first referenced param_get
            // ID + target_element offset.
            return target_element;
        },
        .failure => return target_element,
    }
}

/// Map a ZigType to a canonical short name for generic container encoding.
/// Used in call_builtin name encoding: "List:i64.method", "Map:u32:str.method".
fn zigTypeToEncodedName(zig_type: ZigType) []const u8 {
    return switch (std.meta.activeTag(zig_type)) {
        .i64 => "i64",
        .i128 => "i128",
        .i32 => "i32",
        .i16 => "i16",
        .i8 => "i8",
        .u64 => "u64",
        .u128 => "u128",
        .u32 => "u32",
        .u16 => "u16",
        .u8 => "u8",
        .f64 => "f64",
        .f80 => "f80",
        .f128 => "f128",
        .f32 => "f32",
        .f16 => "f16",
        .bool_type => "bool",
        .string => "str",
        .atom => "u32",
        .term => "Term",
        .struct_ref => zig_type.struct_ref,
        .tagged_union => zig_type.tagged_union,
        else => "i64",
    };
}

/// Walks every destructure-binding kind on every clause and returns one past
/// the maximum local_index used. The result is the lower bound for fresh
/// Whether a HIR `MatchPattern` is total — guaranteed to match any value of
/// its declared parameter type without runtime inspection. Bare bindings and
/// wildcards qualify; literals, tuples, lists, struct patterns, maps, pins,
/// list-cons, and binary patterns all perform some structural check and so
/// can fail to match. Used by `__try`-variant generation to decide whether a
/// single-clause function needs a dispatch wrapper for catch-basin callers.
fn isTotalMatchPattern(pattern: *const hir_mod.MatchPattern) bool {
    return switch (pattern.*) {
        .wildcard, .bind => true,
        else => false,
    };
}

/// local allocation in the function body (binding locals live above this).
/// All six binding kinds (tuple/struct/list/cons_tail/binary/map) must be
/// covered — omitting any one silently corrupts the local layout for the
/// affected pattern shape (this was the bug that broke `__try` variants on
/// map-pattern functions).
///
/// Phase E.5 Gap 3: also counts assignment-binding (`local_set.index`)
/// indices used in each clause body. HIR allocates these indices from
/// the same per-clause `next_local` counter as pattern bindings, so an
/// assignment like `name = expr` inside the body produces a
/// `local_set.index` that occupies the same numbering space as
/// pattern-binding indices. If the IR-level `next_local` is initialized
/// only from pattern bindings, IR-level expression lowering allocates
/// fresh locals starting BELOW the assignment-binding indices and
/// silently collides, causing `local_set` propagation to overwrite the
/// IR builder's `local_hir_types[ls.index]` with a stale entry.
/// Walking the body for `local_set` indices closes that collision.
fn computeMaxBindingLocalForClauses(clauses: []const hir_mod.Clause) LocalId {
    var max_local: LocalId = 0;
    for (clauses) |clause| {
        for (clause.tuple_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.struct_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.list_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.cons_tail_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.binary_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        for (clause.map_bindings) |binding| {
            max_local = @max(max_local, binding.local_index + 1);
        }
        // Walk the clause body for `local_set` indices (assignment
        // bindings allocated via HIR's per-clause `next_local`).
        const body_max = maxLocalSetIndexInBlock(clause.body);
        max_local = @max(max_local, body_max);
    }
    return max_local;
}

/// Recursively walks a HIR block, returning one past the largest
/// `local_set.index` reached anywhere inside the block (including
/// nested blocks, function-group bodies, branches, case arms, error
/// pipes, etc.). Returns `0` when the block contains no `local_set`.
fn maxLocalSetIndexInBlock(block: *const hir_mod.Block) LocalId {
    var max_local: LocalId = 0;
    for (block.stmts) |stmt| {
        switch (stmt) {
            .local_set => |ls| {
                max_local = @max(max_local, ls.index + 1);
                const value_max = maxLocalSetIndexInExpr(ls.value);
                max_local = @max(max_local, value_max);
            },
            .expr => |expr| {
                const expr_max = maxLocalSetIndexInExpr(expr);
                max_local = @max(max_local, expr_max);
            },
            .function_group => |group| {
                // Closures capture by reference; their bodies use a
                // fresh `next_local` counter, so they cannot collide
                // with the enclosing function's local space. Skip.
                _ = group;
            },
        }
    }
    return max_local;
}

/// Recursively walks a HIR expression for `local_set` indices that
/// appear inside its sub-blocks (case arms, branches, error pipes,
/// blocks-as-expressions, ...). Mirrors `maxLocalSetIndexInBlock`.
fn maxLocalSetIndexInExpr(expr: *const hir_mod.Expr) LocalId {
    var max_local: LocalId = 0;
    switch (expr.kind) {
        .branch => |*br| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(br.condition));
            max_local = @max(max_local, maxLocalSetIndexInBlock(br.then_block));
            if (br.else_block) |eb| max_local = @max(max_local, maxLocalSetIndexInBlock(eb));
        },
        .case => |*ce| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(ce.scrutinee));
            for (ce.arms) |arm| {
                max_local = @max(max_local, maxLocalSetIndexInBlock(arm.body));
                // Phase H.5: case-arm bindings allocate `local_index`
                // from the HIR builder's per-clause `next_local`
                // counter (see `collectCasePatternBindings`). The
                // IR-builder reservation in
                // `computeMaxBindingLocalForClauses` walks every
                // `tuple_bindings`/`list_bindings`/etc. on the clause
                // to keep its own `next_local` above any reserved
                // index, but it never visited the case arm's
                // `bindings` list — so a case-arm binding's
                // `local_index` could collide with a top-level
                // `local_set` (e.g. `opts = [...]` whose list_init
                // dest gets `next_local++`). The collision rebinds
                // an already-ARC-managed local mid-function, which
                // makes `local_ownership[binding] = .owned` and
                // causes the classifier to emit `copy_value` (with
                // a runtime retain) on top of a non-ARC value
                // (e.g. a String binding inside a keyword pattern).
                // Walk the arm's bindings here so the reservation is
                // sound across every case-arm pattern shape.
                for (arm.bindings) |binding| {
                    max_local = @max(max_local, binding.local_index + 1);
                }
            }
        },
        .block => |*blk| {
            max_local = @max(max_local, maxLocalSetIndexInBlock(blk));
        },
        .binary => |b| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(b.lhs));
            max_local = @max(max_local, maxLocalSetIndexInExpr(b.rhs));
        },
        .unary => |u| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(u.operand));
        },
        .call => |c| {
            for (c.args) |arg| {
                max_local = @max(max_local, maxLocalSetIndexInExpr(arg.expr));
            }
        },
        .union_init => |ui| {
            max_local = @max(max_local, maxLocalSetIndexInExpr(ui.value));
        },
        .error_pipe => |ep| {
            for (ep.steps) |step| {
                max_local = @max(max_local, maxLocalSetIndexInExpr(step.expr));
            }
            max_local = @max(max_local, maxLocalSetIndexInExpr(ep.handler));
        },
        else => {},
    }
    return max_local;
}

/// Check if a HIR function group is generic (has unresolved type variables in params/return).
fn isGenericHirGroup(store: *const types_mod.TypeStore, group: *const hir_mod.FunctionGroup) bool {
    if (group.clauses.len == 0) return false;

    // Synthesized protocol dispatch functions (scope_id = 0) are NOT generic.
    // They merge clauses from different impl blocks for type-based dispatch.
    if (group.scope_id == 0 and group.clauses.len > 1) return false;

    const first_clause = &group.clauses[0];
    for (first_clause.params) |param| {
        // UNKNOWN (any) parameters are NOT generic — they compile to anytype in Zig
        if (param.type_id == types_mod.TypeStore.UNKNOWN) continue;
        if (containsTypeVarInStore(store, param.type_id)) {
            // Check if the actual type is a type_var that was unified from UNKNOWN
            if (param.type_id < store.types.items.len) {
                const actual = store.types.items[param.type_id];
                if (actual == .unknown or actual == .type_var) continue; // Not truly generic
            }
            return true;
        }
    }
    const ret = first_clause.return_type;
    if (ret != types_mod.TypeStore.UNKNOWN and containsTypeVarInStore(store, ret)) return true;
    return false;
}

fn containsTypeVarInStore(store: *const types_mod.TypeStore, type_id: types_mod.TypeId) bool {
    if (type_id >= store.types.items.len) return false;
    const typ = store.types.items[type_id];
    return switch (typ) {
        .type_var => true,
        .list => |lt| containsTypeVarInStore(store, lt.element),
        .tuple => |tt| {
            for (tt.elements) |elem| {
                if (containsTypeVarInStore(store, elem)) return true;
            }
            return false;
        },
        .function => |ft| {
            for (ft.params) |param| {
                if (containsTypeVarInStore(store, param)) return true;
            }
            return containsTypeVarInStore(store, ft.return_type);
        },
        .map => |mt| containsTypeVarInStore(store, mt.key) or containsTypeVarInStore(store, mt.value),
        .applied => |at| {
            for (at.args) |arg| {
                if (containsTypeVarInStore(store, arg)) return true;
            }
            return false;
        },
        .protocol_constraint => |pc| {
            if (pc.type_params.len > 0) {
                for (pc.type_params) |tp| {
                    if (containsTypeVarInStore(store, tp)) return true;
                }
            }
            // Protocol constraints are compile-time dispatch constraints,
            // not runtime value types. A function that still has one after
            // monomorphization is still generic and must not be lowered.
            return true;
        },
        else => false,
    };
}

fn typeIdToZigType(type_id: types_mod.TypeId) ZigType {
    return typeIdToZigTypeWithStore(type_id, null);
}

fn typeIdToZigTypeWithStore(type_id: types_mod.TypeId, type_store: ?*const types_mod.TypeStore) ZigType {
    return switch (type_id) {
        types_mod.TypeStore.BOOL => .bool_type,
        types_mod.TypeStore.STRING => .string,
        types_mod.TypeStore.ATOM => .atom,
        types_mod.TypeStore.NIL => .nil,
        types_mod.TypeStore.NEVER => .never,
        types_mod.TypeStore.TERM => .term,
        types_mod.TypeStore.I128 => .i128,
        types_mod.TypeStore.I64 => .i64,
        types_mod.TypeStore.I32 => .i32,
        types_mod.TypeStore.I16 => .i16,
        types_mod.TypeStore.I8 => .i8,
        types_mod.TypeStore.U128 => .u128,
        types_mod.TypeStore.U64 => .u64,
        types_mod.TypeStore.U32 => .u32,
        types_mod.TypeStore.U16 => .u16,
        types_mod.TypeStore.U8 => .u8,
        types_mod.TypeStore.F128 => .f128,
        types_mod.TypeStore.F80 => .f80,
        types_mod.TypeStore.F64 => .f64,
        types_mod.TypeStore.F32 => .f32,
        types_mod.TypeStore.F16 => .f16,
        types_mod.TypeStore.USIZE => .usize,
        types_mod.TypeStore.ISIZE => .isize,
        types_mod.TypeStore.MARRAY_I64 => .marray_i64,
        types_mod.TypeStore.MARRAY_F64 => .marray_f64,
        else => {
            // Try to resolve user-defined struct/enum/union types
            if (type_store) |ts| {
                if (type_id < ts.types.items.len) {
                    const typ = ts.types.items[type_id];
                    switch (typ) {
                        .marray_type => |element_kind| return switch (element_kind) {
                            .i64 => .marray_i64,
                            .f64 => .marray_f64,
                        },
                        .struct_type => |st| {
                            return .{ .struct_ref = ts.interner.get(st.name) };
                        },
                        .tagged_union => |tu| {
                            return .{ .struct_ref = ts.interner.get(tu.name) };
                        },
                        .opaque_type => |ot| {
                            return .{ .struct_ref = ts.interner.get(ot.name) };
                        },
                        .tuple => |tt| {
                            var zig_elems = ts.allocator.alloc(ZigType, tt.elements.len) catch return .any;
                            for (tt.elements, 0..) |elem, i| {
                                zig_elems[i] = typeIdToZigTypeWithStore(elem, type_store);
                            }
                            return .{ .tuple = zig_elems };
                        },
                        .list => |lt| {
                            const elem_zig = ts.allocator.create(ZigType) catch return .any;
                            elem_zig.* = typeIdToZigTypeWithStore(lt.element, type_store);
                            return .{ .list = elem_zig };
                        },
                        .map => |mt| {
                            const key_zig = ts.allocator.create(ZigType) catch return .any;
                            key_zig.* = typeIdToZigTypeWithStore(mt.key, type_store);
                            const val_zig = ts.allocator.create(ZigType) catch return .any;
                            val_zig.* = typeIdToZigTypeWithStore(mt.value, type_store);
                            return .{ .map = .{ .key = key_zig, .value = val_zig } };
                        },
                        .function => |ft| {
                            var zig_params = ts.allocator.alloc(ZigType, ft.params.len) catch return .any;
                            for (ft.params, 0..) |param, i| {
                                zig_params[i] = typeIdToZigTypeWithStore(param, type_store);
                            }
                            const ret_ptr = ts.allocator.create(ZigType) catch return .any;
                            ret_ptr.* = typeIdToZigTypeWithStore(ft.return_type, type_store);
                            return .{ .function = .{ .params = zig_params, .return_type = ret_ptr } };
                        },
                        .union_type => |ut| {
                            // T | nil → ?T (Zig optional)
                            if (ut.members.len == 2) {
                                var non_nil: ?types_mod.TypeId = null;
                                for (ut.members) |m| {
                                    if (m == types_mod.TypeStore.NIL) continue;
                                    non_nil = m;
                                }
                                if (non_nil) |inner| {
                                    const inner_zig = typeIdToZigTypeWithStore(inner, type_store);
                                    const inner_ptr = ts.allocator.create(ZigType) catch return .any;
                                    inner_ptr.* = inner_zig;
                                    return .{ .optional = inner_ptr };
                                }
                            }
                            // General union types → anytype
                            return .any;
                        },
                        else => {},
                    }
                }
            }
            return .any;
        },
    };
}

/// Walk a ZigType and return true if it transitively references a
/// nominal struct type matching `owner_name` via direct
/// `struct_ref` traversal alone — does NOT follow into other
/// structs' fields. Used as the inner step of the SCC-aware walker
/// below, and as the storage-decision criterion when no `TypeStore`
/// is attached (raw-IR unit tests).
///
/// Self-recursion only at this layer; for mutual recursion (`A → B
/// → A`) callers should use `zigTypeReachesStructInCycle`.
/// Peel `optional`/`ptr` wrappers and return the struct name when the
/// underlying nominal type is a struct. Used by `field_get` lowering
/// to look up the receiver's struct definition for indirect-storage
/// auto-deref.
fn zigTypeStructName(t: ZigType) ?[]const u8 {
    return switch (t) {
        .struct_ref => |name| name,
        .optional => |inner| zigTypeStructName(inner.*),
        .ptr => |inner| zigTypeStructName(inner.*),
        else => null,
    };
}

fn zigTypeReachesStruct(t: ZigType, owner_name: []const u8) bool {
    return switch (t) {
        .struct_ref => |name| std.mem.eql(u8, name, owner_name),
        .optional => |inner| zigTypeReachesStruct(inner.*, owner_name),
        .ptr => |pointee| zigTypeReachesStruct(pointee.*, owner_name),
        .list => |elem| zigTypeReachesStruct(elem.*, owner_name),
        .map => |mt| zigTypeReachesStruct(mt.key.*, owner_name) or
            zigTypeReachesStruct(mt.value.*, owner_name),
        .tuple => |elems| blk: {
            for (elems) |elem| {
                if (zigTypeReachesStruct(elem, owner_name)) break :blk true;
            }
            break :blk false;
        },
        .function => |ft| blk: {
            for (ft.params) |p| {
                if (zigTypeReachesStruct(p, owner_name)) break :blk true;
            }
            break :blk zigTypeReachesStruct(ft.return_type.*, owner_name);
        },
        // Primitives and tagged_union (a name reference, not a
        // structural type) cannot transitively reach a struct.
        // tagged_union variants currently lower as u32 enum tags
        // anyway; if/when payload variants land they'd need
        // separate recursion handling.
        .void,
        .bool_type,
        .nil,
        .never,
        .term,
        .any,
        .string,
        .atom,
        .i8,
        .i16,
        .i32,
        .i64,
        .i128,
        .u8,
        .u16,
        .u32,
        .u64,
        .u128,
        .f16,
        .f32,
        .f64,
        .f80,
        .f128,
        .usize,
        .isize,
        .tagged_union,
        // MArray cells are heap-managed runtime values whose `Inner`
        // never embeds a Zap user struct, so they cannot reach
        // `owner_name`.
        .marray_i64,
        .marray_f64,
        => false,
    };
}

/// SCC-aware variant of `zigTypeReachesStruct`. Returns true iff
/// `t` transitively references a struct that is in the same
/// strongly-connected component as `owner_name` over the struct
/// dependency graph. Catches both self-recursion (`A → A`, the
/// degenerate 1-element SCC) and mutual recursion (`A → B → A`,
/// where the cycle crosses one or more intermediate structs).
///
/// Without this, mutually-recursive struct families would lay out
/// inline by value and explode at type-check or codegen time
/// (Zig's "struct has infinite size" diagnostic, or worse, an LLVM
/// crash). The check uses an iterative DFS keyed on struct name with
/// a visited set, so the cost is bounded by the program's struct
/// graph regardless of how the user wraps fields in containers.
///
/// `interner_lookup` translates a `StringId` to a string; the caller
/// passes its own interner so this function stays free of any
/// `IrBuilder` state and remains usable from raw-IR unit tests once
/// they wire up a TypeStore.
fn zigTypeReachesStructInCycle(
    allocator: std.mem.Allocator,
    t: ZigType,
    owner_name: []const u8,
    type_store: *const types_mod.TypeStore,
    interner: *const ast.StringInterner,
) !bool {
    var visited = std.StringHashMapUnmanaged(void){};
    defer visited.deinit(allocator);
    return reachesStructInCycleImpl(allocator, t, owner_name, &visited, type_store, interner);
}

fn reachesStructInCycleImpl(
    allocator: std.mem.Allocator,
    t: ZigType,
    owner_name: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    type_store: *const types_mod.TypeStore,
    interner: *const ast.StringInterner,
) !bool {
    return switch (t) {
        .struct_ref => |name| blk: {
            if (std.mem.eql(u8, name, owner_name)) break :blk true;
            // Avoid revisiting structs already on the DFS stack —
            // bounds the walk to one pass over the struct graph.
            if (visited.contains(name)) break :blk false;
            try visited.put(allocator, name, {});
            // Walk the named struct's field types, looking for a
            // path back to `owner_name`. The TypeStore is the
            // authoritative source of struct field shapes; the
            // `IrBuilder.fields` representation is built only at IR
            // finalization and isn't available here.
            for (type_store.types.items) |typ| {
                if (typ != .struct_type) continue;
                const st = typ.struct_type;
                const sname = interner.get(st.name);
                if (!std.mem.eql(u8, sname, name)) continue;
                for (st.fields) |f| {
                    const f_zig_type = typeIdToZigTypeWithStore(f.type_id, type_store);
                    if (try reachesStructInCycleImpl(allocator, f_zig_type, owner_name, visited, type_store, interner))
                        break :blk true;
                }
                break;
            }
            break :blk false;
        },
        .optional => |inner| try reachesStructInCycleImpl(allocator, inner.*, owner_name, visited, type_store, interner),
        .ptr => |pointee| try reachesStructInCycleImpl(allocator, pointee.*, owner_name, visited, type_store, interner),
        .list => |elem| try reachesStructInCycleImpl(allocator, elem.*, owner_name, visited, type_store, interner),
        .map => |mt| (try reachesStructInCycleImpl(allocator, mt.key.*, owner_name, visited, type_store, interner)) or
            (try reachesStructInCycleImpl(allocator, mt.value.*, owner_name, visited, type_store, interner)),
        .tuple => |elems| blk: {
            for (elems) |elem| {
                if (try reachesStructInCycleImpl(allocator, elem, owner_name, visited, type_store, interner)) break :blk true;
            }
            break :blk false;
        },
        .function => |ft| blk: {
            for (ft.params) |p| {
                if (try reachesStructInCycleImpl(allocator, p, owner_name, visited, type_store, interner)) break :blk true;
            }
            break :blk try reachesStructInCycleImpl(allocator, ft.return_type.*, owner_name, visited, type_store, interner);
        },
        .void,
        .bool_type,
        .nil,
        .never,
        .term,
        .any,
        .string,
        .atom,
        .i8,
        .i16,
        .i32,
        .i64,
        .i128,
        .u8,
        .u16,
        .u32,
        .u64,
        .u128,
        .f16,
        .f32,
        .f64,
        .f80,
        .f128,
        .usize,
        .isize,
        .tagged_union,
        // MArray cells are heap-managed runtime types whose `Inner`
        // never embeds a Zap user struct, so they can't carry a back-
        // reference to `owner_name`.
        .marray_i64,
        .marray_f64,
        => false,
    };
}

/// Convert a ZigType to its Zig source string representation.
/// Used by typeIdToZigTypeStrWithStore to avoid duplicating the TypeStore lookup.
fn zigTypeToStr(zig_type: ZigType) []const u8 {
    return switch (zig_type) {
        .void => "void",
        .bool_type => "bool",
        .i8 => "i8",
        .i16 => "i16",
        .i32 => "i32",
        .i64 => "i64",
        .i128 => "i128",
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .u128 => "u128",
        .f16 => "f16",
        .f32 => "f32",
        .f64 => "f64",
        .f80 => "f80",
        .f128 => "f128",
        .usize => "usize",
        .isize => "isize",
        .string => "[]const u8",
        .atom => "[]const u8",
        .nil => "?void",
        .marray_i64 => "?*const zap_runtime.MArrayOf(i64)",
        .marray_f64 => "?*const zap_runtime.MArrayOf(f64)",
        .struct_ref => |name| name,
        .tagged_union => |name| name,
        .function => "zap_runtime.DynClosure",
        .optional => "anytype",
        .any => "anytype",
        else => "anytype",
    };
}

/// Derives the string representation from the ZigType conversion,
/// eliminating duplicate TypeStore lookups.
fn typeIdToZigTypeStrWithStore(type_id: types_mod.TypeId, type_store: ?*const types_mod.TypeStore) []const u8 {
    const zig_type = typeIdToZigTypeWithStore(type_id, type_store);
    return zigTypeToStr(zig_type);
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "IR build simple function" {
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    try std.testing.expect(ir_program.functions.len > 0);
    try std.testing.expect(ir_program.functions[0].body.len > 0);
    try std.testing.expect(ir_program.functions[0].body[0].instructions.len > 0);
}

test "IR param_get indices are unique for multi-parameter functions" {
    const source =
        \\pub struct Test {
        \\  pub fn add(a, b) {
        \\    a + b
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    try std.testing.expect(ir_program.functions.len > 0);
    const func = ir_program.functions[0];
    try std.testing.expect(func.body.len > 0);

    // Collect all param_get instructions
    var param_gets: [2]u32 = .{ 0xFFFF, 0xFFFF };
    var pg_count: usize = 0;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .param_get => |pg| {
                if (pg_count < 2) {
                    param_gets[pg_count] = pg.index;
                }
                pg_count += 1;
            },
            else => {},
        }
    }

    // We should have exactly 2 param_get instructions
    try std.testing.expectEqual(@as(usize, 2), pg_count);
    // First param_get should have index 0, second should have index 1
    try std.testing.expectEqual(@as(u32, 0), param_gets[0]);
    try std.testing.expectEqual(@as(u32, 1), param_gets[1]);
}

test "IR call preserves HIR arg modes" {
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
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(apply_clause.meta.span)) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const ownerships = try alloc.alloc(types_mod.Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .unique;
    checker.store.types.items[f_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];
    var found_call = false;
    var found_move = false;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .move_value => found_move = true,
            .call_closure => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.move, call.arg_modes[0]);
                found_call = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_call);
    try std.testing.expect(found_move);
}

test "IR named call preserves move mode" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn take(handle :: Handle) {
        \\    handle
        \\  }
        \\
        \\  pub fn run(handle :: Handle) {
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const run_func = ir_program.functions[1];
    var found_call = false;
    var found_move = false;
    for (run_func.body[0].instructions) |instr| {
        switch (instr) {
            .move_value => found_move = true,
            .call_direct => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.move, call.arg_modes[0]);
                found_call = true;
            },
            .call_named => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.move, call.arg_modes[0]);
                found_call = true;
            },
            else => {},
        }
    }
    try std.testing.expect(found_call);
    try std.testing.expect(found_move);
}

test "IR closure call preserves borrow mode without ARC ops" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn apply(f :: (Handle -> Handle), x :: Handle) {
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

    const apply_clause = program.structs[0].items[1].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(apply_clause.meta.span)) orelse apply_clause.meta.scope_id;
    const f_binding = collector.graph.resolveBinding(clause_scope, apply_clause.params[0].pattern.bind.name).?;
    const f_type_id = collector.graph.bindings.items[f_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[f_type_id].function;
    const ownerships = try alloc.alloc(types_mod.Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .borrowed;
    checker.store.types.items[f_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];
    var found_call = false;
    var retain_count: usize = 0;
    var release_count: usize = 0;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .call_closure => |call| {
                try std.testing.expectEqual(@as(usize, 1), call.arg_modes.len);
                try std.testing.expectEqual(ValueMode.borrow, call.arg_modes[0]);
                found_call = true;
            },
            .retain => retain_count += 1,
            .release => release_count += 1,
            else => {},
        }
    }
    try std.testing.expect(found_call);
    try std.testing.expectEqual(@as(usize, 0), retain_count);
    try std.testing.expectEqual(@as(usize, 0), release_count);
}

test "IR shared opaque call emits retain and release" {
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use(handle :: Handle) {
        \\    handle
        \\  }
        \\
        \\  pub fn run(use_fn :: (Handle -> Handle), handle :: Handle) {
        \\    use_fn(handle)
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

    const run_clause = program.structs[0].items[2].function.clauses[0];
    const clause_scope = collector.graph.node_scope_map.get(scope_mod.ScopeGraph.spanKey(run_clause.meta.span)) orelse run_clause.meta.scope_id;
    const fn_binding = collector.graph.resolveBinding(clause_scope, run_clause.params[0].pattern.bind.name).?;
    const fn_type_id = collector.graph.bindings.items[fn_binding].type_id.?.type_id;
    const original_fn_type = checker.store.types.items[fn_type_id].function;
    const ownerships = try alloc.alloc(types_mod.Ownership, original_fn_type.params.len);
    for (ownerships, 0..) |*ownership, idx| ownership.* = original_fn_type.param_ownerships.?[idx];
    ownerships[0] = .shared;
    checker.store.types.items[fn_type_id] = .{ .function = .{
        .params = original_fn_type.params,
        .return_type = original_fn_type.return_type,
        .param_ownerships = ownerships,
        .return_ownership = original_fn_type.return_ownership,
    } };

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const run_func = ir_program.functions[1];
    var share_count: usize = 0;
    var release_count: usize = 0;
    for (run_func.body[0].instructions) |instr| {
        switch (instr) {
            .share_value => share_count += 1,
            .release => release_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), share_count);
    try std.testing.expectEqual(@as(usize, 1), release_count);
}

test "isTcoSafeType: scalars are safe" {
    try std.testing.expect(IrBuilder.isTcoSafeType(.i64));
    try std.testing.expect(IrBuilder.isTcoSafeType(.f64));
    try std.testing.expect(IrBuilder.isTcoSafeType(.bool_type));
    try std.testing.expect(IrBuilder.isTcoSafeType(.atom));
    try std.testing.expect(IrBuilder.isTcoSafeType(.usize));
    try std.testing.expect(IrBuilder.isTcoSafeType(.never));
    try std.testing.expect(IrBuilder.isTcoSafeType(.void));
}

test "isTcoSafeType: byref aggregates are unsafe" {
    try std.testing.expect(!IrBuilder.isTcoSafeType(.{ .struct_ref = "Body" }));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.string));
    const elem: ZigType = .i64;
    try std.testing.expect(!IrBuilder.isTcoSafeType(.{ .list = &elem }));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.{ .tuple = &.{} }));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.term));
    try std.testing.expect(!IrBuilder.isTcoSafeType(.any));
}

test "rewriteTailCalls marks byref recursion for loopification" {
    // A multi-clause recursive function whose parameter list contains
    // a struct still gets the `tail_call` rewrite — but the function's
    // `loopify` flag is set so the ZIR backend lowers to a loop +
    // stack-slot recurrence instead of LLVM `musttail` (which rejects
    // byref signatures under fastcc). Earlier passes silently kept the
    // recursion as `call_named + ret` for byref shapes, which compiled
    // cleanly but blew the stack at scale.
    const source =
        \\pub struct State {
        \\  a :: f64
        \\  b :: f64
        \\}
        \\
        \\pub struct LoopHost {
        \\  pub fn loop(s :: State, 0 :: i64) -> State {
        \\    s
        \\  }
        \\  pub fn loop(s :: State, n :: i64) -> State {
        \\    LoopHost.loop(s, n - 1)
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
    var checker = types_mod.TypeChecker.initWithSharedStore(alloc, &type_store, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var saw_tail_call = false;
    var saw_loopify = false;
    for (ir_program.functions) |func| {
        if (!std.mem.startsWith(u8, func.name, "LoopHost__loop")) continue;
        if (func.loopify) saw_loopify = true;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .tail_call) saw_tail_call = true;
                if (instr == .switch_return) {
                    for (instr.switch_return.cases) |case| {
                        for (case.body_instrs) |bi| if (bi == .tail_call) {
                            saw_tail_call = true;
                        };
                    }
                    for (instr.switch_return.default_instrs) |bi| if (bi == .tail_call) {
                        saw_tail_call = true;
                    };
                }
            }
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(saw_loopify);
}

test "rewriteTailCalls still rewrites primitive-only recursion" {
    // The companion to the byref test: a recursive function with
    // only scalar parameters and a scalar return must still get the
    // `tail_call` rewrite. This is the working primitive case the
    // existing TCO support targets, and the byref guard must not
    // accidentally disable it.
    const source =
        \\pub struct LoopHostScalar {
        \\  pub fn loop(0 :: i64, acc :: i64) -> i64 {
        \\    acc
        \\  }
        \\  pub fn loop(n :: i64, acc :: i64) -> i64 {
        \\    LoopHostScalar.loop(n - 1, acc + 1)
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
    var checker = types_mod.TypeChecker.initWithSharedStore(alloc, &type_store, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var saw_tail_call = false;
    for (ir_program.functions) |func| {
        if (!std.mem.startsWith(u8, func.name, "LoopHostScalar__loop")) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                if (instr == .tail_call) saw_tail_call = true;
                if (instr == .switch_return) {
                    for (instr.switch_return.cases) |case| {
                        for (case.body_instrs) |bi| if (bi == .tail_call) {
                            saw_tail_call = true;
                        };
                    }
                    for (instr.switch_return.default_instrs) |bi| if (bi == .tail_call) {
                        saw_tail_call = true;
                    };
                }
            }
        }
    }
    try std.testing.expect(saw_tail_call);
}

test "rewriteTailCalls walks past intervening releases for ARC tail recursion" {
    // The k-nucleotide hot loop hits this shape: a self-recursive
    // tail-position call whose ARC-managed argument is shared via
    // `share_value` and gets a post-call `release{value=shared_dest}`
    // emitted by the call lowering. Without walking past the
    // trailing release the rewriter mistakes "is the immediately-
    // preceding instruction a call_named?" for "no" and leaves a
    // regular `call_named + ret`. At k-nucleotide-scale workloads
    // (~hundreds of thousands of recursive iterations) the missing
    // tail-call optimization blows the stack.
    //
    // This regression test pins the rewriter's behaviour: even when
    // a `.release` instruction sits between the recursive call and
    // the `ret`, the result must contain a `tail_call` (and the
    // per-arg release must be elided because the callee inherits
    // ownership through the tail jump).
    const source =
        \\pub struct Loop {
        \\  opaque Cell = String
        \\
        \\  pub fn step(c :: Cell) -> Cell {
        \\    Loop.step(c)
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
    var checker = types_mod.TypeChecker.initWithSharedStore(alloc, &type_store, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, &type_store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = &type_store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var saw_tail_call = false;
    var saw_call_named_to_self = false;
    var saw_orphan_release = false;
    for (ir_program.functions) |func| {
        if (!std.mem.startsWith(u8, func.name, "Loop__step")) continue;
        for (func.body) |block| {
            for (block.instructions) |instr| {
                switch (instr) {
                    .tail_call => |tc| {
                        if (std.mem.startsWith(u8, tc.name, "Loop__step")) saw_tail_call = true;
                    },
                    .call_named => |cn| {
                        if (std.mem.startsWith(u8, cn.name, "Loop__step")) saw_call_named_to_self = true;
                    },
                    // After the rewrite, the per-arg release on the
                    // shared dest must be elided — the callee
                    // inherits ownership across the tail jump and the
                    // release would never fire (post-tail
                    // instructions are dead code) or, worse, fire
                    // before the tail jump and decrement the cell
                    // out from under the callee.
                    .release => saw_orphan_release = true,
                    else => {},
                }
            }
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_call_named_to_self);
    try std.testing.expect(!saw_orphan_release);
}

test "rewriteTailCalls walks past borrow_value/copy_value/move_value/retain trailing instructions (Phase E.6)" {
    // Phase E.6 of the Phase 6 redux plan: between the recursive
    // `call_named` and the trailing `ret`, ARC infrastructure may
    // interleave any of:
    //
    //   * `.release` (post-call shared-arg cleanup, drop insertion)
    //   * `.retain` (refcount bump pairs)
    //   * `.borrow_value` / `.copy_value` (Phase C alias/copy)
    //   * `.move_value` (ownership transfer)
    //
    // The rewriter must walk past every one of these and recognise the
    // tail-position recursive call. This test hand-constructs an
    // instruction stream containing each kind of trailing instruction
    // and checks the rewrite produces a `.tail_call` with no surviving
    // `.call_named` to self.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    // Hand-built layout for `pub fn step(c) -> Cell { step(c) }` after
    // arg lowering, drop insertion, and Phase C ownership normalisation
    // have run:
    //
    //   %0 = call_named(name="step", args=[%10], dest=%20)
    //   borrow_value %30 <- %10        // Phase C alias (no runtime effect)
    //   copy_value   %31 <- %10        // Phase C copy (retain)
    //   move_value   %32 <- %20        // ownership transfer of call result
    //   retain       %31               // refcount bump
    //   release      %10               // shared-arg release (DROPPED on rewrite — %10 in args)
    //   release      %99               // non-arg release (PRESERVED before tail_call)
    //   ret          %20
    const args = try alloc.alloc(LocalId, 1);
    args[0] = 10;
    const arg_modes = try alloc.alloc(ValueMode, 1);
    arg_modes[0] = .share;

    const instrs = try alloc.alloc(Instruction, 8);
    instrs[0] = .{ .call_named = .{ .dest = 20, .name = "step", .args = args, .arg_modes = arg_modes } };
    instrs[1] = .{ .borrow_value = .{ .dest = 30, .source = 10 } };
    instrs[2] = .{ .copy_value = .{ .dest = 31, .source = 10 } };
    instrs[3] = .{ .move_value = .{ .dest = 32, .source = 20 } };
    instrs[4] = .{ .retain = .{ .value = 31 } };
    instrs[5] = .{ .release = .{ .value = 10 } };
    instrs[6] = .{ .release = .{ .value = 99 } };
    instrs[7] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 1);
    params[0] = .{ .name = "c", .type_expr = .void, .type_id = null };

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_borrow_value = false;
    var saw_copy_value = false;
    var saw_move_value = false;
    var saw_retain = false;
    var preserved_non_arg_release = false;
    var dropped_arg_release = true;
    var saw_call_named_to_self = false;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => |tc| {
                if (std.mem.eql(u8, tc.name, "step")) saw_tail_call = true;
            },
            .call_named => |cn| {
                if (std.mem.eql(u8, cn.name, "step")) saw_call_named_to_self = true;
            },
            .borrow_value => saw_borrow_value = true,
            .copy_value => saw_copy_value = true,
            .move_value => saw_move_value = true,
            .retain => saw_retain = true,
            .release => |r| {
                if (r.value == 99) preserved_non_arg_release = true;
                if (r.value == 10) dropped_arg_release = false;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_call_named_to_self);
    try std.testing.expect(saw_borrow_value);
    try std.testing.expect(saw_copy_value);
    try std.testing.expect(saw_move_value);
    try std.testing.expect(saw_retain);
    try std.testing.expect(preserved_non_arg_release);
    try std.testing.expect(dropped_arg_release);
}

test "rewriteTailCalls bails out on non-tail-mappable trailing instruction (Phase E.6)" {
    // Phase E.6: when an instruction sitting between the recursive
    // call and the `ret` is NOT in the tail-mappable set (for example
    // a `.struct_init`), the rewriter must NOT silently fall back to
    // `.call_named + .ret` — that would hide the regression behind a
    // stack-blowing recursion at runtime. Instead, it leaves the call
    // unchanged so the verifier's V6 invariant fires at compile time.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    const args = try alloc.alloc(LocalId, 0);
    _ = args;
    const arg_modes = try alloc.alloc(ValueMode, 0);
    _ = arg_modes;

    const fields = try alloc.alloc(StructFieldInit, 1);
    fields[0] = .{ .name = "f", .value = 5 };

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .call_named = .{ .dest = 20, .name = "step", .args = &.{}, .arg_modes = &.{} } };
    instrs[1] = .{ .struct_init = .{ .dest = 21, .type_name = "T", .fields = fields } };
    instrs[2] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 0);

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_call_named = false;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => saw_tail_call = true,
            .call_named => saw_call_named = true,
            else => {},
        }
    }
    try std.testing.expect(!saw_tail_call);
    try std.testing.expect(saw_call_named);
}

test "rewriteTailCalls elides matched share_value/release pair and substitutes call arg (Phase E.8)" {
    // Phase E.8 of the Phase 6 redux plan — orphan-share fix.
    //
    // The tail-call rewriter drops a trailing `.release{value=X}` of a
    // call-arg slot because the callee inherits ownership through the
    // tail jump. Without a matching cleanup of the prelude, the
    // `.share_value{dest=X, source=Y}` that originally retained the
    // cell for the call argument becomes an "orphan share" — a +1
    // retain whose paired release no longer exists. At iteration
    // scale (millions of calls) the orphan retains accumulate and
    // produce the exact pool-leak signature observed in Phase F's
    // retry-3 (8.75M Map cells/run, refcount=2 at every step).
    //
    // The fix: when the rewriter drops a trailing `.release{value=X}`,
    // it must also drop the matching `.share_value{dest=X, source=Y}`
    // earlier in the body and substitute the call's arg `X` with `Y`.
    //
    // Hand-built layout:
    //   share_value  %30 <- %10            // retain for call arg
    //   call_named   step args=[%30] -> %20
    //   release      %30                   // post-call cleanup (DROPPED)
    //   ret          %20
    //
    // After rewrite:
    //   tail_call    step args=[%10]       // arg substituted to source
    //   (no share_value, no release, no call_named)
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    const args = try alloc.alloc(LocalId, 1);
    args[0] = 30;
    const arg_modes = try alloc.alloc(ValueMode, 1);
    arg_modes[0] = .share;

    const instrs = try alloc.alloc(Instruction, 4);
    instrs[0] = .{ .share_value = .{ .dest = 30, .source = 10 } };
    instrs[1] = .{ .call_named = .{ .dest = 20, .name = "step", .args = args, .arg_modes = arg_modes } };
    instrs[2] = .{ .release = .{ .value = 30 } };
    instrs[3] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 1);
    params[0] = .{ .name = "c", .type_expr = .void, .type_id = null };

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_share_value = false;
    var saw_release = false;
    var saw_call_named = false;
    var tail_call_arg: ?LocalId = null;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => |tc| {
                saw_tail_call = true;
                if (tc.args.len > 0) tail_call_arg = tc.args[0];
            },
            .share_value => saw_share_value = true,
            .release => saw_release = true,
            .call_named => saw_call_named = true,
            else => {},
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_share_value);
    try std.testing.expect(!saw_release);
    try std.testing.expect(!saw_call_named);
    // The tail_call's arg must be the original source local (10),
    // not the now-removed share dest (30).
    try std.testing.expectEqual(@as(?LocalId, 10), tail_call_arg);
}

test "rewriteTailCalls handles unmatched release without breaking (Phase E.8)" {
    // Phase E.8: the orphan-share fix must not regress the pre-existing
    // E.6 behaviour for releases that have no matching `share_value`
    // earlier in the body. This can happen e.g. when the source local
    // was passed in as a parameter that was bumped via `.retain`
    // rather than aliased through `.share_value`. The rewriter still
    // drops the release (it's an arg-cleanup release), but there is
    // no share to find — the call's arg stays as-is.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var ir_builder = IrBuilder.init(alloc, &interner);
    defer ir_builder.deinit();

    const args = try alloc.alloc(LocalId, 1);
    args[0] = 10;
    const arg_modes = try alloc.alloc(ValueMode, 1);
    arg_modes[0] = .share;

    const instrs = try alloc.alloc(Instruction, 3);
    instrs[0] = .{ .call_named = .{ .dest = 20, .name = "step", .args = args, .arg_modes = arg_modes } };
    instrs[1] = .{ .release = .{ .value = 10 } };
    instrs[2] = .{ .ret = .{ .value = 20 } };

    const params = try alloc.alloc(Param, 1);
    params[0] = .{ .name = "c", .type_expr = .void, .type_id = null };

    const rewritten = try ir_builder.rewriteTailCalls(instrs, "step", 0, params, .void);

    var saw_tail_call = false;
    var saw_release = false;
    var saw_call_named = false;
    var tail_call_arg: ?LocalId = null;
    for (rewritten) |instr| {
        switch (instr) {
            .tail_call => |tc| {
                saw_tail_call = true;
                if (tc.args.len > 0) tail_call_arg = tc.args[0];
            },
            .release => saw_release = true,
            .call_named => saw_call_named = true,
            else => {},
        }
    }
    try std.testing.expect(saw_tail_call);
    try std.testing.expect(!saw_release);
    try std.testing.expect(!saw_call_named);
    // Without a matching share, the arg stays as the original local.
    try std.testing.expectEqual(@as(?LocalId, 10), tail_call_arg);
}

test "IR local_get of ARC-managed source emits retain on dest" {
    // Phase 6 — Option B ownership protocol: every named binding of an
    // ARC-managed value owns an independent +1 refcount on the underlying
    // cell. The IR builder honors this by emitting a `.retain{value=dest}`
    // immediately after every `.local_get` whose source is ARC-managed,
    // making the alias a stand-alone ownership unit. This test pins the
    // invariant for `opaque_type` (the only currently-flagged ARC type).
    //
    // Source pattern:
    //   pub fn alias_use(h :: Handle) {
    //     aliased = h
    //     aliased
    //   }
    // - `h` is a parameter. `aliased = h` lowers to a local_set that records
    //   `h` (a param_get's dest) into the binding's local. The trailing
    //   `aliased` expression lowers to a `.local_get{dest=N, source=binding}`.
    // - With the Phase 6 retain rule, that local_get is followed by
    //   `.retain{value=N}` because Handle is ARC-managed (opaque_type).
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn alias_use(h :: Handle) {
        \\    aliased = h
        \\    aliased
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];

    // Walk the body and find every `.local_get`. For each, the *immediately
    // following* instruction must be a `.retain` whose `value` equals the
    // local_get's `dest`. There must be at least one such pair (the body's
    // tail expression `aliased`).
    var found_pair: bool = false;
    const instrs = func.body[0].instructions;
    for (instrs, 0..) |instr, idx| {
        if (instr != .local_get) continue;
        const lg = instr.local_get;
        try std.testing.expect(idx + 1 < instrs.len);
        const next = instrs[idx + 1];
        try std.testing.expect(next == .retain);
        try std.testing.expectEqual(lg.dest, next.retain.value);
        found_pair = true;
    }
    try std.testing.expect(found_pair);
}

test "IR local_get of non-ARC source does NOT emit retain" {
    // Counter-test: scalar locals (e.g. i64) must not generate an extra
    // retain after `.local_get`. Phase 6 retain emission is gated on
    // `IrBuilder.isArcManagedType(expr.type_id)`. This pins the gate.
    const source =
        \\pub struct Test {
        \\  pub fn alias_use(n :: i64) -> i64 {
        \\    aliased = n
        \\    aliased
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];
    var retain_count: usize = 0;
    for (func.body[0].instructions) |instr| {
        switch (instr) {
            .retain => retain_count += 1,
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 0), retain_count);
}

test "ShareValue defaults to retain mode" {
    // Phase 3: every existing IR construction site that does not
    // explicitly set `mode` must carry `.retain`, so default behavior
    // is preserved bit-for-bit until the ARC liveness pass starts
    // upgrading sites in phase 4. This test pins the default and
    // makes any accidental change to it (e.g. flipping the default
    // to `.consume`) surface as an immediate test failure.
    const default_share = ShareValue{ .dest = 1, .source = 2 };
    try std.testing.expectEqual(ShareMode.retain, default_share.mode);

    const explicit_consume = ShareValue{ .dest = 3, .source = 4, .mode = .consume };
    try std.testing.expectEqual(ShareMode.consume, explicit_consume.mode);
}

test "ShareMode enum has exactly retain and consume" {
    // Phase 3: the lowering switch in `zir_builder.zig` is exhaustive
    // over `ShareMode`. Anyone adding a new variant must update the
    // lowering and break the build at the switch site, but we also
    // pin the variant set here so a renaming or accidental addition
    // surfaces as a test diff rather than a silent semantic change.
    const fields = std.meta.fields(ShareMode);
    try std.testing.expectEqual(@as(usize, 2), fields.len);
    try std.testing.expectEqualStrings("retain", fields[0].name);
    try std.testing.expectEqualStrings("consume", fields[1].name);
}

test "IR pattern-binding local_get of ARC-managed scrutinee emits retain" {
    // Phase 6 — Option B ownership protocol: the four pattern-binding
    // `.local_get` sites (case scrutinee bind, switch_literal default-arm
    // bind, decision-tree `.bind` node, guard scrutinee resolve) must
    // also emit `.retain{value=dest}` when the source is ARC-managed.
    // Before the unified `emitLocalGet` helper landed, the named-binding
    // `local_get` retained but pattern bindings did not, leaving case-
    // dispatch on ARC values with under-counted refcounts.
    //
    // The source pins the simplest pattern that exercises the
    // `lowerCaseExprBody` decision-tree path with a scrutinee bind:
    //   case h {
    //     bound -> bound
    //   }
    // After lowering, the bind's `.local_get{dest=bound, source=scr}`
    // must be immediately followed by `.retain{value=bound}`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn case_bind(h :: Handle) -> Handle {
        \\    case h {
        \\      bound -> bound
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

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    const func = ir_program.functions[0];

    // Walk every instruction (including those nested inside structural
    // sub-streams like case_block.pre_instrs) and search for any
    // `.local_get` whose immediately following sibling is a `.retain`
    // matching the same dest. Since `case h { bound -> bound }` lowers
    // to a `case_block` containing a decision-tree leaf with a
    // scrutinee-bind followed by the body's `bound` reference, we
    // expect at least one such pair somewhere in the function.
    const Walker = struct {
        found_pair: bool = false,

        fn visit(ctx: *@This(), instr_stream: []const Instruction) void {
            for (instr_stream, 0..) |instr, idx| {
                if (instr == .local_get and idx + 1 < instr_stream.len) {
                    const lg = instr.local_get;
                    const next = instr_stream[idx + 1];
                    if (next == .retain and next.retain.value == lg.dest) {
                        ctx.found_pair = true;
                    }
                }
                switch (instr) {
                    .case_block => |cb| {
                        ctx.visit(cb.pre_instrs);
                        for (cb.arms) |arm| {
                            ctx.visit(arm.cond_instrs);
                            ctx.visit(arm.body_instrs);
                        }
                        ctx.visit(cb.default_instrs);
                    },
                    .if_expr => |ie| {
                        ctx.visit(ie.then_instrs);
                        ctx.visit(ie.else_instrs);
                    },
                    .guard_block => |gb| ctx.visit(gb.body),
                    .switch_literal => |sw| {
                        for (sw.cases) |c| ctx.visit(c.body_instrs);
                        ctx.visit(sw.default_instrs);
                    },
                    else => {},
                }
            }
        }
    };

    var walker = Walker{};
    for (func.body) |block| {
        walker.visit(block.instructions);
    }
    try std.testing.expect(walker.found_pair);
}

test "Instruction.share_value carries the mode field through union storage" {
    // Phase 3: confirm an Instruction value built with a `.consume`-
    // mode `ShareValue` round-trips through the tagged-union storage
    // without losing the mode. Catches any future flattening of
    // ShareValue that accidentally drops the new field.
    const instr: Instruction = .{
        .share_value = .{ .dest = 5, .source = 6, .mode = .consume },
    };
    try std.testing.expectEqual(ShareMode.consume, instr.share_value.mode);

    const default_instr: Instruction = .{
        .share_value = .{ .dest = 7, .source = 8 },
    };
    try std.testing.expectEqual(ShareMode.retain, default_instr.share_value.mode);
}

test "ownership metadata: ARC-managed identity function gets borrowed param + owned result" {
    // Phase A of the Phase 6 redux plan: a function whose single
    // parameter has an ARC-managed type must default to a `.borrowed`
    // calling convention, and a function that returns an ARC-managed
    // value must default to an `.owned` result convention. The
    // parameter local in `local_ownership` is also `.borrowed` —
    // matching the convention so drop insertion (Phase B onwards)
    // skips it correctly when scope-exit destroys are emitted.
    //
    // We use `opaque_type` (Handle) here because it's already
    // ARC-flagged and exercises the same `isArcManagedTypeId`
    // predicate Phase F will eventually flip on for `.map`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var found_id_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "id") != null) {
            found_id_func = function;
            break;
        }
    }
    const id_func = found_id_func orelse return error.MissingFunction;

    // Per-parameter conventions match the params slice exactly.
    try std.testing.expectEqual(id_func.params.len, id_func.param_conventions.len);
    try std.testing.expectEqual(@as(usize, 1), id_func.params.len);
    try std.testing.expectEqual(ParamConvention.borrowed, id_func.param_conventions[0]);

    // ARC-managed return type defaults to .owned.
    try std.testing.expectEqual(ResultConvention.owned, id_func.result_convention);

    // local_ownership is sized to local_count; the param-bound local
    // (LocalId 0 by `param_get` allocation order) is ARC-managed, so
    // Phase A's stub classifier marks it `.owned`. Phase C will
    // refine this to `.borrowed` once the borrow/copy split lands.
    try std.testing.expectEqual(@as(usize, id_func.local_count), id_func.local_ownership.len);
    try std.testing.expect(id_func.local_count >= 1);
    // The first local emitted is the param_get for the single arg.
    try std.testing.expectEqual(OwnershipClass.owned, id_func.local_ownership[0]);
}

test "ownership metadata: non-ARC parameters classify as trivial" {
    // Phase A counter-test: scalar parameters (i64, Bool, ...) must
    // never receive a non-trivial calling convention. ARC discipline
    // does not fire on these locals: `param_conventions` reports
    // `.trivial`, the result convention is `.trivial`, and every
    // local in the function defaults to `.trivial` since none hold
    // an ARC-managed cell.
    const source =
        \\pub struct Test {
        \\  pub fn add(x :: i64, y :: i64) -> i64 { x + y }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const ast_program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&ast_program);

    var checker = types_mod.TypeChecker.init(alloc, parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&ast_program);

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&ast_program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var found_add_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "add") != null) {
            found_add_func = function;
            break;
        }
    }
    const add_func = found_add_func orelse return error.MissingFunction;

    try std.testing.expectEqual(@as(usize, 2), add_func.param_conventions.len);
    try std.testing.expectEqual(ParamConvention.trivial, add_func.param_conventions[0]);
    try std.testing.expectEqual(ParamConvention.trivial, add_func.param_conventions[1]);

    try std.testing.expectEqual(ResultConvention.trivial, add_func.result_convention);

    // No local in this function holds an ARC cell, so every entry in
    // local_ownership must be `.trivial`.
    try std.testing.expectEqual(@as(usize, add_func.local_count), add_func.local_ownership.len);
    for (add_func.local_ownership) |class| {
        try std.testing.expectEqual(OwnershipClass.trivial, class);
    }
}

test "ownership metadata: defaultParamConvention and defaultResultConvention agree on ARC predicate" {
    // The free-function helpers (`defaultParamConvention`,
    // `defaultResultConvention`) must agree with the IrBuilder's
    // type-resolution path so analysis passes outside the IrBuilder
    // (arc_ownership, arc_verifier in later phases) reach the same
    // conclusions about a given type. This is a property test on the
    // helpers themselves; it pins the contract that ARC-managed
    // types map to (.borrowed param, .owned result) and non-ARC
    // types map to (.trivial param, .trivial result).
    //
    // Because the helpers tolerate a null `type_store`, the unit
    // test asserts the null-fallback path too: callers without
    // type information default to `.trivial` so the analysis never
    // accidentally classifies an unknown local as ARC-managed.
    try std.testing.expectEqual(ParamConvention.trivial, defaultParamConvention(null, null));
    try std.testing.expectEqual(ResultConvention.trivial, defaultResultConvention(null, null));
    try std.testing.expectEqual(ParamConvention.trivial, defaultParamConvention(null, 0));
    try std.testing.expectEqual(ResultConvention.trivial, defaultResultConvention(null, 0));
}

test "Phase E.5 Gap 1: share_value shared_local has ARC-managed local_ownership" {
    // When IrBuilder lowers a call argument with `.share` mode and an
    // ARC-managed expression type, it allocates a fresh `shared_local`
    // and emits `share_value{shared_local, source_local}`. The shared
    // local owns +1 from the share's retain and must be classified as
    // ARC-managed in `Function.local_ownership`. Without HIR-type
    // propagation onto `shared_local`, `local_ownership[shared_local]`
    // would default to `.trivial` and the verifier's V2 invariant
    // (release target's HIR type matches the local's ownership class)
    // would mismatch when the post-call `release{shared_local}` fires.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn use(h :: Handle) -> Handle { h }
        \\
        \\  pub fn run(h :: Handle) -> Handle {
        \\    Test.use(h)
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var run_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "run") != null) {
            run_func = function;
            break;
        }
    }
    const func = run_func orelse return error.MissingFunction;

    // Find the share_value instruction in the function body.
    var found_share = false;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .share_value => |sv| {
                    found_share = true;
                    // The shared local must be classified as ARC-managed
                    // in local_ownership. Phase A's stub classifier
                    // labels every ARC-managed local as `.owned` until
                    // arc_ownership refines it; either `.owned` or
                    // `.borrowed` is acceptable here, but never
                    // `.trivial`.
                    try std.testing.expect(sv.dest < func.local_ownership.len);
                    try std.testing.expect(func.local_ownership[sv.dest] != .trivial);
                    // Likewise the source must be ARC-managed (the share
                    // only fires when the source's HIR type is ARC).
                    try std.testing.expect(sv.source < func.local_ownership.len);
                    try std.testing.expect(func.local_ownership[sv.source] != .trivial);
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_share);
}

test "Phase E.5 Gap 2: param_get HIR-expression dest gets ARC-managed local_ownership in single-clause function" {
    // A single-clause function `pub fn id(h :: Handle) -> Handle { h }`
    // lowers `h` to a HIR `param_get` expression. The IR's
    // `lowerExpr.param_get` arm allocates a fresh dest local and
    // emits `param_get{dest, index=0}`. The dest local must be
    // classified as ARC-managed in `local_ownership` because its
    // value originates from a borrowed-convention parameter of an
    // ARC-managed type. Without populating `local_hir_types[dest]`
    // from the function's declared param types,
    // `local_ownership[dest]` would default to `.trivial` and
    // arc_liveness would never include the dest in
    // `arc_managed_locals`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn id(h :: Handle) -> Handle { h }
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var id_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "id") != null) {
            id_func = function;
            break;
        }
    }
    const func = id_func orelse return error.MissingFunction;

    // Walk the body for every `param_get` instruction. Each dest
    // local must be classified as ARC-managed (non-trivial) since
    // the parameter's HIR type is the ARC-managed `Handle` opaque.
    var found_param_get = false;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .param_get => |pg| {
                    found_param_get = true;
                    try std.testing.expect(pg.dest < func.local_ownership.len);
                    try std.testing.expect(func.local_ownership[pg.dest] != .trivial);
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_param_get);
}

test "Phase E.5 Gap 3: assignment-binding indices reserved before IR-level next_local allocation" {
    // A function with `name = expr; ... name ...` allocates `name`'s
    // local index via HIR's per-clause `next_local` counter. That
    // counter is shared with pattern bindings, so the resulting
    // index can land in the IR builder's expression-lowering range
    // unless `computeMaxBindingLocalForClauses` accounts for body
    // `local_set.index` values. Concretely: the IR builder must
    // reserve enough locals up-front so no `lowerExpr` allocation
    // collides with an assignment binding's index.
    //
    // We exercise this by writing a function whose body assigns a
    // local then reads it. Every `local_set.dest` index must be at
    // least as large as `func.local_ownership.len` would be if the
    // pre-allocation were missing — equivalently: every local_set
    // dest must fall within `func.local_count`, and no IR-emitted
    // instruction before the local_set targets that same dest.
    const source =
        \\pub struct Test {
        \\  pub fn assign_then_read() -> i64 {
        \\    x = 42
        \\    x + 1
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var assign_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "assign_then_read") != null) {
            assign_func = function;
            break;
        }
    }
    const func = assign_func orelse return error.MissingFunction;

    // Find every local_set; its dest index must be valid.
    var local_set_dest: ?LocalId = null;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .local_set => |ls| {
                    try std.testing.expect(ls.dest < func.local_count);
                    local_set_dest = ls.dest;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(local_set_dest != null);

    // The local_set's dest must NOT have been allocated as a fresh
    // dest by an earlier `lowerExpr` in the same function — i.e. it
    // must be in the reserved binding-local range. Walk the body
    // once and assert no instruction *before* the local_set defines
    // ls.dest as its own dest (that would indicate a collision).
    const dest = local_set_dest.?;
    var seen_local_set_for_dest = false;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            if (instr == .local_set and instr.local_set.dest == dest) {
                seen_local_set_for_dest = true;
                continue;
            }
            if (seen_local_set_for_dest) break;
            // Before the local_set: ensure no instruction's dest
            // equals our binding-local index.
            const conflicting_dest: ?LocalId = switch (instr) {
                .const_int => |x| x.dest,
                .const_float => |x| x.dest,
                .const_string => |x| x.dest,
                .const_bool => |x| x.dest,
                .const_atom => |x| x.dest,
                .binary_op => |x| x.dest,
                .unary_op => |x| x.dest,
                .call_named => |x| x.dest,
                .call_direct => |x| x.dest,
                .call_builtin => |x| x.dest,
                else => null,
            };
            if (conflicting_dest) |cd| {
                try std.testing.expect(cd != dest);
            }
        }
    }
}

test "Phase E.5 Gap 5: arc_managed_locals registers map_init / list_init / call dests of ARC type" {
    // `arc_liveness.identifyArcLocals` must register every local
    // whose value is ARC-managed by construction — not only those
    // that flow through `share_value` / `retain` / `release`. The
    // canonical anchor is `Function.local_ownership[L] != .trivial`
    // (populated by IrBuilder from `local_hir_types`). Without this
    // registration, scope-exit drops never fire on owned bindings
    // such as `m = map_init(...)`, leaking the cell on every
    // function exit.
    //
    // We use `opaque_type` (Handle) as our ARC-managed scalar. A
    // function that calls another ARC-returning function and binds
    // the result must register that binding local as ARC-managed
    // even though no `share_value` mentions it on the value side.
    //
    // This test pins the contract; the implementation lives in
    // `arc_liveness.identifyArcLocals`.
    const source =
        \\pub struct Test {
        \\  opaque Handle = String
        \\
        \\  pub fn make() -> Handle {
        \\    Test.fresh()
        \\  }
        \\
        \\  pub fn fresh() -> Handle {
        \\    "x"
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

    var hir_builder = hir_mod.HirBuilder.init(alloc, parser.interner, &collector.graph, checker.store);
    defer hir_builder.deinit();
    const hir_program = try hir_builder.buildProgram(&program);

    var ir_builder = IrBuilder.init(alloc, parser.interner);
    ir_builder.type_store = checker.store;
    defer ir_builder.deinit();
    const ir_program = try ir_builder.buildProgram(&hir_program);

    var make_func: ?*const Function = null;
    for (ir_program.functions) |*function| {
        if (std.mem.indexOf(u8, function.name, "make") != null) {
            make_func = function;
            break;
        }
    }
    const func = make_func orelse return error.MissingFunction;

    // Find the call instruction; its dest must be ARC-managed in
    // local_ownership (precondition for arc_liveness to register
    // it). This is a Phase A/B/C invariant the gap relies on.
    var call_dest: ?LocalId = null;
    for (func.body) |block| {
        for (block.instructions) |instr| {
            switch (instr) {
                .call_named => |c| {
                    if (c.dest < func.local_ownership.len and
                        func.local_ownership[c.dest] != .trivial)
                    {
                        call_dest = c.dest;
                    }
                },
                .call_direct => |c| {
                    if (c.dest < func.local_ownership.len and
                        func.local_ownership[c.dest] != .trivial)
                    {
                        call_dest = c.dest;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(call_dest != null);

    // Now run arc_liveness and assert the call dest is in
    // arc_managed_locals.
    const arc_liveness = @import("arc_liveness.zig");
    var ownership = try arc_liveness.computeArcOwnership(
        std.testing.allocator,
        func,
        checker.store,
        arc_liveness.defaultArcManagedTypeId,
    );
    defer ownership.deinit(std.testing.allocator);

    try std.testing.expect(ownership.arc_managed_locals.contains(call_dest.?));
}
