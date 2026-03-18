const std = @import("std");
const ast = @import("ast.zig");
const scope_mod = @import("scope.zig");
const types_mod = @import("types.zig");

// ============================================================
// Dispatch engine
//
// Implements scope-prioritized fallback dispatch (spec §10):
//   1. Try innermost scope's family
//   2. If no family or no applicable overload, continue outward
//   3. Ambiguous overload → compilation error
//   4. Applicable overload → attempt clause matching
//   5. No clause match → continue outward
//   6. Walk: local → module → import → prelude
//
// Also handles:
//   - Overload applicability (spec §9)
//   - Specificity comparison
//   - Ambiguity detection
//   - Clause matching
//   - Refinement evaluation
// ============================================================

pub const DispatchEngine = struct {
    allocator: std.mem.Allocator,
    graph: *const scope_mod.ScopeGraph,
    type_store: *const types_mod.TypeStore,
    interner: *const ast.StringInterner,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub const DispatchResult = struct {
        family_id: scope_mod.FunctionFamilyId,
        clause_index: u32,
        scope_id: scope_mod.ScopeId,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        graph: *const scope_mod.ScopeGraph,
        type_store: *const types_mod.TypeStore,
        interner: *const ast.StringInterner,
    ) DispatchEngine {
        return .{
            .allocator = allocator,
            .graph = graph,
            .type_store = type_store,
            .interner = interner,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *DispatchEngine) void {
        self.errors.deinit(self.allocator);
    }

    // ============================================================
    // Main dispatch entry point
    // ============================================================

    /// Resolve an unqualified call from a given scope.
    /// Walks outward through the scope chain following §10.1.
    pub fn resolve(
        self: *DispatchEngine,
        from_scope: scope_mod.ScopeId,
        name: ast.StringId,
        arity: u32,
        arg_types: []const types_mod.TypeId,
        span: ast.SourceSpan,
    ) !?DispatchResult {
        var current: ?scope_mod.ScopeId = from_scope;

        while (current) |sid| {
            const s = self.graph.getScope(sid);
            const key = scope_mod.FamilyKey{ .name = name, .arity = arity };

            if (s.function_families.get(key)) |fam_id| {
                // Family exists in this scope — try overload resolution
                const result = try self.resolveInFamily(fam_id, sid, arg_types, span);
                switch (result) {
                    .resolved => |r| return r,
                    .ambiguous => {
                        // Ambiguity never falls through (spec §10.1 step 5)
                        try self.errors.append(self.allocator, .{
                            .message = "ambiguous overload resolution",
                            .span = span,
                        });
                        return null;
                    },
                    .no_match => {
                        // No applicable overload/clause — continue outward
                    },
                }
            }

            // Check imports at module scope
            if (s.kind == .module) {
                for (s.imports.items) |imported| {
                    _ = imported;
                    // TODO: check imported families when cross-module resolution is implemented
                }
            }

            current = s.parent;
        }

        // No scope matched — report error
        try self.errors.append(self.allocator, .{
            .message = "no matching function found",
            .span = span,
        });
        return null;
    }

    /// Resolve a qualified call `Module.f(args...)` — no fallback (spec §10.1 qualified).
    pub fn resolveQualified(
        self: *DispatchEngine,
        module_scope: scope_mod.ScopeId,
        name: ast.StringId,
        arity: u32,
        arg_types: []const types_mod.TypeId,
        span: ast.SourceSpan,
    ) !?DispatchResult {
        const s = self.graph.getScope(module_scope);
        const key = scope_mod.FamilyKey{ .name = name, .arity = arity };

        if (s.function_families.get(key)) |fam_id| {
            const family = self.graph.getFamily(fam_id);
            // Must be public for qualified calls
            if (family.visibility != .public) {
                try self.errors.append(self.allocator, .{
                    .message = "function is private",
                    .span = span,
                });
                return null;
            }
            const result = try self.resolveInFamily(fam_id, module_scope, arg_types, span);
            switch (result) {
                .resolved => |r| return r,
                .ambiguous => {
                    try self.errors.append(self.allocator, .{
                        .message = "ambiguous overload in qualified call",
                        .span = span,
                    });
                    return null;
                },
                .no_match => {
                    try self.errors.append(self.allocator, .{
                        .message = "no matching clause in qualified call",
                        .span = span,
                    });
                    return null;
                },
            }
        }

        try self.errors.append(self.allocator, .{
            .message = "function not found in module",
            .span = span,
        });
        return null;
    }

    // ============================================================
    // Family-level resolution
    // ============================================================

    const FamilyResult = union(enum) {
        resolved: DispatchResult,
        ambiguous,
        no_match,
    };

    fn resolveInFamily(
        self: *DispatchEngine,
        family_id: scope_mod.FunctionFamilyId,
        scope_id: scope_mod.ScopeId,
        arg_types: []const types_mod.TypeId,
        _: ast.SourceSpan,
    ) !FamilyResult {
        const family = self.graph.getFamily(family_id);

        // Collect applicable clauses
        var applicable: std.ArrayList(u32) = .empty;
        defer applicable.deinit(self.allocator);

        for (family.clauses.items, 0..) |clause_ref, idx| {
            if (self.isClauseApplicable(clause_ref, arg_types)) {
                try applicable.append(self.allocator, @intCast(idx));
            }
        }

        if (applicable.items.len == 0) return .no_match;
        if (applicable.items.len == 1) {
            return .{ .resolved = .{
                .family_id = family_id,
                .clause_index = applicable.items[0],
                .scope_id = scope_id,
            } };
        }

        // Multiple applicable — check specificity
        const most_specific = self.findMostSpecific(family, applicable.items, arg_types);
        if (most_specific) |idx| {
            return .{ .resolved = .{
                .family_id = family_id,
                .clause_index = idx,
                .scope_id = scope_id,
            } };
        }

        return .ambiguous;
    }

    // ============================================================
    // Clause applicability
    // ============================================================

    fn isClauseApplicable(
        _: *DispatchEngine,
        clause_ref: scope_mod.FunctionClauseRef,
        arg_types: []const types_mod.TypeId,
    ) bool {
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Check parameter count matches
        if (clause.params.len != arg_types.len) return false;

        // Check each parameter type
        for (clause.params, arg_types) |param, arg_type| {
            if (param.type_annotation != null) {
                // If the parameter has a type annotation, check compatibility
                // For now, unknown types are always compatible
                if (arg_type == types_mod.TypeStore.UNKNOWN) continue;
                // TODO: resolve param type annotation and compare with arg_type
            }
            // No type annotation — any type is acceptable
        }

        return true;
    }

    // ============================================================
    // Specificity comparison (spec §9.3)
    // ============================================================

    fn findMostSpecific(
        self: *DispatchEngine,
        family: *const scope_mod.FunctionFamily,
        applicable: []const u32,
        _: []const types_mod.TypeId,
    ) ?u32 {
        if (applicable.len == 0) return null;

        var best: u32 = applicable[0];

        for (applicable[1..]) |candidate| {
            const cmp = self.compareSpecificity(family, best, candidate);
            if (cmp == .less_specific) {
                best = candidate;
            } else if (cmp == .incomparable) {
                return null; // Ambiguous
            }
        }

        // Verify best is actually more specific than all others
        for (applicable) |candidate| {
            if (candidate == best) continue;
            const cmp = self.compareSpecificity(family, best, candidate);
            if (cmp != .more_specific) return null;
        }

        return best;
    }

    const SpecificityOrder = enum {
        more_specific,
        less_specific,
        equal,
        incomparable,
    };

    fn compareSpecificity(
        self: *DispatchEngine,
        family: *const scope_mod.FunctionFamily,
        a_idx: u32,
        b_idx: u32,
    ) SpecificityOrder {
        _ = self;
        const clause_a = &family.clauses.items[a_idx];
        const clause_b = &family.clauses.items[b_idx];
        const a = &clause_a.decl.clauses[clause_a.clause_index];
        const b = &clause_b.decl.clauses[clause_b.clause_index];

        var a_more_specific: bool = false;
        var b_more_specific: bool = false;

        for (a.params, b.params) |pa, pb| {
            const a_has_type = pa.type_annotation != null;
            const b_has_type = pb.type_annotation != null;

            if (a_has_type and !b_has_type) {
                a_more_specific = true;
            } else if (!a_has_type and b_has_type) {
                b_more_specific = true;
            }

            // Check pattern specificity
            const a_pattern_specific = isPatternSpecific(pa.pattern);
            const b_pattern_specific = isPatternSpecific(pb.pattern);

            if (a_pattern_specific and !b_pattern_specific) {
                a_more_specific = true;
            } else if (!a_pattern_specific and b_pattern_specific) {
                b_more_specific = true;
            }
        }

        // Refinement adds specificity
        if (a.refinement != null and b.refinement == null) {
            a_more_specific = true;
        } else if (a.refinement == null and b.refinement != null) {
            b_more_specific = true;
        }

        if (a_more_specific and !b_more_specific) return .more_specific;
        if (b_more_specific and !a_more_specific) return .less_specific;
        if (!a_more_specific and !b_more_specific) return .equal;
        return .incomparable;
    }

    fn isPatternSpecific(pattern: *const ast.Pattern) bool {
        return switch (pattern.*) {
            .literal => true,
            .tuple => true,
            .list => true,
            .list_cons => true,
            .map => true,
            .struct_pattern => true,
            .pin => true,
            .wildcard => false,
            .bind => false,
            .paren => |p| isPatternSpecific(p.inner),
        };
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "dispatch resolve simple function" {
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

    var engine = DispatchEngine.init(alloc, &collector.graph, &type_store, &parser.interner);
    defer engine.deinit();

    const add_name = try parser.interner.intern("add");
    const arg_types = [_]types_mod.TypeId{ types_mod.TypeStore.I64, types_mod.TypeStore.I64 };
    const result = try engine.resolve(
        0, // prelude scope
        add_name,
        2,
        &arg_types,
        .{ .start = 0, .end = 0 },
    );

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.clause_index);
}

test "dispatch scope fallback" {
    const source =
        \\defmodule Foo do
        \\  def b(s :: String) :: String do
        \\    s
        \\  end
        \\
        \\  def a(x :: i64) :: String do
        \\    def b(n :: i64) :: String do
        \\      "local"
        \\    end
        \\    b("hello")
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

    var engine = DispatchEngine.init(alloc, &collector.graph, &type_store, &parser.interner);
    defer engine.deinit();

    // Both module and local b exist — find b from the function scope of a
    // Walk scopes to find a function scope (should be inside module)
    const b_name = try parser.interner.intern("b");
    var search_scope: scope_mod.ScopeId = 0;
    for (collector.graph.scopes.items, 0..) |s, idx| {
        if (s.kind == .function) {
            search_scope = @intCast(idx);
        }
    }
    const result = try engine.resolve(
        search_scope,
        b_name,
        1,
        &.{types_mod.TypeStore.UNKNOWN},
        .{ .start = 0, .end = 0 },
    );

    try std.testing.expect(result != null);
}

test "dispatch no match" {
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

    var engine = DispatchEngine.init(alloc, &collector.graph, &type_store, &parser.interner);
    defer engine.deinit();

    const nonexistent = try parser.interner.intern("nonexistent");
    const result = try engine.resolve(
        0,
        nonexistent,
        1,
        &.{types_mod.TypeStore.I64},
        .{ .start = 0, .end = 0 },
    );

    try std.testing.expect(result == null);
    try std.testing.expect(engine.errors.items.len > 0);
}

test "dispatch specificity — literal pattern beats bind" {
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

    var type_store = types_mod.TypeStore.init(alloc, &parser.interner);
    defer type_store.deinit();

    var engine = DispatchEngine.init(alloc, &collector.graph, &type_store, &parser.interner);
    defer engine.deinit();

    const factorial_name = try parser.interner.intern("factorial");
    const result = try engine.resolve(
        0,
        factorial_name,
        1,
        &.{types_mod.TypeStore.I64},
        .{ .start = 0, .end = 0 },
    );

    // Should resolve to the literal pattern (more specific)
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u32, 0), result.?.clause_index);
}
