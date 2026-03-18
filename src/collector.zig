const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");

// ============================================================
// Declaration collector
//
// Walks the surface AST and:
//   1. Creates scopes for modules, functions, blocks
//   2. Collects type/opaque/struct declarations
//   3. Groups function clauses into families
//   4. Processes alias and import declarations
//   5. Hoists local defs to their enclosing block scope
// ============================================================

pub const Collector = struct {
    allocator: std.mem.Allocator,
    graph: scope.ScopeGraph,
    interner: *const ast.StringInterner,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner) Collector {
        return .{
            .allocator = allocator,
            .graph = scope.ScopeGraph.init(allocator),
            .interner = interner,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *Collector) void {
        self.graph.deinit();
        self.errors.deinit(self.allocator);
    }

    fn addError(self: *Collector, message: []const u8, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    // ============================================================
    // Top-level collection entry point
    // ============================================================

    pub fn collectProgram(self: *Collector, program: *const ast.Program) !void {
        // Process top-level modules
        for (program.modules) |*mod| {
            try self.collectModule(mod, self.graph.prelude_scope);
        }

        // Process top-level items (functions, types outside modules)
        // Modules are already processed above via program.modules, skip them here
        for (program.top_items) |item| {
            switch (item) {
                .function => |func| try self.collectFunction(func, self.graph.prelude_scope),
                .priv_function => |func| try self.collectFunction(func, self.graph.prelude_scope),
                .macro => |mac| try self.collectMacro(mac, self.graph.prelude_scope),
                .type_decl => |td| try self.collectType(td, self.graph.prelude_scope),
                .opaque_decl => |od| try self.collectOpaque(od, self.graph.prelude_scope),
                .struct_decl => |sd| try self.collectStruct(sd, self.graph.prelude_scope),
                .enum_decl => |ed| try self.collectEnum(ed, self.graph.prelude_scope),
                .module => {},
            }
        }

        // Second pass: resolve struct extends (copy parent fields into children)
        try self.resolveStructExtends();

        // Third pass: resolve module extends (copy parent function families into children)
        try self.resolveModuleExtends(program);
    }

    // ============================================================
    // Module collection
    // ============================================================

    fn collectModule(self: *Collector, mod: *const ast.ModuleDecl, parent_scope: scope.ScopeId) !void {
        const mod_scope = try self.graph.createScope(parent_scope, .module);
        try self.graph.node_scope_map.put(mod.meta.span.start, mod_scope);
        try self.graph.registerModule(mod.name, mod_scope, mod);

        for (mod.items) |item| {
            switch (item) {
                .function => |func| try self.collectFunction(func, mod_scope),
                .priv_function => |func| try self.collectFunction(func, mod_scope),
                .macro => |mac| try self.collectMacro(mac, mod_scope),
                .type_decl => |td| try self.collectType(td, mod_scope),
                .opaque_decl => |od| try self.collectOpaque(od, mod_scope),
                .struct_decl => |sd| try self.collectStruct(sd, mod_scope),
                .enum_decl => |ed| try self.collectEnum(ed, mod_scope),
                .alias_decl => |ad| try self.collectAlias(ad, mod_scope),
                .import_decl => |id_decl| try self.collectImport(id_decl, mod_scope),
            }
        }
    }

    // ============================================================
    // Function collection — family grouping
    // ============================================================

    fn collectFunction(self: *Collector, func: *const ast.FunctionDecl, parent_scope: scope.ScopeId) !void {
        for (func.clauses, 0..) |clause, clause_idx| {
            const arity: u32 = @intCast(clause.params.len);
            const key = scope.FamilyKey{ .name = func.name, .arity = arity };

            // Look up existing family in this scope (not parent scopes)
            const parent = self.graph.getScopeMut(parent_scope);
            const family_id = if (parent.function_families.get(key)) |fid|
                fid
            else
                try self.graph.createFamily(parent_scope, func.name, arity, func.visibility);

            // Add clause reference to the family
            try self.graph.getFamilyMut(family_id).clauses.append(self.allocator, .{
                .decl = func,
                .clause_index = @intCast(clause_idx),
            });

            // Create a function scope for each clause
            const fn_scope = try self.graph.createScope(parent_scope, .function);
            // Record scope mapping so the type checker can find it
            try self.graph.node_scope_map.put(clause.meta.span.start, fn_scope);

            // Collect parameter bindings
            for (clause.params) |param| {
                try self.collectPatternBindings(param.pattern, fn_scope);
            }

            // Collect body statements (hoisting local defs)
            try self.collectBlock(clause.body, fn_scope);
        }
    }

    // ============================================================
    // Macro collection
    // ============================================================

    fn collectMacro(self: *Collector, mac: *const ast.FunctionDecl, parent_scope: scope.ScopeId) !void {
        for (mac.clauses, 0..) |clause, clause_idx| {
            const arity: u32 = @intCast(clause.params.len);
            const key = scope.FamilyKey{ .name = mac.name, .arity = arity };

            const parent = self.graph.getScopeMut(parent_scope);
            const macro_id = if (parent.macros.get(key)) |mid|
                mid
            else
                try self.graph.createMacroFamily(parent_scope, mac.name, arity);

            try self.graph.macro_families.items[macro_id].clauses.append(self.allocator, .{
                .decl = mac,
                .clause_index = @intCast(clause_idx),
            });

            const fn_scope = try self.graph.createScope(parent_scope, .function);
            try self.graph.node_scope_map.put(clause.meta.span.start, fn_scope);

            for (clause.params) |param| {
                try self.collectPatternBindings(param.pattern, fn_scope);
            }

            try self.collectBlock(clause.body, fn_scope);
        }
    }

    // ============================================================
    // Type/opaque/struct collection
    // ============================================================

    fn collectType(self: *Collector, td: *const ast.TypeDecl, parent_scope: scope.ScopeId) !void {
        _ = try self.graph.registerType(td.name, parent_scope, .{ .type_alias = td.body }, td.params);
    }

    fn collectOpaque(self: *Collector, od: *const ast.OpaqueDecl, parent_scope: scope.ScopeId) !void {
        _ = try self.graph.registerType(od.name, parent_scope, .{ .opaque_type = od.body }, od.params);
    }

    fn collectStruct(self: *Collector, sd: *const ast.StructDecl, parent_scope: scope.ScopeId) !void {
        const name = sd.name orelse 0; // Named structs use their own name; module-scoped use sentinel
        _ = try self.graph.registerType(
            name,
            parent_scope,
            .{ .struct_type = sd },
            &.{},
        );
    }

    fn collectEnum(self: *Collector, ed: *const ast.EnumDecl, parent_scope: scope.ScopeId) !void {
        _ = try self.graph.registerType(
            ed.name,
            parent_scope,
            .{ .enum_type = ed },
            &.{},
        );
    }

    // ============================================================
    // Extends resolution
    // ============================================================

    fn resolveStructExtends(self: *Collector) !void {
        // For each registered type that is a struct with a parent, resolve it
        for (self.graph.types.items) |*type_entry| {
            if (type_entry.kind != .struct_type) continue;
            const sd = type_entry.kind.struct_type;
            const parent_name = sd.parent orelse continue;

            // Find parent type
            const parent_type_id = self.graph.resolveTypeByName(parent_name) orelse {
                try self.addError(
                    "unknown parent struct in extends",
                    sd.meta.span,
                );
                continue;
            };

            const parent_entry = self.graph.types.items[parent_type_id];
            if (parent_entry.kind != .struct_type) {
                try self.addError(
                    "extends target must be a struct",
                    sd.meta.span,
                );
                continue;
            }

            // Detect cycles: walk the parent chain and check for self-reference
            const child_name = sd.name orelse continue;
            var current_parent: ?ast.StringId = parent_name;
            while (current_parent) |cp| {
                if (cp == child_name) {
                    try self.addError(
                        "circular struct inheritance detected",
                        sd.meta.span,
                    );
                    break;
                }
                // Walk up to grandparent
                if (self.graph.resolveTypeByName(cp)) |cp_tid| {
                    const cp_entry = self.graph.types.items[cp_tid];
                    if (cp_entry.kind == .struct_type) {
                        current_parent = cp_entry.kind.struct_type.parent;
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            }
        }
    }

    fn resolveModuleExtends(self: *Collector, program: *const ast.Program) !void {
        // For each module with a parent, copy parent's public function families
        for (program.modules) |*mod| {
            const parent_name = mod.parent orelse continue;

            // Find parent module by name
            var parent_scope_id: ?scope.ScopeId = null;
            for (self.graph.modules.items) |mod_entry| {
                if (mod_entry.name.parts.len == 1 and mod_entry.name.parts[0] == parent_name) {
                    parent_scope_id = mod_entry.scope_id;
                    break;
                }
            }

            if (parent_scope_id == null) {
                try self.addError(
                    "unknown parent module in extends",
                    mod.meta.span,
                );
                continue;
            }

            // Find child module scope
            var child_scope_id: ?scope.ScopeId = null;
            for (self.graph.modules.items) |mod_entry| {
                if (mod_entry.decl == mod) {
                    child_scope_id = mod_entry.scope_id;
                    break;
                }
            }

            const child_sid = child_scope_id orelse continue;
            const parent_sid = parent_scope_id.?;

            // Copy public function families from parent to child
            // First collect family keys to avoid iterator invalidation
            var family_keys: std.ArrayList(scope.FamilyKey) = .empty;
            var family_ids: std.ArrayList(scope.FunctionFamilyId) = .empty;
            {
                const parent_scope_data = self.graph.getScope(parent_sid);
                var iter = parent_scope_data.function_families.iterator();
                while (iter.next()) |entry| {
                    try family_keys.append(self.allocator, entry.key_ptr.*);
                    try family_ids.append(self.allocator, entry.value_ptr.*);
                }
            }

            for (family_keys.items, family_ids.items) |family_key, parent_family_id| {
                const parent_family = self.graph.getFamily(parent_family_id);

                // Only copy public functions
                if (parent_family.visibility != .public) continue;

                // Skip if child already has this family (override)
                const child_scope_data = self.graph.getScope(child_sid);
                if (child_scope_data.function_families.get(family_key) != null) continue;

                // Collect clause refs before creating new family (avoids stale pointer)
                var clause_refs: std.ArrayList(scope.FunctionClauseRef) = .empty;
                for (parent_family.clauses.items) |clause_ref| {
                    try clause_refs.append(self.allocator, clause_ref);
                }

                // Create a new family in the child scope that references parent clauses
                const new_family_id = try self.graph.createFamily(child_sid, family_key.name, family_key.arity, .public);
                const new_family = self.graph.getFamilyMut(new_family_id);
                for (clause_refs.items) |clause_ref| {
                    try new_family.clauses.append(self.allocator, clause_ref);
                }
            }
        }
    }

    // ============================================================
    // Alias and import collection
    // ============================================================

    fn collectAlias(self: *Collector, ad: *const ast.AliasDecl, parent_scope: scope.ScopeId) !void {
        // alias Foo.Bar.Baz -> Baz (or "as" name)
        const short_name = if (ad.as_name) |as_name|
            as_name.parts[as_name.parts.len - 1]
        else
            ad.module_path.parts[ad.module_path.parts.len - 1];

        const full_name = ad.module_path.parts[ad.module_path.parts.len - 1];

        try self.graph.getScopeMut(parent_scope).aliases.put(short_name, full_name);
    }

    fn collectImport(self: *Collector, id_decl: *const ast.ImportDecl, parent_scope: scope.ScopeId) !void {
        const filter: scope.ImportFilter = if (id_decl.filter) |f| switch (f) {
            .only => |entries| blk: {
                var import_entries: std.ArrayList(scope.ImportEntry) = .empty;
                for (entries) |e| {
                    switch (e) {
                        .function => |func| try import_entries.append(self.allocator, .{
                            .name = func.name,
                            .arity = func.arity,
                        }),
                        .type_import => |name| try import_entries.append(self.allocator, .{
                            .name = name,
                            .arity = null,
                        }),
                    }
                }
                break :blk .{ .only = try import_entries.toOwnedSlice(self.allocator) };
            },
            .except => |entries| blk: {
                var import_entries: std.ArrayList(scope.ImportEntry) = .empty;
                for (entries) |e| {
                    switch (e) {
                        .function => |func| try import_entries.append(self.allocator, .{
                            .name = func.name,
                            .arity = func.arity,
                        }),
                        .type_import => |name| try import_entries.append(self.allocator, .{
                            .name = name,
                            .arity = null,
                        }),
                    }
                }
                break :blk .{ .except = try import_entries.toOwnedSlice(self.allocator) };
            },
        } else .all;

        try self.graph.getScopeMut(parent_scope).imports.append(self.allocator, .{
            .source_module = id_decl.module_path,
            .filter = filter,
            .imported_families = std.AutoHashMap(scope.FamilyKey, scope.FunctionFamilyId).init(self.allocator),
            .imported_types = std.AutoHashMap(ast.StringId, scope.TypeId).init(self.allocator),
        });
    }

    // ============================================================
    // Block collection — handles local def hoisting
    // ============================================================

    fn collectBlock(self: *Collector, stmts: []const ast.Stmt, parent_scope: scope.ScopeId) anyerror!void {
        // First pass: hoist local function declarations
        for (stmts) |stmt| {
            switch (stmt) {
                .function_decl => |func| try self.collectFunction(func, parent_scope),
                .macro_decl => |mac| try self.collectMacro(mac, parent_scope),
                else => {},
            }
        }

        // Second pass: collect bindings from assignments and expressions
        for (stmts) |stmt| {
            switch (stmt) {
                .assignment => |assign| {
                    try self.collectPatternBindings(assign.pattern, parent_scope);
                },
                .expr => |expr| {
                    try self.collectExprScopes(expr, parent_scope);
                },
                .import_decl => |id_decl| {
                    try self.collectImport(id_decl, parent_scope);
                },
                .function_decl, .macro_decl => {},
            }
        }
    }

    // ============================================================
    // Pattern binding collection
    // ============================================================

    fn collectPatternBindings(self: *Collector, pattern: *const ast.Pattern, scope_id: scope.ScopeId) !void {
        switch (pattern.*) {
            .bind => |bind| {
                _ = try self.graph.createBinding(bind.name, scope_id, .pattern_bind, bind.meta.span);
            },
            .tuple => |tup| {
                for (tup.elements) |elem| {
                    try self.collectPatternBindings(elem, scope_id);
                }
            },
            .list => |lst| {
                for (lst.elements) |elem| {
                    try self.collectPatternBindings(elem, scope_id);
                }
            },
            .map => |m| {
                for (m.fields) |field| {
                    try self.collectPatternBindings(field.value, scope_id);
                }
            },
            .struct_pattern => |sp| {
                for (sp.fields) |field| {
                    try self.collectPatternBindings(field.pattern, scope_id);
                }
            },
            .paren => |p| {
                try self.collectPatternBindings(p.inner, scope_id);
            },
            .wildcard, .literal, .pin => {},
        }
    }

    // ============================================================
    // Expression scope collection
    // ============================================================

    fn collectExprScopes(self: *Collector, expr: *const ast.Expr, parent_scope: scope.ScopeId) anyerror!void {
        switch (expr.*) {
            .if_expr => |ie| {
                const then_scope = try self.graph.createScope(parent_scope, .block);
                try self.collectBlock(ie.then_block, then_scope);
                if (ie.else_block) |else_block| {
                    const else_scope = try self.graph.createScope(parent_scope, .block);
                    try self.collectBlock(else_block, else_scope);
                }
            },
            .case_expr => |ce| {
                for (ce.clauses) |clause| {
                    const clause_scope = try self.graph.createScope(parent_scope, .case_clause);
                    try self.collectPatternBindings(clause.pattern, clause_scope);
                    try self.collectBlock(clause.body, clause_scope);
                }
            },
            .with_expr => |we| {
                const with_scope = try self.graph.createScope(parent_scope, .block);
                for (we.items) |item| {
                    switch (item) {
                        .bind => |b| {
                            try self.collectPatternBindings(b.pattern, with_scope);
                        },
                        .expr => {},
                    }
                }
                try self.collectBlock(we.body, with_scope);
                if (we.else_clauses) |else_clauses| {
                    for (else_clauses) |clause| {
                        const clause_scope = try self.graph.createScope(parent_scope, .case_clause);
                        try self.collectPatternBindings(clause.pattern, clause_scope);
                        try self.collectBlock(clause.body, clause_scope);
                    }
                }
            },
            .cond_expr => |cond| {
                for (cond.clauses) |clause| {
                    const clause_scope = try self.graph.createScope(parent_scope, .block);
                    try self.collectBlock(clause.body, clause_scope);
                }
            },
            .block => |blk| {
                const blk_scope = try self.graph.createScope(parent_scope, .block);
                try self.collectBlock(blk.stmts, blk_scope);
            },
            // For other expressions, we don't create new scopes
            else => {},
        }
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

test "collect simple function" {
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

    // Should have: prelude scope + function scope
    try std.testing.expectEqual(@as(usize, 2), collector.graph.scopes.items.len);
    // Should have 1 function family
    try std.testing.expectEqual(@as(usize, 1), collector.graph.families.items.len);
    // Family should have arity 2
    try std.testing.expectEqual(@as(u32, 2), collector.graph.families.items[0].arity);
    // Should have 2 parameter bindings (x, y)
    try std.testing.expectEqual(@as(usize, 2), collector.graph.bindings.items.len);
}

test "collect module with functions" {
    const source =
        \\defmodule Math do
        \\  def add(x :: i64, y :: i64) :: i64 do
        \\    x + y
        \\  end
        \\
        \\  def sub(x :: i64, y :: i64) :: i64 do
        \\    x - y
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

    // prelude + module + 2 function scopes
    try std.testing.expectEqual(@as(usize, 4), collector.graph.scopes.items.len);
    // 2 function families
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items.len);
    // 1 module
    try std.testing.expectEqual(@as(usize, 1), collector.graph.modules.items.len);
}

test "collect type declaration" {
    const source =
        \\defmodule Types do
        \\  type Result(a, e) = {:ok, a} | {:error, e}
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

    // Should have 1 type registered
    try std.testing.expectEqual(@as(usize, 1), collector.graph.types.items.len);
    try std.testing.expect(collector.graph.types.items[0].kind == .type_alias);
}

test "collect function family grouping" {
    const source =
        \\def factorial(0 :: i64) :: i64 do
        \\  1
        \\end
        \\
        \\def factorial(n :: i64) :: i64 do
        \\  n * factorial(n - 1)
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

    // Both clauses should be in one family (same name, same arity)
    try std.testing.expectEqual(@as(usize, 1), collector.graph.families.items.len);
    // Family should have 2 clauses
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items[0].clauses.items.len);
}

test "collect case expression creates scopes" {
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

    // prelude + function + 2 case clause scopes
    try std.testing.expectEqual(@as(usize, 4), collector.graph.scopes.items.len);
    // Parameter x + pattern binds v and e
    try std.testing.expectEqual(@as(usize, 3), collector.graph.bindings.items.len);
}

test "collect local def hoisting" {
    const source =
        \\def outer(x :: i64) :: String do
        \\  def inner(s :: String) :: String do
        \\    s
        \\  end
        \\  inner("ok")
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

    // Should have 2 function families (outer and inner)
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items.len);
}

test "collect struct declaration" {
    const source =
        \\defmodule User do
        \\  defstruct do
        \\    name :: String
        \\    age :: i64
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

    // Should have 1 type registered (struct)
    try std.testing.expectEqual(@as(usize, 1), collector.graph.types.items.len);
    try std.testing.expect(collector.graph.types.items[0].kind == .struct_type);
}
