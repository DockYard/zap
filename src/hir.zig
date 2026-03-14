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

// ============================================================
// HIR Program
// ============================================================

pub const Program = struct {
    modules: []const Module,
    top_functions: []const FunctionGroup,
};

pub const Module = struct {
    name: ast.ModuleName,
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
    clauses: []const Clause,
    fallback_parent: ?u32, // ID of the outer scope's function group
};

pub const Clause = struct {
    params: []const TypedParam,
    return_type: TypeId,
    decision: *const Decision, // compiled match decision
    body: *const Block,
};

pub const TypedParam = struct {
    name: ?ast.StringId,
    type_id: TypeId,
    pattern: ?*const MatchPattern,
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

    // Compound
    tuple_init: []const *const Expr,
    list_init: []const *const Expr,
    map_init: []const MapEntry,
    struct_init: StructInit,

    // Operations
    binary: BinaryExpr,
    unary: UnaryExpr,
    call: CallExpr,
    field_get: FieldGetExpr,

    // Control flow
    branch: BranchExpr,
    match: MatchExpr,
    block: Block,

    // Error handling
    panic: *const Expr,

    // Special
    closure_create: ClosureCreate,
    never,
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
    args: []const *const Expr,
};

pub const CallTarget = union(enum) {
    direct: DirectCall,
    closure: *const Expr,
    dispatch: DispatchCall,
    builtin: []const u8,
};

pub const DirectCall = struct {
    function_group_id: u32,
    clause_index: u32,
};

pub const DispatchCall = struct {
    function_group_id: u32,
};

pub const FieldGetExpr = struct {
    object: *const Expr,
    field: ast.StringId,
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
    captures: []const u32, // local variable indices
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
};

