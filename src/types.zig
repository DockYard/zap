const std = @import("std");
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");

// ============================================================
// Type representation
// ============================================================

pub const TypeId = u32;
pub const TypeVarId = u32;

pub const Type = union(enum) {
    // Primitive types
    int: IntType,
    float: FloatType,
    bool_type,
    string_type,
    atom_type,
    nil_type,
    never,

    // Compound types
    tuple: TupleType,
    list: ListType,
    map: MapType,
    struct_type: StructType,
    union_type: UnionType,
    function: FunctionType,

    // Parametric
    type_var: TypeVarId,
    applied: AppliedType,

    // Opaque
    opaque_type: OpaqueType,

    // Unknown (for inference)
    unknown,
    error_type,

    pub const IntType = struct {
        signedness: enum { signed, unsigned },
        bits: u16,
    };

    pub const FloatType = struct {
        bits: u16,
    };

    pub const TupleType = struct {
        elements: []const TypeId,
    };

    pub const ListType = struct {
        element: TypeId,
    };

    pub const MapType = struct {
        key: TypeId,
        value: TypeId,
    };

    pub const StructType = struct {
        name: ast.StringId,
        fields: []const StructField,
    };

    pub const StructField = struct {
        name: ast.StringId,
        type_id: TypeId,
    };

    pub const UnionType = struct {
        members: []const TypeId,
    };

    pub const FunctionType = struct {
        params: []const TypeId,
        return_type: TypeId,
    };

    pub const AppliedType = struct {
        base: TypeId,
        args: []const TypeId,
    };

    pub const OpaqueType = struct {
        name: ast.StringId,
        inner: TypeId,
    };
};

// ============================================================
// Type store
// ============================================================

