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

pub const StructFieldDef = struct {
    name: []const u8,
    type_expr: []const u8,
    default_value: ?DefaultValue = null,
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

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    /// Module this function belongs to (e.g., "IO", "Zest_Runtime"). Null for top-level.
    module_name: ?[]const u8 = null,
    /// Function name within its module, with arity suffix (e.g., "puts__1"). Used for per-module ZIR emission.
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

pub const LocalSet = struct {
    dest: LocalId,
    value: LocalId,
};

pub const MoveValue = struct {
    dest: LocalId,
    source: LocalId,
};

pub const ShareValue = struct {
    dest: LocalId,
    source: LocalId,
};

pub const ParamGet = struct {
    dest: LocalId,
    index: u32,
};

pub const AggregateInit = struct {
    dest: LocalId,
    elements: []const LocalId,
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
};

pub const ListGet = struct {
    dest: LocalId,
    list: LocalId,
    index: u32,
    element_type: ZigType = .i64,
};

pub const ListIsNotEmpty = struct {
    dest: LocalId,
    list: LocalId,
    element_type: ZigType = .i64,
};

pub const ListHeadTail = struct {
    dest: LocalId,
    list: LocalId,
    element_type: ZigType = .i64,
};

pub const MapHasKey = struct {
    dest: LocalId,
    map: LocalId,
    key: LocalId,
};

pub const MapGet = struct {
    dest: LocalId,
    map: LocalId,
    key: LocalId,
    default: LocalId,
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
pub const TryCallNamed = struct {
    dest: LocalId, // holds the optional result (?ReturnType)
    name: []const u8, // the __try function name (already suffixed)
    args: []const LocalId,
    arg_modes: []const ValueMode,
    input_local: LocalId, // the pipe input — passed to handler on null
    handler_instrs: []const Instruction, // handler body instructions
    handler_result: ?LocalId, // handler result local
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
    u8,
    u16,
    u32,
    u64,
    f16,
    f32,
    f64,
    usize,
    isize,
    string, // []const u8
    atom, // enum literal or interned string
    nil, // void or optional
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
// IR Builder — lowers HIR to IR
// ============================================================

pub const IrBuilder = struct {
    allocator: std.mem.Allocator,
    functions: std.ArrayList(Function),
    next_function_id: FunctionId,
    /// Separate ID counter for __try variants to avoid colliding with HIR group IDs.
    next_try_id: FunctionId = 10000,
    next_local: LocalId,
    next_label: LabelId,
    current_blocks: std.ArrayList(Block),
    current_instrs: std.ArrayList(Instruction),
    interner: *const ast.StringInterner,
    type_store: ?*const types_mod.TypeStore,
    known_local_types: std.AutoHashMap(LocalId, ZigType),
    current_module_prefix: ?[]const u8,
    known_function_names: std.StringHashMap(void),
    synthesized_type_defs: std.ArrayList(TypeDef),
    /// Maps function name → union dispatch info for call-site wrapping
    union_dispatch_map: std.StringHashMap(UnionDispatchInfo),
    /// Maps "func_name:arity" → wrapper name for default-arg resolution
    default_arg_wrappers: std.StringHashMap([]const u8),
    /// When true, decision tree failure nodes emit match_error_return instead of match_fail.
    /// Used when generating __try function variants for the ~> catch basin operator.
    try_mode: bool = false,
    /// The original function's arity (number of params excluding the handler).
    /// The handler param is at index current_try_arity in the __try variant.
    current_try_arity: u32 = 0,
    /// Set of function names that need __try variants (populated by error pipe analysis).
    /// Only functions in this set will get __try variants generated.
    try_variant_names: std.StringHashMap(void),
    /// Current function's declared param types (for param_get fallback when expr type is UNKNOWN).
    current_param_types: std.ArrayListUnmanaged(ZigType) = .empty,
    /// Maps mangled function names → @native binding strings (e.g., "String__length" → "String.length").
    /// Populated from @native attributes in the scope graph before building function bodies.

    pub const UnionDispatchInfo = struct {
        param_idx: u32,
        union_type_name: []const u8,
        /// Maps variant type name → variant name in the union
        variants: std.StringHashMap(void),
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) IrBuilder {
        return .{
            .allocator = allocator,
            .functions = .empty,
            .next_function_id = 0,
            .next_local = 0,
            .next_label = 0,
            .current_blocks = .empty,
            .current_instrs = .empty,
            .interner = interner,
            .type_store = null,
            .known_local_types = std.AutoHashMap(LocalId, ZigType).init(allocator),
            .current_module_prefix = null,
            .known_function_names = std.StringHashMap(void).init(allocator),
            .synthesized_type_defs = .empty,
            .union_dispatch_map = std.StringHashMap(UnionDispatchInfo).init(allocator),
            .default_arg_wrappers = std.StringHashMap([]const u8).init(allocator),
            .try_variant_names = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *IrBuilder) void {
        self.functions.deinit(self.allocator);
        self.current_blocks.deinit(self.allocator);
        self.current_instrs.deinit(self.allocator);
        self.known_local_types.deinit();
        self.synthesized_type_defs.deinit(self.allocator);
        self.union_dispatch_map.deinit();
        self.default_arg_wrappers.deinit();
        self.known_function_names.deinit();
    }

    /// Extract the list element ZigType from an HIR expression's type_id.
    /// Returns .i64 as default when type info is unavailable or not a list type.
    fn listElementTypeFromHir(self: *const IrBuilder, type_id: types_mod.TypeId) ZigType {
        const ts = self.type_store orelse return .i64;
        if (type_id >= ts.types.items.len) return .i64;
        const typ = ts.types.items[type_id];
        return switch (typ) {
            .list => |lt| typeIdToZigTypeWithStore(lt.element, self.type_store),
            else => .i64,
        };
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

    pub fn buildProgram(self: *IrBuilder, hir_program: *const hir_mod.Program) !Program {
        // First pass: register all qualified function names for bare call resolution
        for (hir_program.modules) |mod| {
            const module_prefix = self.moduleNameToPrefix(mod.name);
            for (mod.functions) |func_group| {
                const func_name = self.interner.get(func_group.name);
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ module_prefix, func_name, func_group.arity });
                try self.known_function_names.put(qualified, {});
            }
        }
        for (hir_program.top_functions) |func_group| {
            const func_name = self.interner.get(func_group.name);
            const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ func_name, func_group.arity });
            try self.known_function_names.put(qualified, {});
        }

        // Second pass: pre-scan for ~> error pipe chains to identify functions
        // that need __try variants. This must happen before building function bodies
        // so that __try variants are generated during buildFunctionGroup.
        for (hir_program.modules) |mod| {
            const module_prefix = self.moduleNameToPrefix(mod.name);
            for (mod.functions) |func_group| {
                for (func_group.clauses) |clause| {
                    try self.scanForTryVariantNames(clause.body, module_prefix);
                }
            }
        }
        for (hir_program.top_functions) |func_group| {
            for (func_group.clauses) |clause| {
                try self.scanForTryVariantNames(clause.body, null);
            }
        }



        // Fourth pass: build function bodies
        for (hir_program.modules) |mod| {
            const module_prefix = self.moduleNameToPrefix(mod.name);
            self.current_module_prefix = module_prefix;
            for (mod.functions) |func_group| {
                try self.buildFunctionGroup(&func_group);
            }
        }
        self.current_module_prefix = null;
        for (hir_program.top_functions) |func_group| {
            try self.buildFunctionGroup(&func_group);
        }

        // Build type definitions from TypeStore
        var type_defs: std.ArrayList(TypeDef) = .empty;
        if (self.type_store) |ts| {
            for (ts.types.items) |typ| {
                switch (typ) {
                    .struct_type => |st| {
                        var fields: std.ArrayList(StructFieldDef) = .empty;
                        for (st.fields) |field| {
                            const default_val: ?DefaultValue = if (field.default_expr) |expr| self.extractDefaultValue(expr) else null;
                            try fields.append(self.allocator, .{
                                .name = self.interner.get(field.name),
                                .type_expr = typeIdToZigTypeStrWithStore(field.type_id, self.type_store),
                                .default_value = default_val,
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
                                } else
                                    "void";
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

    fn buildFunctionGroup(self: *IrBuilder, group: *const hir_mod.FunctionGroup) !void {
        if (group.clauses.len == 0) return;

        // Skip generic (unmonomorphized) functions — they contain type variables
        // that can't be lowered to concrete IR types. Only the monomorphized copies
        // (produced by the monomorphization pass) should be compiled.
        // Emit a minimal stub to preserve function ID ordering.
        if (self.type_store) |ts| {
            if (isGenericHirGroup(ts, group)) {
                const func_id: FunctionId = group.id;
                if (self.next_function_id <= func_id) {
                    self.next_function_id = func_id + 1;
                }
                const gn2 = self.interner.get(group.name);
                if (std.mem.indexOf(u8, gn2, "mode") != null and std.mem.indexOf(u8, gn2, "IO") != null) {
                    std.debug.print("DEBUG SKIP GENERIC: {s} id={d}\n", .{ gn2, group.id });
                    if (group.clauses.len > 0) {
                        for (group.clauses[0].params) |p| {
                            std.debug.print("  param type_id={d} has_vars={}\n", .{ p.type_id, containsTypeVarInStore(ts, p.type_id) });
                        }
                        std.debug.print("  return={d} has_vars={}\n", .{ group.clauses[0].return_type, containsTypeVarInStore(ts, group.clauses[0].return_type) });
                    }
                }
                return;
            }
        }

        // @native bodyless functions: emit a minimal stub (no body instructions).
        // The actual call routing happens via call_builtin at call sites.
        // We still need to emit the function to preserve function ID ordering.

        const func_id: FunctionId = group.id;
        if (self.next_function_id <= func_id) {
            self.next_function_id = func_id + 1;
        }
        self.next_local = 0;
        self.next_label = 0;
        self.current_instrs = .empty;
        self.known_local_types.clearRetainingCapacity();
        self.current_param_types = .empty;

        // Use first clause for arity and return type
        const first_clause = &group.clauses[0];

        // Build params with generic names (__arg_N).
        // If all clauses agree on a param's type, use that type.
        // If clauses have different struct types, synthesize a union.
        // Otherwise fall back to anytype.
        var params: std.ArrayList(Param) = .empty;
        var union_param_idx: ?u32 = null;
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
        }

        // Reserve local indices used by tuple/struct bindings across all clauses.
        // These locals are defined inside guard_blocks (separate Zig scopes),
        // so top-level code must start allocating ABOVE this range.
        {
            var max_binding_local: u32 = 0;
            for (group.clauses) |clause| {
                for (clause.tuple_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
                for (clause.struct_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
                for (clause.list_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
                for (clause.cons_tail_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
                for (clause.binary_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
                for (clause.map_bindings) |binding| {
                    max_binding_local = @max(max_binding_local, binding.local_index + 1);
                }
            }
            self.next_local = max_binding_local;
        }

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
                try scrutinee_map.put(@intCast(i), param_local);
            }

            try self.lowerDecisionTreeForDispatch(decision, group.clauses, &scrutinee_map);
        }

        var entry_instrs: []const Instruction = try self.current_instrs.toOwnedSlice(self.allocator);

        const raw_name = if (group.name < self.interner.strings.items.len)
            self.interner.get(group.name)
        else
            "anonymous";
        const local_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ raw_name, group.arity });
        const name_str = if (self.current_module_prefix) |prefix|
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

        // Rewrite tail-recursive calls: replace call_named + ret/break with tail_call
        entry_instrs = try self.rewriteTailCalls(entry_instrs, name_str);

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

        try self.functions.append(self.allocator, .{
            .id = func_id,
            .name = name_str,
            .module_name = self.current_module_prefix,
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
        });

        // Default parameter wrappers disabled — defaults are inlined at call sites
        // by the ZIR builder's call_named handler using default_arg_info.
        if (false) { // @suppress: wrapper generation disabled
            const clause = &group.clauses[0];
            // Count trailing defaults
            var num_defaults: u32 = 0;
            var i: usize = clause.params.len;
            while (i > 0) {
                i -= 1;
                if (clause.params[i].default != null) {
                    num_defaults += 1;
                } else break;
            }

            if (num_defaults > 0) {
                const total_params = clause.params.len;
                // Generate one wrapper for each shorter arity
                var arity: usize = total_params - num_defaults;
                while (arity < total_params) : (arity += 1) {
                    // Use high-offset IDs for wrappers to avoid colliding
                    // with HIR group.id values used by normal functions.
                    const wrapper_id = self.next_try_id;
                    self.next_try_id += 1;

                    // Build param list for the wrapper (just the non-default params)
                    var wrapper_params: std.ArrayList(Param) = .empty;
                    for (0..arity) |pi| {
                        try wrapper_params.append(self.allocator, final_params[pi]);
                    }

                    // Build the forwarding call body:
                    // return full_func(arg0, arg1, ..., default_N, default_N+1, ...)
                    var wrapper_instrs: std.ArrayList(Instruction) = .empty;
                    var call_args: std.ArrayList(LocalId) = .empty;

                    var next_local: LocalId = 0;

                    // Forward the provided args
                    for (0..arity) |pi| {
                        const local = next_local;
                        next_local += 1;
                        try wrapper_instrs.append(self.allocator, .{
                            .param_get = .{ .dest = local, .index = @intCast(pi) },
                        });
                        try call_args.append(self.allocator, local);
                    }

                    // Lower default expressions for the remaining params
                    const saved_instrs = self.current_instrs;
                    const saved_next_local = self.next_local;
                    self.current_instrs = .empty;
                    self.next_local = next_local;

                    for (arity..total_params) |pi| {
                        const default_expr = clause.params[pi].default.?;
                        const default_local = try self.lowerExpr(default_expr);
                        try call_args.append(self.allocator, default_local);
                    }

                    // Collect the default-lowering instructions
                    for (self.current_instrs.items) |instr| {
                        try wrapper_instrs.append(self.allocator, instr);
                    }
                    self.current_instrs = saved_instrs;
                    self.next_local = saved_next_local;

                    // Emit the forwarding call
                    const result_local = next_local + @as(LocalId, @intCast(total_params - arity)) + @as(LocalId, @intCast(self.next_local - saved_next_local));
                    const wrapper_modes = try self.allocator.alloc(ValueMode, call_args.items.len);
                    for (wrapper_modes) |*mode| mode.* = .share;
                    try wrapper_instrs.append(self.allocator, .{
                        .call_named = .{
                            .dest = result_local,
                            .name = name_str,
                            .args = try call_args.toOwnedSlice(self.allocator),
                            .arg_modes = wrapper_modes,
                        },
                    });

                    // Return the result
                    if (return_type != .void) {
                        try wrapper_instrs.append(self.allocator, .{
                            .ret = .{ .value = result_local },
                        });
                    } else {
                        try wrapper_instrs.append(self.allocator, .{
                            .ret = .{ .value = null },
                        });
                    }

                    const wrapper_block = Block{
                        .label = 0,
                        .instructions = try wrapper_instrs.toOwnedSlice(self.allocator),
                    };

                    const wrapper_name = try std.fmt.allocPrint(self.allocator, "{s}__default_{d}", .{ name_str, arity });

                    try self.functions.append(self.allocator, .{
                        .id = wrapper_id,
                        .name = wrapper_name,
                        .scope_id = group.scope_id,
                        .arity = @intCast(arity),
                        .params = try wrapper_params.toOwnedSlice(self.allocator),
                        .return_type = return_type,
                        .body = try self.allocSlice(Block, &.{wrapper_block}),
                        .is_closure = false,
                        .captures = &.{},
                        .local_count = result_local + 1,
                    });

                    // Register for call-site resolution
                    const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ name_str, arity });
                    try self.default_arg_wrappers.put(key, wrapper_name);
                }
            }
        }

        // Generate __try variant for multi-clause functions that use decision tree dispatch.
        if (uses_decision_tree and group.clauses.len > 1 and self.try_variant_names.contains(name_str)) {
            // Use a high ID offset for __try variants to avoid colliding with
            // normal function group IDs (which come from HIR and are sequential).
            const try_func_id = self.next_try_id;
            self.next_try_id += 1;
            self.next_local = 0;
            self.next_label = 0;
            self.current_instrs = .empty;
            self.known_local_types.clearRetainingCapacity();

            // Reserve binding locals (same as normal function)
            {
                var max_binding_local: u32 = 0;
                for (group.clauses) |clause| {
                    for (clause.tuple_bindings) |binding| {
                        max_binding_local = @max(max_binding_local, binding.local_index + 1);
                    }
                    for (clause.struct_bindings) |binding| {
                        max_binding_local = @max(max_binding_local, binding.local_index + 1);
                    }
                    for (clause.list_bindings) |binding| {
                        max_binding_local = @max(max_binding_local, binding.local_index + 1);
                    }
                    for (clause.cons_tail_bindings) |binding| {
                        max_binding_local = @max(max_binding_local, binding.local_index + 1);
                    }
                    for (clause.binary_bindings) |binding| {
                        max_binding_local = @max(max_binding_local, binding.local_index + 1);
                    }
                }
                self.next_local = max_binding_local;
            }

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
            try self.functions.append(self.allocator, .{
                .id = try_func_id,
                .name = try_name,
                .module_name = self.current_module_prefix,
                .local_name = try_local_name,
                .scope_id = group.scope_id,
                .arity = group.arity,
                .params = try try_params.toOwnedSlice(self.allocator),
                .return_type = return_type,
                .body = try self.allocSlice(Block, &.{try_entry_block}),
                .is_closure = group.captures.len > 0,
                .captures = try try_captures.toOwnedSlice(self.allocator),
                .local_count = self.next_local,
            });
        }
    }

    /// Rewrite tail-recursive calls in a function's instruction list.
    /// Scans for patterns where the last operation before a return/break is a
    /// recursive call to the same function, and replaces them with tail_call.
    fn rewriteTailCalls(self: *IrBuilder, instrs: []const Instruction, func_name: []const u8) ![]const Instruction {
        var result: std.ArrayList(Instruction) = .empty;
        for (instrs) |instr| {
            switch (instr) {
                .switch_return => |sr| {
                    // Rewrite tail calls inside switch_return cases
                    var new_cases: std.ArrayList(ReturnCase) = .empty;
                    for (sr.cases) |case| {
                        const new_body = try self.rewriteTailCallsInBody(case.body_instrs, case.return_value, func_name);
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
                    const new_default = try self.rewriteTailCallsInBody(sr.default_instrs, sr.default_result, func_name);
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
                    // Check if the previous instruction is a recursive call
                    if (result.items.len > 0) {
                        const prev = &result.items[result.items.len - 1];
                        if (prev.* == .call_named) {
                            const cn = prev.call_named;
                            if (std.mem.eql(u8, cn.name, func_name)) {
                                if (r.value != null and r.value.? == cn.dest) {
                                    // Replace: call_named + ret → tail_call
                                    prev.* = .{ .tail_call = .{
                                        .name = cn.name,
                                        .args = cn.args,
                                    } };
                                    continue; // skip the ret
                                }
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
    ) !TailCallRewrite {
        if (body.len == 0 or return_value == null) return .{ .instrs = body, .rewritten = false };

        // Check if the last instruction is a call_named or call_direct to ourselves
        // and the return_value matches the call's dest
        const last = body[body.len - 1];

        // Handle call_direct: multi-clause recursive calls use call_direct.
        // If the dest matches return_value, this is a tail-position self-call.
        if (last == .call_direct) {
            const cd = last.call_direct;
            if (cd.dest == return_value.?) {
                // call_direct in a multi-clause function calling itself
                // Rewrite to tail_call using the function's own name.
                var new_body: std.ArrayList(Instruction) = .empty;
                for (body[0 .. body.len - 1]) |bi| {
                    try new_body.append(self.allocator, bi);
                }
                try new_body.append(self.allocator, .{
                    .tail_call = .{ .name = func_name, .args = cd.args },
                });
                return .{ .instrs = try new_body.toOwnedSlice(self.allocator), .rewritten = true };
            }
        }

        if (last == .call_named) {
            const cn = last.call_named;
            if (std.mem.eql(u8, cn.name, func_name) and cn.dest == return_value.?) {
                // Replace the call with tail_call, drop the return_value
                var new_body: std.ArrayList(Instruction) = .empty;
                for (body[0 .. body.len - 1]) |bi| {
                    try new_body.append(self.allocator, bi);
                }
                try new_body.append(self.allocator, .{
                    .tail_call = .{ .name = cn.name, .args = cn.args },
                });
                return .{ .instrs = try new_body.toOwnedSlice(self.allocator), .rewritten = true };
            }
        }
        return .{ .instrs = body, .rewritten = false };
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
                    .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize => {},
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
        const func_name = if (self.current_module_prefix) |prefix|
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
                                    const var_local = self.findBinaryVarLocal(clause, var_name);
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

    fn findBinaryVarLocal(self: *IrBuilder, clause: *const hir_mod.Clause, var_name: ast.StringId) LocalId {
        for (clause.binary_bindings) |binding| {
            if (binding.name == var_name) return binding.local_index;
        }
        _ = self;
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
    fn emitTupleBindings(self: *IrBuilder, clause: *const hir_mod.Clause) !void {
        for (clause.tuple_bindings) |binding| {
            // Get the param (the tuple)
            const tuple_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{
                .param_get = .{ .dest = tuple_local, .index = binding.param_index },
            });
            // Extract the element into the binding's local index
            try self.current_instrs.append(self.allocator, .{
                .index_get = .{
                    .dest = binding.local_index,
                    .object = tuple_local,
                    .index = binding.element_index,
                },
            });
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
            try self.current_instrs.append(self.allocator, .{
                .field_get = .{
                    .dest = binding.local_index,
                    .object = struct_local,
                    .field = self.interner.get(binding.field_name),
                },
            });
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
            // Lower the key expression to get the key local
            const key_local = try self.lowerExpr(binding.key_expr);
            // Create a default value (nil/0)
            const default_local = self.next_local;
            self.next_local += 1;
            try self.current_instrs.append(self.allocator, .{ .const_nil = default_local });
            // Extract the value via map_get
            try self.current_instrs.append(self.allocator, .{
                .map_get = .{
                    .dest = binding.local_index,
                    .map = map_local,
                    .key = key_local,
                    .default = default_local,
                },
            });
        }
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
                                try self.current_instrs.append(self.allocator, .{
                                    .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                                });
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
                // Tuple element bindings are handled by bind nodes in the
                // decision tree path, which resolve to the correct decomposed locals.
                for (arm.bindings) |binding| {
                    if (binding.kind == .scrutinee) {
                        const scr_local = scrutinee_map.get(0) orelse 0;
                        try self.current_instrs.append(self.allocator, .{
                            .local_get = .{ .dest = binding.local_index, .source = scr_local },
                        });
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
                const guard_local = try self.lowerGuardExpr(guard_node.condition, scrutinee_map);
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
                    // Use stored element scrutinee IDs directly — avoids the
                    // fragile heuristic of walking the decision tree which breaks
                    // when wildcard patterns skip bind nodes.
                    const elem_id = if (i < ct.element_scrutinee_ids.len)
                        ct.element_scrutinee_ids[i]
                    else
                        findParamGetIdInDecision(ct.success, i);
                    try scrutinee_map.put(elem_id, elem_local);
                }
                try self.lowerDecisionTreeForCase(ct.success, case_arms, scrutinee_map, 0);
                const success_body = try self.current_instrs.toOwnedSlice(self.allocator);
                self.current_instrs = saved;
                try self.current_instrs.append(self.allocator, .{
                    .guard_block = .{ .condition = type_check_local, .body = success_body },
                });
                try self.lowerDecisionTreeForCase(ct.failure, case_arms, scrutinee_map, 0);
            },
            .check_list => |cl| {
                const scrutinee_local = self.resolveScrutinee(cl.scrutinee, scrutinee_map);
                const elem_type = self.listElementTypeForLocal(scrutinee_local);
                const len_check_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_len_check = .{ .dest = len_check_local, .scrutinee = scrutinee_local, .expected_len = cl.expected_length, .element_type = elem_type },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                while (i < cl.expected_length) : (i += 1) {
                    const elem_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_get = .{ .dest = elem_local, .list = scrutinee_local, .index = i, .element_type = elem_type },
                    });
                    try self.known_local_types.put(elem_local, elem_type);
                    try scrutinee_map.put(findParamGetIdInDecision(cl.success, i), elem_local);
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
                const not_empty_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_is_not_empty = .{ .dest = not_empty_local, .list = scrutinee_local, .element_type = elem_type },
                });
                const saved = self.current_instrs;
                self.current_instrs = .empty;
                var i: u32 = 0;
                var current_list = scrutinee_local;
                while (i < clc.head_count) : (i += 1) {
                    const head_local = self.next_local;
                    self.next_local += 1;
                    try self.current_instrs.append(self.allocator, .{
                        .list_head = .{ .dest = head_local, .list = current_list, .element_type = elem_type },
                    });
                    try self.known_local_types.put(head_local, elem_type);
                    try scrutinee_map.put(clc.head_scrutinee_ids[i], head_local);
                    if (i + 1 < clc.head_count) {
                        const next_list = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .list_tail = .{ .dest = next_list, .list = current_list, .element_type = elem_type },
                        });
                        try self.known_local_types.put(next_list, scrutinee_list_type);
                        current_list = next_list;
                    }
                }
                const tail_local = self.next_local;
                self.next_local += 1;
                try self.current_instrs.append(self.allocator, .{
                    .list_tail = .{ .dest = tail_local, .list = current_list, .element_type = elem_type },
                });
                try self.known_local_types.put(tail_local, scrutinee_list_type);
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
                            try self.current_instrs.append(self.allocator, .{
                                .local_get = .{ .dest = binding.local_index, .source = scrutinee_local },
                            });
                            break;
                        }
                    }
                }
                try self.lowerDecisionTreeForCase(bind_node.next, case_arms, scrutinee_map, 0);
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
                const guard_local = try self.lowerGuardExpr(guard_node.condition, scrutinee_map);
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
                    try scrutinee_map.put(clc.head_scrutinee_ids[i], head_local);
                    if (i + 1 < clc.head_count) {
                        const next_list = self.next_local;
                        self.next_local += 1;
                        try self.current_instrs.append(self.allocator, .{
                            .list_tail = .{ .dest = next_list, .list = current_list, .element_type = elem_type },
                        });
                        try self.known_local_types.put(next_list, scrutinee_list_type);
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

                // For multi-clause dispatch, check if any segments have string literal
                // prefixes that need guard blocks to differentiate clauses
                var has_prefix_dispatch = false;
                for (clauses) |clause| {
                    for (clause.params) |param| {
                        if (param.pattern) |pat| {
                            if (pat.* == .binary_match) {
                                for (pat.binary_match.segments) |seg| {
                                    if (seg.string_literal != null) {
                                        has_prefix_dispatch = true;
                                        break;
                                    }
                                }
                            }
                        }
                        if (has_prefix_dispatch) break;
                    }
                    if (has_prefix_dispatch) break;
                }

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
                    try self.current_instrs.append(self.allocator, .{
                        .local_get = .{ .dest = dest, .source = local },
                    });
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
                };
                try self.current_instrs.append(self.allocator, .{
                    .binary_op = .{ .dest = dest, .op = ir_op, .lhs = lhs, .rhs = rhs },
                });
                return dest;
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
                .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .isize, .usize => true,
                else => false,
            },
            .float => switch (known_type) {
                .f16, .f32, .f64 => true,
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
                    last_local = ls.index;
                },
                .function_group => |group| {
                    const saved_instrs = self.current_instrs;
                    const saved_next_local = self.next_local;
                    const saved_known_local_types = self.known_local_types;
                    self.current_instrs = .empty;
                    self.known_local_types = std.AutoHashMap(LocalId, ZigType).init(self.allocator);
                    defer {
                        self.known_local_types.deinit();
                        self.known_local_types = saved_known_local_types;
                    }
                    try self.buildFunctionGroup(group);
                    self.current_instrs = saved_instrs;
                    self.next_local = saved_next_local;
                },
            }
        }
        return last_local;
    }

    fn isArcManagedType(self: *const IrBuilder, type_id: hir_mod.TypeId) bool {
        const store = self.type_store orelse return false;
        return store.getType(type_id) == .opaque_type;
    }

    /// Pre-scan HIR block to find error_pipe expressions with
    /// is_dispatched steps, registering their function names in try_variant_names.
    /// This runs before function bodies are built so __try variants are generated.
    fn scanForTryVariantNames(self: *IrBuilder, block: *const hir_mod.Block, module_prefix: ?[]const u8) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.scanExprForTryVariants(expr, module_prefix),
                .local_set => |ls| try self.scanExprForTryVariants(ls.value, module_prefix),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanForTryVariantNames(clause.body, module_prefix);
                    }
                },
            }
        }
    }

    fn scanExprForTryVariants(self: *IrBuilder, expr: *const hir_mod.Expr, module_prefix: ?[]const u8) error{OutOfMemory}!void {
        switch (expr.kind) {
            .error_pipe => |ep| {
                for (ep.steps) |step| {
                    if (step.is_dispatched and step.expr.kind == .call) {
                        const call = step.expr.kind.call;
                        // +1 for the piped value which becomes the first argument
                        const call_arity = call.args.len + 1;
                        const call_name_str = switch (call.target) {
                            .named => |n| blk: {
                                if (n.module) |mod| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, n.name, call_arity });
                                if (module_prefix) |prefix| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, n.name, call_arity });
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ n.name, call_arity });
                            },
                            else => continue,
                        };
                        try self.try_variant_names.put(call_name_str, {});
                    }
                    // Recurse into step expressions
                    try self.scanExprForTryVariants(step.expr, module_prefix);
                }
                // Recurse into handler
                try self.scanExprForTryVariants(ep.handler, module_prefix);
            },
            .call => |c| {
                for (c.args) |arg| {
                    try self.scanExprForTryVariants(arg.expr, module_prefix);
                }
            },
            .branch => |br| {
                try self.scanExprForTryVariants(br.condition, module_prefix);
                try self.scanBlockForTryVariants(br.then_block, module_prefix);
                if (br.else_block) |eb| try self.scanBlockForTryVariants(eb, module_prefix);
            },
            .case => |ce| {
                try self.scanExprForTryVariants(ce.scrutinee, module_prefix);
                for (ce.arms) |arm| {
                    try self.scanBlockForTryVariants(arm.body, module_prefix);
                }
            },
            .binary => |b| {
                try self.scanExprForTryVariants(b.lhs, module_prefix);
                try self.scanExprForTryVariants(b.rhs, module_prefix);
            },
            .unary => |u| {
                try self.scanExprForTryVariants(u.operand, module_prefix);
            },
            .union_init => |ui| {
                try self.scanExprForTryVariants(ui.value, module_prefix);
            },
            .block => |blk| {
                try self.scanBlockForTryVariants(&blk, module_prefix);
            },
            else => {},
        }
    }

    fn scanBlockForTryVariants(self: *IrBuilder, block: *const hir_mod.Block, module_prefix: ?[]const u8) error{OutOfMemory}!void {
        for (block.stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| try self.scanExprForTryVariants(expr, module_prefix),
                .local_set => |ls| try self.scanExprForTryVariants(ls.value, module_prefix),
                .function_group => |fg| {
                    for (fg.clauses) |clause| {
                        try self.scanForTryVariantNames(clause.body, module_prefix);
                    }
                },
            }
        }
    }

    fn lowerExpr(self: *IrBuilder, expr: *const hir_mod.Expr) anyerror!LocalId {
        // Case expressions need binding locals reserved before dest allocation
        // to avoid shadowing conflicts in the generated Zig.
        if (expr.kind == .case) {
            return self.lowerCaseExpr(expr.kind.case);
        }

        const dest = self.next_local;
        self.next_local += 1;

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
                try self.current_instrs.append(self.allocator, .{
                    .local_get = .{ .dest = dest, .source = idx },
                });
                if (self.known_local_types.get(idx)) |src_type| {
                    try self.known_local_types.put(dest, src_type);
                }
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
            },
            .binary => |bin| {
                const lhs = try self.lowerExpr(bin.lhs);
                const rhs = try self.lowerExpr(bin.rhs);
                // Detect string comparison — Zig needs std.mem.eql, not ==
                const lhs_is_string = if (self.known_local_types.get(lhs)) |t| t == .string else
                    (bin.lhs.type_id == types_mod.TypeStore.STRING);
                const rhs_is_string = if (self.known_local_types.get(rhs)) |t| t == .string else
                    (bin.rhs.type_id == types_mod.TypeStore.STRING);
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
                for (call.args) |arg| {
                    const arg_local = try self.lowerExpr(arg.expr);
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
                            .call_direct = .{ .dest = dest, .function = dc.function_group_id, .args = lowered_args, .arg_modes = lowered_modes },
                        });
                    },
                    .named => |nc| {
                        const call_arity = call.args.len;
                        // For module-qualified calls, try exact arity first, then higher
                        // arities for functions with default parameters.
                        const resolved_name = if (nc.module) |mod| blk: {
                            var try_a: usize = call_arity;
                            while (try_a <= call_arity + 4) : (try_a += 1) {
                                const candidate = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, nc.name, try_a });
                                if (self.known_function_names.contains(candidate)) break :blk candidate;
                            }
                            break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, nc.name, call_arity });
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
                        try self.current_instrs.append(self.allocator, .{
                            .call_closure = .{ .dest = dest, .callee = callee_local, .args = lowered_args, .arg_modes = lowered_modes, .return_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store) },
                        });
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
                                        // Enum values use u32 — route to MapOf(u32, u32)
                                        break :blk try std.fmt.allocPrint(self.allocator, "MapOfU32Val.{s}", .{method});
                                    } else {
                                        const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                        break :blk try std.fmt.allocPrint(self.allocator, "MapOf:{s}:{s}.{s}", .{ key_name, val_zig.struct_ref, method });
                                    }
                                }
                                // For nested map/list value types, encode for generic dispatch
                                if (std.meta.activeTag(val_zig) == .map or std.meta.activeTag(val_zig) == .list) {
                                    const key_name = if (std.meta.activeTag(key_zig) == .atom) "u32" else if (std.meta.activeTag(key_zig) == .string) "str" else "u32";
                                    break :blk try std.fmt.allocPrint(self.allocator, "MapOfNested:{s}:{s}.{s}", .{ key_name, @tagName(std.meta.activeTag(val_zig)), method });
                                }
                                const map_name = getMapName(key_zig, val_zig);
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ map_name, method });
                            }
                            break :blk name;
                        } else name;

                        const resolved_name = if (std.mem.startsWith(u8, map_resolved, "List.") and lowered_args.len > 0) blk: {
                            const first_arg_type = self.known_local_types.get(lowered_args[0]) orelse .any;
                            if (std.meta.activeTag(first_arg_type) == .list) {
                                const elem_zig = first_arg_type.list.*;
                                const method = map_resolved["List.".len..];
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
                                        // Enum lists use ListOf(u32) — encode for generic dispatch
                                        break :blk try std.fmt.allocPrint(self.allocator, "ListOfU32.{s}", .{method});
                                    } else {
                                        break :blk try std.fmt.allocPrint(self.allocator, "ListOf:{s}.{s}", .{ elem_zig.struct_ref, method });
                                    }
                                }
                                if (std.meta.activeTag(elem_zig) == .list) {
                                    // Nested list: ListOf(?*const ListOf(T))
                                    // Use "ListOfNested:inner_type.method" encoding
                                    break :blk try std.fmt.allocPrint(self.allocator, "ListOfNested:{s}.{s}", .{ @tagName(elem_zig.list.*), method });
                                }
                                const cell_name = getListName(elem_zig);
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ cell_name, method });
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
                try self.current_instrs.append(self.allocator, .{
                    .tuple_init = .{ .dest = dest, .elements = elements },
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
                const elem_type = self.listElementTypeFromHir(expr.type_id);
                try self.current_instrs.append(self.allocator, .{
                    .list_init = .{ .dest = dest, .elements = elements, .element_type = elem_type },
                });
                const list_zig_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
                try self.known_local_types.put(dest, list_zig_type);
            },
            .list_cons => |lc| {
                const head = try self.lowerExpr(lc.head);
                const tail = try self.lowerExpr(lc.tail);
                const elem_type = self.listElementTypeFromHir(expr.type_id);
                try self.current_instrs.append(self.allocator, .{
                    .list_cons = .{ .dest = dest, .head = head, .tail = tail, .element_type = elem_type },
                });
                const list_zig_type = typeIdToZigTypeWithStore(expr.type_id, self.type_store);
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
                        },
                        .function_group => |group| {
                            // Anonymous functions and nested functions defined
                            // inside block expressions must be built as IR functions.
                            const saved_instrs = self.current_instrs;
                            const saved_next_local = self.next_local;
                            const saved_known_local_types = self.known_local_types;
                            self.current_instrs = .empty;
                            self.known_local_types = std.AutoHashMap(LocalId, ZigType).init(self.allocator);
                            defer {
                                self.known_local_types.deinit();
                                self.known_local_types = saved_known_local_types;
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
            },
            .error_pipe => |ep| {
                // Lower error pipe as FLAT sequence.
                // Every function call in the pipe uses its __try variant if multi-clause.
                // If __try returns null, the unmatched input flows to the handler.
                if (ep.steps.len == 0) return dest;

                // Store the handler HIR expression for deferred evaluation at each step.
                const handler_hir = ep.handler;
                var pipe_val = try self.lowerExpr(ep.steps[0].expr);

                // Process remaining steps at the top level
                for (ep.steps[1..]) |step| {
                    if (step.expr.kind == .call) {
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
                        const call_name_str = switch (call.target) {
                            .named => |n| blk: {
                                if (n.module) |mod| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ mod, n.name, ep_call_arity });
                                if (self.current_module_prefix) |prefix| break :blk try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, n.name, ep_call_arity });
                                break :blk try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ n.name, ep_call_arity });
                            },
                            else => "unknown",
                        };

                        if (step.is_dispatched) {
                            // Multi-clause: call __try variant (returns ?ReturnType).
                            // On null: run handler with input value, short-circuit.
                            const try_name = try std.fmt.allocPrint(self.allocator, "{s}__try", .{call_name_str});
                            try self.try_variant_names.put(call_name_str, {});

                            // Lower handler with pipe_val as the scrutinee (__err)
                            const saved = self.current_instrs;
                            self.current_instrs = .empty;
                            // Assign __err = pipe_val (the input that failed to match)
                            const err_local = self.next_local;
                            self.next_local += 1;
                            try self.current_instrs.append(self.allocator, .{
                                .local_set = .{ .dest = err_local, .value = pipe_val },
                            });
                            // Lower handler expression with __err available
                            const handler_result = try self.lowerExpr(handler_hir);
                            const handler_instrs = try self.current_instrs.toOwnedSlice(self.allocator);
                            self.current_instrs = saved;

                            try self.current_instrs.append(self.allocator, .{
                                .try_call_named = .{
                                    .dest = call_dest,
                                    .name = try_name,
                                    .args = final_args,
                                    .arg_modes = modes,
                                    .input_local = pipe_val,
                                    .handler_instrs = handler_instrs,
                                    .handler_result = handler_result,
                                },
                            });
                            pipe_val = call_dest;
                        } else {
                            // Single-clause function: always matches, regular call
                            try self.current_instrs.append(self.allocator, .{
                                .call_named = .{ .dest = call_dest, .name = call_name_str, .args = final_args, .arg_modes = modes },
                            });
                            pipe_val = call_dest;
                        }
                    }
                }

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
                try self.current_instrs.append(self.allocator, .{
                    .field_get = .{
                        .dest = dest,
                        .object = obj,
                        .field = self.interner.get(fg.field),
                    },
                });
            },
            .map_init => |entries| {
                var ir_entries: std.ArrayList(MapEntry) = .empty;
                // Infer key/value types from the first entry's HIR type
                var key_type: ZigType = .atom;
                var value_type: ZigType = .i64;
                if (entries.len > 0) {
                    key_type = typeIdToZigTypeWithStore(entries[0].key.type_id, self.type_store);
                    value_type = typeIdToZigTypeWithStore(entries[0].value.type_id, self.type_store);
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
    /// Resolution order: current module → Kernel → top-level → bare name.
    /// Also checks higher arities for functions with default parameters.
    fn resolveBareCall(self: *IrBuilder, name: []const u8, arity: u32) ![]const u8 {
        // Try exact arity first, then higher arities (for default params)
        var try_arity: u32 = arity;
        while (try_arity <= arity + 4) : (try_arity += 1) {
            // 1. Current module function
            if (self.current_module_prefix) |prefix| {
                const qualified = try std.fmt.allocPrint(self.allocator, "{s}__{s}__{d}", .{ prefix, name, try_arity });
                if (self.known_function_names.contains(qualified)) return qualified;
            }
            // 2. Top-level function (bare name with arity)
            {
                const top_name = try std.fmt.allocPrint(self.allocator, "{s}__{d}", .{ name, try_arity });
                if (self.known_function_names.contains(top_name)) return top_name;
            }
        }
        // 4. Keep bare name — Zig compiler will error
        return name;
    }

    /// Convert an ast.ModuleName to a prefix string for function naming.
    /// Single-part: "IO". Multi-part: "IO_File".
    fn moduleNameToPrefix(self: *IrBuilder, name: ast.ModuleName) []const u8 {
        if (name.parts.len == 1) {
            return self.interner.get(name.parts[0]);
        }
        var buf: std.ArrayList(u8) = .empty;
        for (name.parts, 0..) |part, i| {
            if (i > 0) buf.appendSlice(self.allocator, "_") catch return self.interner.get(name.parts[0]);
            buf.appendSlice(self.allocator, self.interner.get(part)) catch return self.interner.get(name.parts[0]);
        }
        return buf.toOwnedSlice(self.allocator) catch return self.interner.get(name.parts[0]);
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

/// Map a list element ZigType to the runtime List variant name.
fn getMapName(key_type: ZigType, value_type: ZigType) []const u8 {
    if (std.meta.activeTag(key_type) == .atom) {
        return switch (std.meta.activeTag(value_type)) {
            .string => "MapAtomString",
            .bool_type => "MapAtomBool",
            .f64 => "MapAtomFloat",
            else => "MapAtomInt",
        };
    }
    if (std.meta.activeTag(key_type) == .string) {
        return switch (std.meta.activeTag(value_type)) {
            .string => "MapStringString",
            .f64 => "MapStringFloat",
            else => "MapStringInt",
        };
    }
    return "MapAtomInt";
}

fn getListName(element_type: ZigType) []const u8 {
    return switch (std.meta.activeTag(element_type)) {
        .string => "StringList",
        .bool_type => "BoolList",
        .f64 => "FloatList",
        .atom => "AtomList",
        else => "List",
    };
}

/// Check if a HIR function group is generic (has unresolved type variables in params/return).
fn isGenericHirGroup(store: *const types_mod.TypeStore, group: *const hir_mod.FunctionGroup) bool {
    if (group.clauses.len == 0) return false;
    const first_clause = &group.clauses[0];
    for (first_clause.params) |param| {
        if (containsTypeVarInStore(store, param.type_id)) return true;
    }
    if (containsTypeVarInStore(store, first_clause.return_type)) return true;
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
            // Protocol constraints are always generic — they need dispatch resolution
            if (pc.type_params.len > 0) {
                for (pc.type_params) |tp| {
                    if (containsTypeVarInStore(store, tp)) return true;
                }
            }
            // Bare protocol constraint (no type params) is still generic
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
        types_mod.TypeStore.I64 => .i64,
        types_mod.TypeStore.I32 => .i32,
        types_mod.TypeStore.I16 => .i16,
        types_mod.TypeStore.I8 => .i8,
        types_mod.TypeStore.U64 => .u64,
        types_mod.TypeStore.U32 => .u32,
        types_mod.TypeStore.U16 => .u16,
        types_mod.TypeStore.U8 => .u8,
        types_mod.TypeStore.F64 => .f64,
        types_mod.TypeStore.F32 => .f32,
        types_mod.TypeStore.F16 => .f16,
        types_mod.TypeStore.USIZE => .usize,
        types_mod.TypeStore.ISIZE => .isize,
        else => {
            // Try to resolve user-defined struct/enum/union types
            if (type_store) |ts| {
                if (type_id < ts.types.items.len) {
                    const typ = ts.types.items[type_id];
                    switch (typ) {
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

fn typeIdToZigTypeStr(type_id: types_mod.TypeId) []const u8 {
    return typeIdToZigTypeStrWithStore(type_id, null);
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
        .u8 => "u8",
        .u16 => "u16",
        .u32 => "u32",
        .u64 => "u64",
        .f16 => "f16",
        .f32 => "f32",
        .f64 => "f64",
        .usize => "usize",
        .isize => "isize",
        .string => "[]const u8",
        .atom => "[]const u8",
        .nil => "?void",
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
        \\pub module Test {
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
        \\pub module Test {
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
        \\pub module Test {
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

    const apply_clause = program.modules[0].items[0].function.clauses[0];
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
        \\pub module Test {
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
        \\pub module Test {
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

    const apply_clause = program.modules[0].items[1].function.clauses[0];
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
        \\pub module Test {
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

    const run_clause = program.modules[0].items[2].function.clauses[0];
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