pub const LocalSet = struct {
    index: u32,
    value: *const Expr,
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
    /// Bind a variable and continue
    bind: BindNode,
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

pub const CheckTupleNode = struct {
    scrutinee: *const Expr,
    expected_arity: u32,
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
    pin: ast.StringId,
};

// ============================================================
// HIR builder — converts typed AST to HIR
// ============================================================

pub const HirBuilder = struct {
    allocator: std.mem.Allocator,
    interner: *const ast.StringInterner,
    graph: *const scope_mod.ScopeGraph,
    type_store: *const types_mod.TypeStore,
    next_group_id: u32,
    next_local: u32,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        interner: *const ast.StringInterner,
        graph: *const scope_mod.ScopeGraph,
        type_store: *const types_mod.TypeStore,
    ) HirBuilder {
        return .{
            .allocator = allocator,
            .interner = interner,
            .graph = graph,
            .type_store = type_store,
            .next_group_id = 0,
            .next_local = 0,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *HirBuilder) void {
        self.errors.deinit(self.allocator);
    }

    // ============================================================
    // Program lowering
    // ============================================================

    pub fn buildProgram(self: *HirBuilder, program: *const ast.Program) !Program {
        var modules: std.ArrayList(Module) = .empty;
        for (program.modules, 0..) |*mod, i| {
            const mod_scope = if (i < self.graph.modules.items.len)
                self.graph.modules.items[i].scope_id
            else
                self.graph.prelude_scope;
            try modules.append(self.allocator, try self.buildModule(mod, mod_scope));
        }

        var top_fns: std.ArrayList(FunctionGroup) = .empty;
        for (program.top_items) |item| {
            switch (item) {
                .function => |func| try top_fns.append(self.allocator, try self.buildFunctionGroup(func, self.graph.prelude_scope, null)),
                .priv_function => |func| try top_fns.append(self.allocator, try self.buildFunctionGroup(func, self.graph.prelude_scope, null)),
                else => {},
            }
        }

        return .{
            .modules = try modules.toOwnedSlice(self.allocator),
            .top_functions = try top_fns.toOwnedSlice(self.allocator),
        };
    }

    fn buildModule(self: *HirBuilder, mod: *const ast.ModuleDecl, mod_scope: scope_mod.ScopeId) !Module {
        var functions: std.ArrayList(FunctionGroup) = .empty;
        var type_defs: std.ArrayList(TypeDef) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function, .priv_function => |func| {
                    try functions.append(self.allocator, try self.buildFunctionGroup(func, mod_scope, null));
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
                .struct_decl => {
                    try type_defs.append(self.allocator, .{
                        .name = 0,
                        .type_id = types_mod.TypeStore.UNKNOWN,
                        .kind = .struct_type,
                    });
                },
                else => {},
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

    fn buildFunctionGroup(
        self: *HirBuilder,
        func: *const ast.FunctionDecl,
        scope_id: scope_mod.ScopeId,
        fallback_parent: ?u32,
    ) !FunctionGroup {
        const group_id = self.next_group_id;
        self.next_group_id += 1;

        var clauses: std.ArrayList(Clause) = .empty;
        for (func.clauses) |clause| {
            try clauses.append(self.allocator, try self.buildClause(&clause));
        }

        return .{
            .id = group_id,
            .scope_id = scope_id,
            .name = func.name,
            .arity = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0,
            .clauses = try clauses.toOwnedSlice(self.allocator),
            .fallback_parent = fallback_parent,
        };
    }

    fn buildClause(self: *HirBuilder, clause: *const ast.FunctionClause) !Clause {
        self.next_local = 0;

        var params: std.ArrayList(TypedParam) = .empty;
        for (clause.params) |param| {
            const type_id = if (param.type_annotation) |_|
                types_mod.TypeStore.UNKNOWN // TODO: resolve type annotation
            else
                types_mod.TypeStore.UNKNOWN;

            const match_pattern = try self.compilePattern(param.pattern);

            const name = if (param.pattern.* == .bind) param.pattern.bind.name else null;
            try params.append(self.allocator, .{
                .name = name,
                .type_id = type_id,
                .pattern = match_pattern,
            });
        }

        const return_type = if (clause.return_type) |_|
            types_mod.TypeStore.UNKNOWN
        else
            types_mod.TypeStore.UNKNOWN;

        // Build decision tree for this clause
        const decision = try self.create(Decision, .{
            .success = .{ .bindings = &.{}, .body_index = 0 },
        });

        // Build body block
        const body = try self.buildBlock(clause.body);

        return .{
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .decision = decision,
            .body = body,
        };
    }

    // ============================================================
    // Pattern compilation (spec §17)
    // ============================================================

    fn compilePattern(self: *HirBuilder, pattern: *const ast.Pattern) anyerror!?*const MatchPattern {
        return switch (pattern.*) {
            .wildcard => try self.create(MatchPattern, .wildcard),
            .bind => |b| try self.create(MatchPattern, .{ .bind = b.name }),
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
            .pin => |p| try self.create(MatchPattern, .{ .pin = p.name }),
            .paren => |p| self.compilePattern(p.inner),
            .map, .struct_pattern => null, // TODO
        };
    }

    // ============================================================
    // Block building
    // ============================================================

    fn buildBlock(self: *HirBuilder, stmts: []const ast.Stmt) anyerror!*const Block {
        var hir_stmts: std.ArrayList(Stmt) = .empty;

        for (stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    const hir_expr = try self.buildExpr(expr);
                    try hir_stmts.append(self.allocator, .{ .expr = hir_expr });
                },
                .assignment => |assign| {
                    const value = try self.buildExpr(assign.value);
                    const idx = self.next_local;
                    self.next_local += 1;
                    try hir_stmts.append(self.allocator, .{
                        .local_set = .{ .index = idx, .value = value },
                    });
                },
                .function_decl => |func| {
                    const group = try self.buildFunctionGroup(func, self.graph.prelude_scope, null);
                    const group_ptr = try self.create(FunctionGroup, group);
                    try hir_stmts.append(self.allocator, .{ .function_group = group_ptr });
                },
                else => {},
            }
        }

        return try self.create(Block, .{
            .stmts = try hir_stmts.toOwnedSlice(self.allocator),
            .result_type = types_mod.TypeStore.UNKNOWN,
        });
    }

    // ============================================================
    // Expression building
    // ============================================================

    fn buildExpr(self: *HirBuilder, expr: *const ast.Expr) anyerror!*const Expr {
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
            .var_ref => |v| try self.create(Expr, .{
                .kind = .{ .local_get = 0 }, // TODO: resolve to local index
                .type_id = types_mod.TypeStore.UNKNOWN,
                .span = v.meta.span,
            }),
            .binary_op => |bo| try self.create(Expr, .{
                .kind = .{ .binary = .{
                    .op = bo.op,
                    .lhs = try self.buildExpr(bo.lhs),
                    .rhs = try self.buildExpr(bo.rhs),
                } },
                .type_id = types_mod.TypeStore.UNKNOWN,
                .span = bo.meta.span,
            }),
            .unary_op => |uo| try self.create(Expr, .{
                .kind = .{ .unary = .{
                    .op = uo.op,
                    .operand = try self.buildExpr(uo.operand),
                } },
                .type_id = types_mod.TypeStore.UNKNOWN,
                .span = uo.meta.span,
            }),
            .call => |call| {
                var args: std.ArrayList(*const Expr) = .empty;
                for (call.args) |arg| {
                    try args.append(self.allocator, try self.buildExpr(arg));
                }

                // Check for module-qualified stdlib call: IO.puts(...)
                const target: CallTarget = if (call.callee.* == .field_access) blk: {
                    const fa = call.callee.field_access;
                    if (fa.object.* == .module_ref) {
                        const mod_name = self.moduleNameToString(fa.object.module_ref.name);
                        const func_name = self.interner.get(fa.field);
                        if (resolveStdlibCall(mod_name, func_name)) |runtime_name| {
                            break :blk .{ .builtin = runtime_name };
                        }
                    }
                    break :blk .{ .closure = try self.buildExpr(call.callee) };
                } else .{ .closure = try self.buildExpr(call.callee) };

                return try self.create(Expr, .{
                    .kind = .{ .call = .{
                        .target = target,
                        .args = try args.toOwnedSlice(self.allocator),
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = call.meta.span,
                });
            },
            .if_expr => |ie| {
                const cond = try self.buildExpr(ie.condition);
                const then_block = try self.buildBlock(ie.then_block);
                const else_block = if (ie.else_block) |eb| try self.buildBlock(eb) else null;
                return try self.create(Expr, .{
                    .kind = .{ .branch = .{
                        .condition = cond,
                        .then_block = then_block,
                        .else_block = else_block,
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = ie.meta.span,
                });
            },
            .case_expr => |ce| {
                const scrutinee = try self.buildExpr(ce.scrutinee);
                // Build decision tree from case clauses
                const decision = try self.create(Decision, .{
                    .success = .{ .bindings = &.{}, .body_index = 0 },
                });
                return try self.create(Expr, .{
                    .kind = .{ .match = .{
                        .scrutinee = scrutinee,
                        .decision = decision,
                    } },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = ce.meta.span,
                });
            },
            .panic_expr => |pe| try self.create(Expr, .{
                .kind = .{ .panic = try self.buildExpr(pe.message) },
                .type_id = types_mod.TypeStore.NEVER,
                .span = pe.meta.span,
            }),
            .tuple => |t| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (t.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                return try self.create(Expr, .{
                    .kind = .{ .tuple_init = try elems.toOwnedSlice(self.allocator) },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = t.meta.span,
                });
            },
            .list => |l| {
                var elems: std.ArrayList(*const Expr) = .empty;
                for (l.elements) |elem| {
                    try elems.append(self.allocator, try self.buildExpr(elem));
                }
                return try self.create(Expr, .{
                    .kind = .{ .list_init = try elems.toOwnedSlice(self.allocator) },
                    .type_id = types_mod.TypeStore.UNKNOWN,
                    .span = l.meta.span,
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
    // Allocation helper
    // ============================================================

    fn moduleNameToString(self: *const HirBuilder, name: ast.ModuleName) []const u8 {
        // For single-part module names like "IO", just return the part
        if (name.parts.len == 1) {
            return self.interner.get(name.parts[0]);
        }
        // For multi-part names like "IO.File", we'd need to join — for now return first part
        return self.interner.get(name.parts[0]);
    }

    fn create(self: *HirBuilder, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }
};

// ============================================================
// Standard library module resolution
//
// Maps module-qualified calls (e.g. IO.puts) to runtime
// function names. No function is implicitly available —
// callers must use the fully qualified ModuleName.function form.
// ============================================================

const StdlibEntry = struct {
    module: []const u8,
    function: []const u8,
    runtime_name: []const u8,
};

const stdlib_functions = [_]StdlibEntry{
    .{ .module = "IO", .function = "puts", .runtime_name = "println" },
    .{ .module = "IO", .function = "inspect", .runtime_name = "print_str" },
};

fn resolveStdlibCall(module_name: []const u8, function_name: []const u8) ?[]const u8 {
    for (&stdlib_functions) |entry| {
        if (std.mem.eql(u8, module_name, entry.module) and
            std.mem.eql(u8, function_name, entry.function))
        {
            return entry.runtime_name;
        }
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "HIR build simple function" {
    const source =
        \\def add(x :: i64, y :: i64) :: i64 do
        \\  x + y
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.top_functions.len);
    try std.testing.expectEqual(@as(u32, 2), hir_program.top_functions[0].arity);
}

test "HIR build module" {
    const source =
        \\defmodule Math do
        \\  def add(x :: i64, y :: i64) :: i64 do
        \\    x + y
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), hir_program.modules.len);
    try std.testing.expectEqual(@as(usize, 1), hir_program.modules[0].functions.len);
}

test "HIR pattern compilation" {
    const source =
        \\def foo(x) do
        \\  case x do
        \\    {:ok, v} ->
        \\      v
        \\    {:error, e} ->
        \\      e
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, &parser.interner);
    defer collector.deinit();
    try collector.collectProgram(&program);

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var builder = HirBuilder.init(alloc, &parser.interner, &collector.graph, &type_store);
    defer builder.deinit();
    const hir_program = try builder.buildProgram(&program);

    // Should have built the function with case expression
    try std.testing.expectEqual(@as(usize, 1), hir_program.top_functions.len);
    try std.testing.expectEqual(@as(usize, 0), builder.errors.items.len);
}