pub const TypeStore = struct {
    allocator: std.mem.Allocator,
    types: std.ArrayList(Type),
    interner: *const ast.StringInterner,
    name_to_type: std.AutoHashMap(ast.StringId, TypeId),
    next_var: TypeVarId,

    // Well-known type IDs
    pub const BOOL: TypeId = 0;
    pub const STRING: TypeId = 1;
    pub const ATOM: TypeId = 2;
    pub const NIL: TypeId = 3;
    pub const NEVER: TypeId = 4;
    pub const I64: TypeId = 5;
    pub const I32: TypeId = 6;
    pub const I16: TypeId = 7;
    pub const I8: TypeId = 8;
    pub const U64: TypeId = 9;
    pub const U32: TypeId = 10;
    pub const U16: TypeId = 11;
    pub const U8: TypeId = 12;
    pub const F64: TypeId = 13;
    pub const F32: TypeId = 14;
    pub const F16: TypeId = 15;
    pub const USIZE: TypeId = 16;
    pub const ISIZE: TypeId = 17;
    pub const UNKNOWN: TypeId = 18;
    pub const ERROR: TypeId = 19;

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) TypeStore {
        var store = TypeStore{
            .allocator = allocator,
            .types = .empty,
            .interner = interner,
            .name_to_type = std.AutoHashMap(ast.StringId, TypeId).init(allocator),
            .next_var = 0,
        };
        store.registerBuiltins() catch {};
        return store;
    }

    pub fn deinit(self: *TypeStore) void {
        self.types.deinit(self.allocator);
        self.name_to_type.deinit();
    }

    fn registerBuiltins(self: *TypeStore) !void {
        // Must match the order of well-known IDs above
        try self.types.append(self.allocator, .bool_type); // 0
        try self.types.append(self.allocator, .string_type); // 1
        try self.types.append(self.allocator, .atom_type); // 2
        try self.types.append(self.allocator, .nil_type); // 3
        try self.types.append(self.allocator, .never); // 4
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 64 } }); // 5 - i64
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 32 } }); // 6 - i32
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 16 } }); // 7 - i16
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 8 } }); // 8 - i8
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 64 } }); // 9 - u64
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 32 } }); // 10 - u32
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 16 } }); // 11 - u16
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 8 } }); // 12 - u8
        try self.types.append(self.allocator, .{ .float = .{ .bits = 64 } }); // 13 - f64
        try self.types.append(self.allocator, .{ .float = .{ .bits = 32 } }); // 14 - f32
        try self.types.append(self.allocator, .{ .float = .{ .bits = 16 } }); // 15 - f16
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .unsigned, .bits = 64 } }); // 16 - usize (platform)
        try self.types.append(self.allocator, .{ .int = .{ .signedness = .signed, .bits = 64 } }); // 17 - isize (platform)
        try self.types.append(self.allocator, .unknown); // 18
        try self.types.append(self.allocator, .error_type); // 19
    }

    pub fn addType(self: *TypeStore, typ: Type) !TypeId {
        const id: TypeId = @intCast(self.types.items.len);
        try self.types.append(self.allocator, typ);
        return id;
    }

    pub fn getType(self: *const TypeStore, id: TypeId) Type {
        return self.types.items[id];
    }

    pub fn freshVar(self: *TypeStore) !TypeId {
        const var_id = self.next_var;
        self.next_var += 1;
        return try self.addType(.{ .type_var = var_id });
    }

    /// Resolve a type name string to a TypeId
    pub fn resolveTypeName(_: *const TypeStore, name: []const u8) ?TypeId {
        if (std.mem.eql(u8, name, "Bool")) return BOOL;
        if (std.mem.eql(u8, name, "String")) return STRING;
        if (std.mem.eql(u8, name, "Atom")) return ATOM;
        if (std.mem.eql(u8, name, "Nil")) return NIL;
        if (std.mem.eql(u8, name, "Never")) return NEVER;
        if (std.mem.eql(u8, name, "i64")) return I64;
        if (std.mem.eql(u8, name, "i32")) return I32;
        if (std.mem.eql(u8, name, "i16")) return I16;
        if (std.mem.eql(u8, name, "i8")) return I8;
        if (std.mem.eql(u8, name, "u64")) return U64;
        if (std.mem.eql(u8, name, "u32")) return U32;
        if (std.mem.eql(u8, name, "u16")) return U16;
        if (std.mem.eql(u8, name, "u8")) return U8;
        if (std.mem.eql(u8, name, "f64")) return F64;
        if (std.mem.eql(u8, name, "f32")) return F32;
        if (std.mem.eql(u8, name, "f16")) return F16;
        if (std.mem.eql(u8, name, "usize")) return USIZE;
        if (std.mem.eql(u8, name, "isize")) return ISIZE;
        return null;
    }

    /// Check if two types are the same
    pub fn typeEquals(self: *const TypeStore, a: TypeId, b: TypeId) bool {
        if (a == b) return true;
        const ta = self.getType(a);
        const tb = self.getType(b);

        // Never is a subtype of everything
        if (ta == .never or tb == .never) return true;
        // Unknown matches anything (for inference)
        if (ta == .unknown or tb == .unknown) return true;

        return false;
    }

    /// Check if `sub` is a subtype of `super`
    pub fn isSubtype(self: *const TypeStore, sub: TypeId, super: TypeId) bool {
        if (sub == super) return true;
        const sub_t = self.getType(sub);
        const super_t = self.getType(super);

        // Never is a subtype of everything
        if (sub_t == .never) return true;

        // Everything is a supertype of Never
        _ = super_t;

        // Union subtyping: sub is a subtype if it's a member of the union
        if (self.getType(super) == .union_type) {
            const ut = self.getType(super).union_type;
            for (ut.members) |member| {
                if (self.isSubtype(sub, member)) return true;
            }
        }

        return false;
    }
};

// ============================================================
// Type checker
// ============================================================

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    store: TypeStore,
    interner: *const ast.StringInterner,
    graph: *const scope_mod.ScopeGraph,
    errors: std.ArrayList(Error),

    // Expression type mapping
    expr_types: std.AutoHashMap(usize, TypeId),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner, graph: *const scope_mod.ScopeGraph) TypeChecker {
        return .{
            .allocator = allocator,
            .store = TypeStore.init(allocator, interner),
            .interner = interner,
            .graph = graph,
            .errors = .empty,
            .expr_types = std.AutoHashMap(usize, TypeId).init(allocator),
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.store.deinit();
        self.errors.deinit(self.allocator);
        self.expr_types.deinit();
    }

    fn addError(self: *TypeChecker, message: []const u8, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    // ============================================================
    // Program type checking
    // ============================================================

    pub fn checkProgram(self: *TypeChecker, program: *const ast.Program) !void {
        for (program.modules) |*mod| {
            try self.checkModule(mod);
        }
        for (program.top_items) |item| {
            try self.checkTopItem(item);
        }
    }

    fn checkModule(self: *TypeChecker, mod: *const ast.ModuleDecl) !void {
        for (mod.items) |item| {
            switch (item) {
                .function => |func| try self.checkFunctionDecl(func),
                .priv_function => |func| try self.checkFunctionDecl(func),
                .macro => |mac| try self.checkFunctionDecl(mac),
                else => {},
            }
        }
    }

    fn checkTopItem(self: *TypeChecker, item: ast.TopItem) !void {
        switch (item) {
            .function => |func| try self.checkFunctionDecl(func),
            .priv_function => |func| try self.checkFunctionDecl(func),
            .macro => |mac| try self.checkFunctionDecl(mac),
            .module => {},
            else => {},
        }
    }

    // ============================================================
    // Function type checking
    // ============================================================

    fn checkFunctionDecl(self: *TypeChecker, func: *const ast.FunctionDecl) !void {
        for (func.clauses) |clause| {
            try self.checkFunctionClause(&clause);
        }
    }

    fn checkFunctionClause(self: *TypeChecker, clause: *const ast.FunctionClause) !void {
        // Resolve parameter types
        for (clause.params) |param| {
            if (param.type_annotation) |ta| {
                _ = try self.resolveTypeExpr(ta);
            }
        }

        // Resolve return type
        const declared_return = if (clause.return_type) |rt|
            try self.resolveTypeExpr(rt)
        else
            TypeStore.UNKNOWN;

        // Check refinement is Bool
        if (clause.refinement) |ref| {
            const ref_type = try self.inferExpr(ref);
            if (ref_type != TypeStore.BOOL and ref_type != TypeStore.UNKNOWN) {
                try self.addError("refinement predicate must be Bool", ref.getMeta().span);
            }
        }

        // Check body
        var body_type: TypeId = TypeStore.NIL;
        for (clause.body) |stmt| {
            body_type = try self.checkStmt(stmt);
        }

        // Verify return type matches
        if (declared_return != TypeStore.UNKNOWN and body_type != TypeStore.UNKNOWN) {
            if (!self.store.typeEquals(body_type, declared_return)) {
                // Type mismatch — for now, just record it
                // Full error reporting needs source span info
            }
        }
    }

    // ============================================================
    // Statement type checking
    // ============================================================

    fn checkStmt(self: *TypeChecker, stmt: ast.Stmt) anyerror!TypeId {
        return switch (stmt) {
            .expr => |expr| self.inferExpr(expr),
            .assignment => |assign| self.inferExpr(assign.value),
            .function_decl => |func| {
                try self.checkFunctionDecl(func);
                return TypeStore.NIL;
            },
            .macro_decl => |mac| {
                try self.checkFunctionDecl(mac);
                return TypeStore.NIL;
            },
            .import_decl => TypeStore.NIL,
        };
    }

    // ============================================================
    // Expression type inference
    // ============================================================

    fn inferExpr(self: *TypeChecker, expr: *const ast.Expr) anyerror!TypeId {
        return switch (expr.*) {
            .int_literal => TypeStore.I64,
            .float_literal => TypeStore.F64,
            .string_literal => TypeStore.STRING,
            .atom_literal => TypeStore.ATOM,
            .bool_literal => TypeStore.BOOL,
            .nil_literal => TypeStore.NIL,
            .var_ref => TypeStore.UNKNOWN, // Type resolved from scope binding later

            .binary_op => |bo| self.inferBinaryOp(&bo),
            .unary_op => |uo| self.inferUnaryOp(&uo),
            .call => |call| self.inferCall(&call),

            .tuple => |t| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (t.elements) |elem| {
                    try elem_types.append(self.allocator, try self.inferExpr(elem));
                }
                return try self.store.addType(.{
                    .tuple = .{ .elements = try elem_types.toOwnedSlice(self.allocator) },
                });
            },

            .list => |l| {
                if (l.elements.len == 0) return TypeStore.UNKNOWN;
                const elem_type = try self.inferExpr(l.elements[0]);
                return try self.store.addType(.{
                    .list = .{ .element = elem_type },
                });
            },

            .if_expr => |ie| {
                const cond_type = try self.inferExpr(ie.condition);
                if (cond_type != TypeStore.BOOL and cond_type != TypeStore.UNKNOWN) {
                    try self.addError("if condition must be Bool", ie.meta.span);
                }
                var then_type: TypeId = TypeStore.NIL;
                for (ie.then_block) |stmt| {
                    then_type = try self.checkStmt(stmt);
                }
                if (ie.else_block) |else_block| {
                    var else_type: TypeId = TypeStore.NIL;
                    for (else_block) |stmt| {
                        else_type = try self.checkStmt(stmt);
                    }
                    // Return type is union of both branches
                    if (self.store.typeEquals(then_type, else_type)) return then_type;
                    return TypeStore.UNKNOWN;
                }
                return then_type;
            },

            .case_expr => |ce| {
                _ = try self.inferExpr(ce.scrutinee);
                var result_type: TypeId = TypeStore.UNKNOWN;
                for (ce.clauses) |clause| {
                    var clause_type: TypeId = TypeStore.NIL;
                    for (clause.body) |stmt| {
                        clause_type = try self.checkStmt(stmt);
                    }
                    if (result_type == TypeStore.UNKNOWN) {
                        result_type = clause_type;
                    }
                }
                return result_type;
            },

            .block => |blk| {
                var result_type: TypeId = TypeStore.NIL;
                for (blk.stmts) |stmt| {
                    result_type = try self.checkStmt(stmt);
                }
                return result_type;
            },

            .panic_expr => TypeStore.NEVER,
            .unwrap => TypeStore.UNKNOWN,
            .pipe => TypeStore.UNKNOWN,
            .field_access => TypeStore.UNKNOWN,
            .map => TypeStore.UNKNOWN,
            .struct_expr => TypeStore.UNKNOWN,
            .module_ref => TypeStore.UNKNOWN,
            .string_interpolation => TypeStore.STRING,
            .quote_expr => TypeStore.UNKNOWN,
            .unquote_expr => TypeStore.UNKNOWN,
            .with_expr => TypeStore.UNKNOWN,
            .cond_expr => TypeStore.UNKNOWN,
            .intrinsic => TypeStore.UNKNOWN,
        };
    }

    fn inferBinaryOp(self: *TypeChecker, bo: *const ast.BinaryOp) !TypeId {
        const lhs = try self.inferExpr(bo.lhs);
        const rhs = try self.inferExpr(bo.rhs);

        return switch (bo.op) {
            // Arithmetic: both operands must be same numeric type
            .add, .sub, .mul, .div, .rem_op => {
                if (lhs == TypeStore.UNKNOWN or rhs == TypeStore.UNKNOWN) return if (lhs != TypeStore.UNKNOWN) lhs else rhs;
                if (!self.store.typeEquals(lhs, rhs)) {
                    try self.addError("arithmetic operands must have the same type", bo.meta.span);
                    return TypeStore.ERROR;
                }
                return lhs;
            },
            // Comparison: returns Bool
            .equal, .not_equal, .less, .greater, .less_equal, .greater_equal => TypeStore.BOOL,
            // Logical: returns Bool
            .and_op, .or_op => TypeStore.BOOL,
            // String concat
            .concat => TypeStore.STRING,
        };
    }

    fn inferUnaryOp(self: *TypeChecker, uo: *const ast.UnaryOp) !TypeId {
        const operand_type = try self.inferExpr(uo.operand);
        return switch (uo.op) {
            .negate => operand_type,
            .not_op => TypeStore.BOOL,
        };
    }

    fn inferCall(self: *TypeChecker, call: *const ast.CallExpr) !TypeId {
        // Infer callee type
        const callee_type = try self.inferExpr(call.callee);

        // If callee has a known function type, use its return type
        if (callee_type != TypeStore.UNKNOWN) {
            const ct = self.store.getType(callee_type);
            if (ct == .function) {
                return ct.function.return_type;
            }
        }

        // Infer argument types (for side effects / error checking)
        for (call.args) |arg| {
            _ = try self.inferExpr(arg);
        }

        return TypeStore.UNKNOWN;
    }

    // ============================================================
    // Type expression resolution
    // ============================================================

    fn resolveTypeExpr(self: *TypeChecker, type_expr: *const ast.TypeExpr) anyerror!TypeId {
        return switch (type_expr.*) {
            .name => |tn| {
                const name = self.interner.get(tn.name);
                if (self.store.resolveTypeName(name)) |tid| {
                    if (tn.args.len > 0) {
                        // Generic type application
                        var arg_types: std.ArrayList(TypeId) = .empty;
                        for (tn.args) |arg| {
                            try arg_types.append(self.allocator, try self.resolveTypeExpr(arg));
                        }
                        return try self.store.addType(.{
                            .applied = .{
                                .base = tid,
                                .args = try arg_types.toOwnedSlice(self.allocator),
                            },
                        });
                    }
                    return tid;
                }
                // User-defined type — return unknown for now
                return TypeStore.UNKNOWN;
            },
            .variable => try self.store.freshVar(),
            .tuple => |tt| {
                var elem_types: std.ArrayList(TypeId) = .empty;
                for (tt.elements) |elem| {
                    try elem_types.append(self.allocator, try self.resolveTypeExpr(elem));
                }
                return try self.store.addType(.{
                    .tuple = .{ .elements = try elem_types.toOwnedSlice(self.allocator) },
                });
            },
            .list => |lt| {
                const elem_type = try self.resolveTypeExpr(lt.element);
                return try self.store.addType(.{
                    .list = .{ .element = elem_type },
                });
            },
            .union_type => |ut| {
                var member_types: std.ArrayList(TypeId) = .empty;
                for (ut.members) |member| {
                    try member_types.append(self.allocator, try self.resolveTypeExpr(member));
                }
                return try self.store.addType(.{
                    .union_type = .{ .members = try member_types.toOwnedSlice(self.allocator) },
                });
            },
            .function => |ft| {
                var param_types: std.ArrayList(TypeId) = .empty;
                for (ft.params) |param| {
                    try param_types.append(self.allocator, try self.resolveTypeExpr(param));
                }
                const return_type = try self.resolveTypeExpr(ft.return_type);
                return try self.store.addType(.{
                    .function = .{
                        .params = try param_types.toOwnedSlice(self.allocator),
                        .return_type = return_type,
                    },
                });
            },
            .never => TypeStore.NEVER,
            .literal => |lt| {
                return switch (lt.value) {
                    .int => TypeStore.I64,
                    .string => TypeStore.STRING,
                    .bool_val => TypeStore.BOOL,
                    .nil => TypeStore.NIL,
                };
            },
            .paren => |pt| self.resolveTypeExpr(pt.inner),
            .map => TypeStore.UNKNOWN,
            .struct_type => TypeStore.UNKNOWN,
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "type store builtin types" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expect(store.getType(TypeStore.BOOL) == .bool_type);
    try std.testing.expect(store.getType(TypeStore.STRING) == .string_type);
    try std.testing.expect(store.getType(TypeStore.I64) == .int);
    try std.testing.expect(store.getType(TypeStore.F64) == .float);
    try std.testing.expect(store.getType(TypeStore.NEVER) == .never);
}

test "type store resolve builtin names" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();
    var store = TypeStore.init(std.testing.allocator, &interner);
    defer store.deinit();

    try std.testing.expectEqual(TypeStore.I64, store.resolveTypeName("i64").?);
    try std.testing.expectEqual(TypeStore.BOOL, store.resolveTypeName("Bool").?);
    try std.testing.expectEqual(TypeStore.STRING, store.resolveTypeName("String").?);
    try std.testing.expect(store.resolveTypeName("Nonexistent") == null);
}

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "type check simple function" {
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

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check literals" {
    const source =
        \\def foo() do
        \\  42
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

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}

test "type check case expression" {
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

    var checker = TypeChecker.init(alloc, &parser.interner, &collector.graph);
    defer checker.deinit();
    try checker.checkProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), checker.errors.items.len);
}
