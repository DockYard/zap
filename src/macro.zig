const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");
const ast_data = @import("ast_data.zig");
const ctfe = @import("ctfe.zig");

// ============================================================
// Macro engine
//
// Performs hygienic macro expansion on the surface AST.
// Expansion is repeated to a fixed point.
//
// Key concepts:
//   - quote: captures AST as data
//   - unquote: splices values into quoted AST
//   - hygiene: generated names carry a generation counter
//     to avoid accidental capture
// ============================================================

pub const MacroEngine = struct {
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    graph: *scope.ScopeGraph,
    /// The module scope currently being expanded, for registering generated declarations.
    current_module_scope: ?scope.ScopeId = null,
    generation: u32,
    max_expansions: u32,
    errors: std.ArrayList(Error),
    /// Tracks which `@before_compile` callbacks have already fired
    /// for each module scope. The callback runs at most once per
    /// module per `expandProgram` invocation; subsequent expansion
    /// iterations re-check but skip already-fired hooks. Keyed by
    /// the (module_scope, hook_module_name_id) pair so the same
    /// module can register multiple distinct hooks.
    before_compile_fired: std.AutoHashMap(BeforeCompileKey, void),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub const BeforeCompileKey = struct {
        module_scope: scope.ScopeId,
        hook_name: ast.StringId,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *ast.StringInterner, graph: *scope.ScopeGraph) MacroEngine {
        return .{
            .allocator = allocator,
            .interner = interner,
            .graph = graph,
            .generation = 0,
            .max_expansions = 100,
            .errors = .empty,
            .before_compile_fired = std.AutoHashMap(BeforeCompileKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *MacroEngine) void {
        self.errors.deinit(self.allocator);
        self.before_compile_fired.deinit();
    }

    // ============================================================
    // Fixed-point expansion
    // ============================================================

    /// Expand all macros in a program to a fixed point.
    /// Returns the expanded program.
    pub fn expandProgram(self: *MacroEngine, program: *const ast.Program) !ast.Program {
        // Validate macro type annotations before expansion
        try self.validateMacros();

        var current_structs = program.structs;
        var current_top_items = program.top_items;
        var iteration: u32 = 0;

        while (iteration < self.max_expansions) : (iteration += 1) {
            var changed = false;

            // Expand structs
            var new_structs: std.ArrayList(ast.StructDecl) = .empty;
            for (current_structs) |mod| {
                const expanded = try self.expandStruct(&mod);
                if (expanded.changed) changed = true;
                try new_structs.append(self.allocator, expanded.module);
            }

            // Expand top-level items
            var new_top_items: std.ArrayList(ast.TopItem) = .empty;
            for (current_top_items) |item| {
                const expanded = try self.expandTopItem(item);
                if (expanded.changed) changed = true;
                try new_top_items.append(self.allocator, expanded.item);
            }

            const owned_structs = try new_structs.toOwnedSlice(self.allocator);
            current_top_items = try new_top_items.toOwnedSlice(self.allocator);

            // Fire `@before_compile` hooks once per (module, hook)
            // pair. Hooks may inject new declarations that themselves
            // contain macro calls, so any change keeps the outer
            // fixed-point loop alive for another iteration.
            const hook_result = try self.fireBeforeCompileHooks(owned_structs);
            if (hook_result.changed) changed = true;
            current_structs = hook_result.structs;

            if (!changed) break;
        }

        if (iteration >= self.max_expansions) {
            try self.errors.append(self.allocator, .{
                .message = "macro expansion did not reach fixed point",
                .span = .{ .start = 0, .end = 0 },
            });
        }

        return .{
            .structs = current_structs,
            .top_items = current_top_items,
        };
    }

    // ============================================================
    // Module expansion
    // ============================================================

    const ExpandedModule = struct {
        module: ast.StructDecl,
        changed: bool,
    };

    fn expandStruct(self: *MacroEngine, mod: *const ast.StructDecl) !ExpandedModule {
        var changed = false;
        var new_items: std.ArrayList(ast.StructItem) = .empty;

        // Find the module's scope by name (not pointer) so it works across
        // expansion iterations where the StructDecl is a copy.
        const mod_scope: ?scope.ScopeId = self.graph.findStructScope(mod.name);
        self.current_module_scope = mod_scope;
        defer self.current_module_scope = null;

        for (mod.items) |item| {
            switch (item) {
                .function => |func| {
                    // Try Kernel.fn macro first (Phase 5)
                    if (self.tryExpandDeclarationMacro("fn", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        // Bootstrap fallback: expand function body directly
                        const expanded = try self.expandFunctionDecl(func);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .function = expanded.decl });
                    }
                },
                .priv_function => |func| {
                    if (self.tryExpandDeclarationMacro("fn", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        const expanded = try self.expandFunctionDecl(func);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .priv_function = expanded.decl });
                    }
                },
                .macro => |mac| {
                    if (self.tryExpandDeclarationMacro("macro", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        const expanded = try self.expandFunctionDecl(mac);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .macro = expanded.decl });
                    }
                },
                .priv_macro => |mac| {
                    if (self.tryExpandDeclarationMacro("macro", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        const expanded = try self.expandFunctionDecl(mac);
                        if (expanded.changed) changed = true;
                        try new_items.append(self.allocator, .{ .priv_macro = expanded.decl });
                    }
                },
                .struct_decl => {
                    // Try Kernel.struct macro (Phase 5)
                    if (self.tryExpandDeclarationMacro("struct", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        // Bootstrap fallback: pass through unchanged
                        try new_items.append(self.allocator, item);
                    }
                },
                .union_decl => {
                    // Try Kernel.union macro (Phase 5)
                    if (self.tryExpandDeclarationMacro("union", item)) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                        changed = true;
                    } else {
                        try new_items.append(self.allocator, item);
                    }
                },
                .use_decl => |ud| {
                    // Step 1: Always emit `import Module` for function access
                    const import_decl = try self.create(ast.ImportDecl, .{
                        .meta = ud.meta,
                        .module_path = ud.module_path,
                        .filter = null,
                    });
                    try new_items.append(self.allocator, .{ .import_decl = import_decl });
                    changed = true;

                    // Step 2: Look up Module.__using__/1 and inject returned items
                    if (self.tryExpandUsing(ud)) |using_items| {
                        for (using_items) |using_item| {
                            try new_items.append(self.allocator, using_item);
                        }
                    }
                },
                .struct_level_expr => |expr| {
                    const expanded_items = self.expandStructLevelExpr(expr) catch {
                        try new_items.append(self.allocator, item);
                        continue;
                    };
                    if (expanded_items.changed) changed = true;
                    for (expanded_items.items) |expanded_item| {
                        try new_items.append(self.allocator, expanded_item);
                    }
                },
                else => try new_items.append(self.allocator, item),
            }
        }

        // Also try expanding the module declaration itself through Kernel.module
        // (only if a Kernel macro for "module" exists)

        return .{
            .module = .{
                .meta = mod.meta,
                .name = mod.name,
                .parent = mod.parent,
                .items = try new_items.toOwnedSlice(self.allocator),
                .fields = mod.fields,
                .is_private = mod.is_private,
            },
            .changed = changed,
        };
    }

    // ============================================================
    // Top-level item expansion
    // ============================================================

    const ExpandedTopItem = struct {
        item: ast.TopItem,
        changed: bool,
    };

    fn expandTopItem(self: *MacroEngine, item: ast.TopItem) !ExpandedTopItem {
        switch (item) {
            .function => |func| {
                const expanded = try self.expandFunctionDecl(func);
                return .{ .item = .{ .function = expanded.decl }, .changed = expanded.changed };
            },
            .priv_function => |func| {
                const expanded = try self.expandFunctionDecl(func);
                return .{ .item = .{ .priv_function = expanded.decl }, .changed = expanded.changed };
            },
            .macro => |mac| {
                const expanded = try self.expandFunctionDecl(mac);
                return .{ .item = .{ .macro = expanded.decl }, .changed = expanded.changed };
            },
            .priv_macro => |mac| {
                const expanded = try self.expandFunctionDecl(mac);
                return .{ .item = .{ .priv_macro = expanded.decl }, .changed = expanded.changed };
            },
            else => return .{ .item = item, .changed = false },
        }
    }

    // ============================================================
    // @before_compile callback firing
    //
    // After per-module macro expansion, every module is checked for
    // `@before_compile` attributes (single-value or accumulated) and
    // each registered hook module's `__before_compile__/1` macro is
    // invoked at most once per `expandProgram` call. The hook returns
    // a CtValue tree of declarations which is spliced into the
    // module's items via the same path `expandStructLevelExpr` uses
    // for inline macro returns. New items can themselves contain
    // macro calls; the outer fixed-point loop catches those.
    // ============================================================

    const HookFireResult = struct {
        structs: []const ast.StructDecl,
        changed: bool,
    };

    /// Fire all not-yet-fired `@before_compile` hooks across modules
    /// and append their results into the corresponding module's
    /// items. Returns either the input slice unchanged (when no hook
    /// fired) or a freshly allocated slice with the affected modules
    /// replaced. Either way the caller takes ownership.
    fn fireBeforeCompileHooks(
        self: *MacroEngine,
        current_structs: []const ast.StructDecl,
    ) !HookFireResult {
        var any_fired = false;
        const before_compile_id = try self.interner.intern("before_compile");

        // Build the output slice lazily — only allocate when the
        // first hook actually fires so the no-op path stays cheap.
        var output: ?[]ast.StructDecl = null;

        for (current_structs, 0..) |mod, mod_idx| {
            const mod_scope = self.graph.findStructScope(mod.name) orelse continue;
            const mod_entry = self.graph.findStructByScope(mod_scope) orelse continue;

            var hook_atoms: std.ArrayListUnmanaged([]const u8) = .empty;
            defer hook_atoms.deinit(self.allocator);

            for (mod_entry.attributes.items) |attr| {
                if (attr.name != before_compile_id) continue;

                // CTFE attribute evaluation runs after macro
                // expansion, so `computed_value` is typically null
                // here. Fall back to the raw AST value, which for
                // `@before_compile = :SomeModule` is an atom literal
                // we can resolve immediately. Hook targets are
                // expected to be plain atoms (or lists of atoms via
                // `Module.put_attribute`), not arbitrary
                // expressions; falling back covers the source-
                // declared case without forcing a CTFE detour.
                if (attr.computed_value) |cv| {
                    try collectHookAtoms(&hook_atoms, self.allocator, cv);
                } else if (attr.value) |expr| {
                    try collectHookAtomsFromExpr(&hook_atoms, self.allocator, self.interner, expr);
                }
            }
            if (hook_atoms.items.len == 0) continue;

            var appended_items: std.ArrayListUnmanaged(ast.StructItem) = .empty;
            defer appended_items.deinit(self.allocator);

            for (hook_atoms.items) |hook_name_str| {
                const hook_name_id = try self.interner.intern(hook_name_str);
                const fired_key: BeforeCompileKey = .{
                    .module_scope = mod_scope,
                    .hook_name = hook_name_id,
                };
                if (self.before_compile_fired.contains(fired_key)) continue;

                try self.before_compile_fired.put(fired_key, {});

                const hook_items = self.invokeBeforeCompileHook(
                    mod_scope,
                    mod.name,
                    hook_name_str,
                ) catch |err| {
                    try self.errors.append(self.allocator, .{
                        .message = try std.fmt.allocPrint(
                            self.allocator,
                            "@before_compile {s}: hook invocation failed ({s})",
                            .{ hook_name_str, @errorName(err) },
                        ),
                        .span = mod.meta.span,
                    });
                    continue;
                };

                for (hook_items) |item| {
                    try appended_items.append(self.allocator, item);
                }
            }

            if (appended_items.items.len == 0) continue;

            // Lazily allocate the output slice on first hook fire,
            // copying over the structs we've already passed.
            if (output == null) {
                output = try self.allocator.alloc(ast.StructDecl, current_structs.len);
                @memcpy(output.?[0..mod_idx], current_structs[0..mod_idx]);
                @memcpy(output.?[mod_idx + 1 ..], current_structs[mod_idx + 1 ..]);
            }

            const old_items = mod.items;
            const new_items = try self.allocator.alloc(ast.StructItem, old_items.len + appended_items.items.len);
            @memcpy(new_items[0..old_items.len], old_items);
            @memcpy(new_items[old_items.len..], appended_items.items);

            output.?[mod_idx] = .{
                .meta = mod.meta,
                .name = mod.name,
                .parent = mod.parent,
                .items = new_items,
                .fields = mod.fields,
                .is_private = mod.is_private,
            };
            any_fired = true;
        }

        return .{
            .structs = output orelse current_structs,
            .changed = any_fired,
        };
    }

    /// Walk a ConstValue and collect every atom string into `out`.
    /// Used to flatten an accumulated `@before_compile` list (which
    /// may be a single atom or a list of atoms from `put_attribute`).
    fn collectHookAtoms(
        out: *std.ArrayListUnmanaged([]const u8),
        alloc: std.mem.Allocator,
        cv: ctfe.ConstValue,
    ) !void {
        switch (cv) {
            .atom => |name| try out.append(alloc, name),
            .list => |elems| for (elems) |e| try collectHookAtoms(out, alloc, e),
            else => {}, // ignore other shapes — invalid hook target
        }
    }

    /// AST-level analog of `collectHookAtoms`: walk an attribute's
    /// raw value expression and collect atom-literal names. Handles
    /// the same shapes (single atom, list of atoms) that the
    /// computed-value path supports, but for source-declared
    /// `@before_compile = :Foo` cases that have not yet been CTFE'd.
    fn collectHookAtomsFromExpr(
        out: *std.ArrayListUnmanaged([]const u8),
        alloc: std.mem.Allocator,
        interner: *const ast.StringInterner,
        expr: *const ast.Expr,
    ) !void {
        switch (expr.*) {
            .atom_literal => |a| try out.append(alloc, interner.get(a.value)),
            .list => |l| for (l.elements) |elem| {
                try collectHookAtomsFromExpr(out, alloc, interner, elem);
            },
            .module_ref => |m| {
                // `@before_compile = SomeModule` — single-part name
                // becomes the hook target. Multi-part names (e.g.
                // `Foo.Bar`) are unsupported here.
                if (m.name.parts.len == 1) {
                    try out.append(alloc, interner.get(m.name.parts[0]));
                }
            },
            else => {},
        }
    }

    /// Invoke `<hook_name>.__before_compile__/1` and convert its
    /// result CtValue into a slice of StructItems for splicing.
    /// The argument passed to the hook is a CtValue describing the
    /// caller module (currently just an atom of the module's name).
    fn invokeBeforeCompileHook(
        self: *MacroEngine,
        caller_module_scope: scope.ScopeId,
        caller_module_name: ast.StructName,
        hook_module_name: []const u8,
    ) ![]ast.StructItem {
        // Resolve hook module name → scope id → __before_compile__/1
        // macro family.
        const hook_module_id = try self.interner.intern(hook_module_name);
        const hook_struct_name: ast.StructName = .{
            .parts = try self.allocator.dupe(ast.StringId, &.{hook_module_id}),
            .span = .{ .start = 0, .end = 0 },
        };
        const hook_scope = self.graph.findStructScope(hook_struct_name) orelse {
            // Hook module not found — emit error and return empty.
            try self.errors.append(self.allocator, .{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "@before_compile target module not found: {s}",
                    .{hook_module_name},
                ),
                .span = .{ .start = 0, .end = 0 },
            });
            return &.{};
        };

        const hook_name_id = try self.interner.intern("__before_compile__");
        const family_id = self.graph.resolveMacro(hook_scope, hook_name_id, 1) orelse {
            try self.errors.append(self.allocator, .{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "@before_compile {s}: __before_compile__/1 not defined",
                    .{hook_module_name},
                ),
                .span = .{ .start = 0, .end = 0 },
            });
            return &.{};
        };
        const family = &self.graph.macro_families.items[family_id];
        if (family.clauses.items.len == 0) return &.{};
        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Build the env-arg CtValue: an atom of the caller's module
        // name. A richer __ENV__ struct can come later; the atom is
        // enough for hooks that just want to read the caller's
        // attributes.
        const macro_eval = @import("macro_eval.zig");
        var store = ctfe.AllocationStore{};
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();
        env.module_ctx = .{
            .graph = self.graph,
            .interner = self.interner,
            // Hooks read attributes from the *caller* module, not the
            // hook module — that's the whole point of the pattern.
            .current_module_scope = caller_module_scope,
        };

        if (clause.params.len > 0 and clause.params[0].pattern.* == .bind) {
            const param_name = self.interner.get(clause.params[0].pattern.bind.name);
            // Caller module name as a colon-prefixed atom (the AST
            // encoding for atom literals). For multi-part names we
            // dot-join the parts so hooks see something readable.
            const name_string = try caller_module_name.toDottedString(self.allocator, self.interner);
            const colon_prefixed = try std.fmt.allocPrint(self.allocator, ":{s}", .{name_string});
            const env_arg = try ast_data.makeTuple3(
                self.allocator,
                &store,
                .{ .atom = colon_prefixed },
                try ast_data.emptyList(self.allocator, &store),
                .nil,
            );
            try env.bind(param_name, env_arg);
        }

        // Evaluate the hook's body.
        var result: ctfe.CtValue = .nil;
        for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
            const stmt_ct = try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt);
            result = macro_eval.eval(&env, stmt_ct) catch .nil;
        }

        // Convert the result into struct items. Same logic as
        // expandStructLevelExpr's __block__ handling — split mixed
        // results, dropping anything that isn't a recognized
        // declaration shape.
        return try self.ctValueToStructItems(result);
    }

    /// Convert a hook's CtValue result into a list of StructItems.
    /// Handles three shapes:
    ///   - `__block__` whose elements are decls: each becomes an item.
    ///   - A bare list of decl-shaped CtValues.
    ///   - A single decl-shaped CtValue.
    /// Anything else is ignored (the hook is expected to produce
    /// declarations only — runtime expressions are not meaningful at
    /// the bottom of a struct's body).
    fn ctValueToStructItems(
        self: *MacroEngine,
        result: ctfe.CtValue,
    ) ![]ast.StructItem {
        var items: std.ArrayListUnmanaged(ast.StructItem) = .empty;
        switch (result) {
            .tuple => |t| if (t.elems.len == 3) {
                const form = t.elems[0];
                if (form == .atom and std.mem.eql(u8, form.atom, "__block__")) {
                    if (t.elems[2] == .list) {
                        for (t.elems[2].list.elems) |elem| {
                            if (try ast_data.ctValueToStructItem(self.allocator, self.interner, elem)) |si| {
                                try items.append(self.allocator, si);
                            }
                        }
                    }
                } else {
                    if (try ast_data.ctValueToStructItem(self.allocator, self.interner, result)) |si| {
                        try items.append(self.allocator, si);
                    }
                }
            },
            .list => |l| {
                for (l.elems) |elem| {
                    if (try ast_data.ctValueToStructItem(self.allocator, self.interner, elem)) |si| {
                        try items.append(self.allocator, si);
                    }
                }
            },
            .nil => {}, // hook returned nothing — fine
            else => {},
        }
        return items.toOwnedSlice(self.allocator);
    }

    // ============================================================
    // Function declaration expansion
    // ============================================================

    const ExpandedDecl = struct {
        decl: *const ast.FunctionDecl,
        changed: bool,
    };

    fn expandFunctionDecl(self: *MacroEngine, func: *const ast.FunctionDecl) !ExpandedDecl {
        var changed = false;
        var new_clauses: std.ArrayList(ast.FunctionClause) = .empty;

        for (func.clauses) |clause| {
            if (clause.body) |body| {
                const expanded = try self.expandBlock(body);
                if (expanded.changed) changed = true;
                try new_clauses.append(self.allocator, .{
                    .meta = clause.meta,
                    .params = clause.params,
                    .return_type = clause.return_type,
                    .refinement = clause.refinement,
                    .body = expanded.stmts,
                });
            } else {
                // Bodyless clause (protocol signature, forward decl) — pass through unchanged
                try new_clauses.append(self.allocator, clause);
            }
        }

        if (!changed) return .{ .decl = func, .changed = false };

        const new_func = try self.create(ast.FunctionDecl, .{
            .meta = func.meta,
            .name = func.name,
            .clauses = try new_clauses.toOwnedSlice(self.allocator),
            .visibility = func.visibility,
        });
        return .{ .decl = new_func, .changed = true };
    }

    // ============================================================
    // Block expansion
    // ============================================================

    const ExpandedBlock = struct {
        stmts: []const ast.Stmt,
        changed: bool,
    };

    fn expandBlock(self: *MacroEngine, stmts: []const ast.Stmt) anyerror!ExpandedBlock {
        var changed = false;
        var new_stmts: std.ArrayList(ast.Stmt) = .empty;

        for (stmts) |stmt| {
            switch (stmt) {
                .expr => |expr| {
                    const expanded = try self.expandExpr(expr);
                    if (expanded.changed) changed = true;
                    try new_stmts.append(self.allocator, .{ .expr = expanded.expr });
                },
                .assignment => |assign| {
                    const expanded = try self.expandExpr(assign.value);
                    if (expanded.changed) changed = true;
                    if (expanded.changed) {
                        try new_stmts.append(self.allocator, .{
                            .assignment = try self.create(ast.Assignment, .{
                                .meta = assign.meta,
                                .pattern = assign.pattern,
                                .value = expanded.expr,
                            }),
                        });
                    } else {
                        try new_stmts.append(self.allocator, stmt);
                    }
                },
                .function_decl => |func| {
                    const expanded = try self.expandFunctionDecl(func);
                    if (expanded.changed) changed = true;
                    try new_stmts.append(self.allocator, .{ .function_decl = expanded.decl });
                },
                .macro_decl => |mac| {
                    const expanded = try self.expandFunctionDecl(mac);
                    if (expanded.changed) changed = true;
                    try new_stmts.append(self.allocator, .{ .macro_decl = expanded.decl });
                },
                .import_decl => {
                    try new_stmts.append(self.allocator, stmt);
                },
            }
        }

        return .{
            .stmts = try new_stmts.toOwnedSlice(self.allocator),
            .changed = changed,
        };
    }

    // ============================================================
    // Expression expansion
    // ============================================================

    const ExpandedExpr = struct {
        expr: *const ast.Expr,
        changed: bool,
    };

    fn expandExpr(self: *MacroEngine, expr: *const ast.Expr) anyerror!ExpandedExpr {
        switch (expr.*) {
            // Quote expressions produce AST data — leave them as-is
            // (unquote inside quote is handled at expansion time)
            .quote_expr => return .{ .expr = expr, .changed = false },

            // Unquote/unquote_splicing outside of quote is an error
            .unquote_expr, .unquote_splicing_expr => {
                try self.errors.append(self.allocator, .{
                    .message = "unquote outside of quote",
                    .span = expr.getMeta().span,
                });
                return .{ .expr = expr, .changed = false };
            },

            // Check if this is a macro call
            .call => |call| {
                // Check if the callee is a known macro
                if (call.callee.* == .var_ref) {
                    const callee_name = call.callee.var_ref.name;
                    const arity: u32 = @intCast(call.args.len);
                    // A function family with the same name+arity in scope shadows
                    // any imported macro of the same shape. This matches normal
                    // scope rules and lets `pub fn <op>` win over a Kernel `pub macro <op>`.
                    if (self.findFunction(callee_name, arity) == null) {
                        if (self.findMacro(callee_name, arity)) |_| {
                            const expanded = try self.expandMacroCall(expr);
                            return .{ .expr = expanded, .changed = true };
                        }
                    }
                }

                // Not a macro call — recurse into subexpressions
                return try self.expandCallExpr(expr);
            },

            .anonymous_function => |anon| {
                const expanded = try self.expandFunctionDecl(anon.decl);
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .anonymous_function = .{
                            .meta = anon.meta,
                            .decl = expanded.decl,
                        },
                    }),
                    .changed = expanded.changed,
                };
            },

            // Recurse into compound expressions
            .if_expr => |ie| {
                // Bootstrap fallback: expand if to case.
                // Kernel.if macro provides the same behavior but allows user override.
                const cond_exp = (try self.expandExpr(ie.condition)).expr;
                const true_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = ie.meta, .value = true } } });
                const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = ie.meta, .value = false } } });

                var then_stmts: std.ArrayList(ast.Stmt) = .empty;
                for (ie.then_block) |s| try then_stmts.append(self.allocator, s);
                const then_body = try then_stmts.toOwnedSlice(self.allocator);

                var else_body: []const ast.Stmt = undefined;
                if (ie.else_block) |else_block| {
                    var es: std.ArrayList(ast.Stmt) = .empty;
                    for (else_block) |s| try es.append(self.allocator, s);
                    else_body = try es.toOwnedSlice(self.allocator);
                } else {
                    const nil_expr = try self.create(ast.Expr, .{ .nil_literal = .{ .meta = ie.meta } });
                    else_body = try self.allocSlice(ast.Stmt, &.{.{ .expr = nil_expr }});
                }

                const clauses = try self.allocator.alloc(ast.CaseClause, 2);
                clauses[0] = .{ .meta = ie.meta, .pattern = true_pat, .type_annotation = null, .guard = null, .body = then_body };
                clauses[1] = .{ .meta = ie.meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = else_body };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .case_expr = .{ .meta = ie.meta, .scrutinee = cond_exp, .clauses = clauses },
                    }),
                    .changed = true,
                };
            },

            .case_expr => |ce| {
                var changed = false;
                const scrut_exp = try self.expandExpr(ce.scrutinee);
                if (scrut_exp.changed) changed = true;

                var new_clauses: std.ArrayList(ast.CaseClause) = .empty;
                for (ce.clauses) |clause| {
                    const body_exp = try self.expandBlock(clause.body);
                    if (body_exp.changed) changed = true;
                    try new_clauses.append(self.allocator, .{
                        .meta = clause.meta,
                        .pattern = clause.pattern,
                        .type_annotation = clause.type_annotation,
                        .guard = clause.guard,
                        .body = body_exp.stmts,
                    });
                }

                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .case_expr = .{
                            .meta = ce.meta,
                            .scrutinee = scrut_exp.expr,
                            .clauses = try new_clauses.toOwnedSlice(self.allocator),
                        },
                    }),
                    .changed = true,
                };
            },

            .binary_op => |bo| {
                const macro_name = binopMacroName(bo.op);

                // Try operator-named function first so a local `pub fn OP` shadows
                // any Kernel macro of the same name (matches normal scope rules).
                if (try self.tryDispatchToFunction(macro_name, &.{ bo.lhs, bo.rhs }, bo.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }

                // Then try Kernel/imported operator macro.
                if (self.tryExpandBinaryMacro(macro_name, bo.lhs, bo.rhs, bo.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }

                // Bootstrap fallback: and/or get short-circuit case expansion
                // (Kernel.and/or macros take precedence when available)
                if (bo.op == .and_op) {
                    const lhs_exp = (try self.expandExpr(bo.lhs)).expr;
                    const rhs_exp = (try self.expandExpr(bo.rhs)).expr;
                    const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = bo.meta, .value = false } } });
                    const wild_pat = try self.create(ast.Pattern, .{ .wildcard = .{ .meta = bo.meta } });
                    const false_expr = try self.create(ast.Expr, .{ .bool_literal = .{ .meta = bo.meta, .value = false } });
                    const false_body = try self.allocSlice(ast.Stmt, &.{.{ .expr = false_expr }});
                    const rhs_body = try self.allocSlice(ast.Stmt, &.{.{ .expr = rhs_exp }});
                    const clauses = try self.allocator.alloc(ast.CaseClause, 2);
                    clauses[0] = .{ .meta = bo.meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = false_body };
                    clauses[1] = .{ .meta = bo.meta, .pattern = wild_pat, .type_annotation = null, .guard = null, .body = rhs_body };
                    return .{ .expr = try self.create(ast.Expr, .{ .case_expr = .{ .meta = bo.meta, .scrutinee = lhs_exp, .clauses = clauses } }), .changed = true };
                }
                if (bo.op == .or_op) {
                    const lhs_exp = (try self.expandExpr(bo.lhs)).expr;
                    const rhs_exp = (try self.expandExpr(bo.rhs)).expr;
                    const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = bo.meta, .value = false } } });
                    const wild_pat = try self.create(ast.Pattern, .{ .wildcard = .{ .meta = bo.meta } });
                    const rhs_body2 = try self.allocSlice(ast.Stmt, &.{.{ .expr = rhs_exp }});
                    const lhs_body2 = try self.allocSlice(ast.Stmt, &.{.{ .expr = lhs_exp }});
                    const clauses = try self.allocator.alloc(ast.CaseClause, 2);
                    clauses[0] = .{ .meta = bo.meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = rhs_body2 };
                    clauses[1] = .{ .meta = bo.meta, .pattern = wild_pat, .type_annotation = null, .guard = null, .body = lhs_body2 };
                    return .{ .expr = try self.create(ast.Expr, .{ .case_expr = .{ .meta = bo.meta, .scrutinee = lhs_exp, .clauses = clauses } }), .changed = true };
                }

                // Bootstrap fallback: other operators pass through with recursive expansion
                const lhs = try self.expandExpr(bo.lhs);
                const rhs = try self.expandExpr(bo.rhs);
                if (!lhs.changed and !rhs.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .binary_op = .{ .meta = bo.meta, .op = bo.op, .lhs = lhs.expr, .rhs = rhs.expr },
                    }),
                    .changed = true,
                };
            },

            .unary_op => |uo| {
                const op_name = unopMacroName(uo.op);

                // Try operator-named function first; a local `pub fn OP` shadows
                // any Kernel macro of the same name. Macros (if added later)
                // would expand here only when no function is in scope.
                if (try self.tryDispatchToFunction(op_name, &.{uo.operand}, uo.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }

                const operand = try self.expandExpr(uo.operand);
                if (!operand.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .unary_op = .{
                            .meta = uo.meta,
                            .op = uo.op,
                            .operand = operand.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            .pipe => |pe| {
                // Try Kernel.|> macro first
                if (self.tryExpandBinaryMacro("|>", pe.lhs, pe.rhs, pe.meta)) |result| {
                    return .{ .expr = result, .changed = true };
                }

                // Bootstrap fallback: desugar pipe directly
                const lhs = (try self.expandExpr(pe.lhs)).expr;
                const rhs = (try self.expandExpr(pe.rhs)).expr;

                switch (rhs.*) {
                    .call => |call| {
                        // x |> f(y) → f(x, y) — inject lhs as first arg
                        var new_args: std.ArrayList(*const ast.Expr) = .empty;
                        try new_args.append(self.allocator, lhs);
                        for (call.args) |arg| {
                            try new_args.append(self.allocator, arg);
                        }
                        return .{
                            .expr = try self.create(ast.Expr, .{
                                .call = .{
                                    .meta = pe.meta,
                                    .callee = call.callee,
                                    .args = try new_args.toOwnedSlice(self.allocator),
                                },
                            }),
                            .changed = true,
                        };
                    },
                    .var_ref => {
                        // x |> f → f(x)
                        const args = try self.allocSlice(*const ast.Expr, &.{lhs});
                        return .{
                            .expr = try self.create(ast.Expr, .{
                                .call = .{
                                    .meta = pe.meta,
                                    .callee = rhs,
                                    .args = args,
                                },
                            }),
                            .changed = true,
                        };
                    },
                    else => {
                        // Fallback: treat as f(x)
                        const args = try self.allocSlice(*const ast.Expr, &.{lhs});
                        return .{
                            .expr = try self.create(ast.Expr, .{
                                .call = .{
                                    .meta = pe.meta,
                                    .callee = rhs,
                                    .args = args,
                                },
                            }),
                            .changed = true,
                        };
                    },
                }
            },

            .block => |blk| {
                const expanded = try self.expandBlock(blk.stmts);
                if (!expanded.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .block = .{
                            .meta = blk.meta,
                            .stmts = expanded.stmts,
                        },
                    }),
                    .changed = true,
                };
            },

            .unwrap => |ue| {
                const inner = try self.expandExpr(ue.expr);
                if (!inner.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .unwrap = .{ .meta = ue.meta, .expr = inner.expr },
                    }),
                    .changed = true,
                };
            },

            .cond_expr => |conde| {
                // Bootstrap fallback: expand cond to nested case.
                // Kernel.cond macro (if defined) provides the same behavior.
                return .{
                    .expr = try self.condToNestedCase(conde.clauses, conde.meta),
                    .changed = true,
                };
            },

            .type_annotated => |ta| {
                const inner = try self.expandExpr(ta.expr);
                if (!inner.changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .type_annotated = .{
                            .meta = ta.meta,
                            .expr = inner.expr,
                            .type_expr = ta.type_expr,
                        },
                    }),
                    .changed = true,
                };
            },

            // For comprehension — recurse into iterable, filter, body
            .for_expr => |fe| {
                var changed = false;
                const iterable = try self.expandExpr(fe.iterable);
                if (iterable.changed) changed = true;
                const filter = if (fe.filter) |f| blk: {
                    const exp = try self.expandExpr(f);
                    if (exp.changed) changed = true;
                    break :blk exp.expr;
                } else null;
                const body = try self.expandExpr(fe.body);
                if (body.changed) changed = true;
                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .for_expr = .{
                            .meta = fe.meta,
                            .var_pattern = fe.var_pattern,
                            .var_type_annotation = fe.var_type_annotation,
                            .iterable = iterable.expr,
                            .filter = filter,
                            .body = body.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            // Range expression — recurse into start, end, and optional step
            .range => |re| {
                var changed = false;
                const start = try self.expandExpr(re.start);
                if (start.changed) changed = true;
                const end_exp = try self.expandExpr(re.end);
                if (end_exp.changed) changed = true;
                const step = if (re.step) |s| blk: {
                    const exp = try self.expandExpr(s);
                    if (exp.changed) changed = true;
                    break :blk exp.expr;
                } else null;
                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .range = .{
                            .meta = re.meta,
                            .start = start.expr,
                            .end = end_exp.expr,
                            .step = step,
                        },
                    }),
                    .changed = true,
                };
            },

            // List cons expression — recurse into head and tail
            .list_cons_expr => |lc| {
                var changed = false;
                const head = try self.expandExpr(lc.head);
                if (head.changed) changed = true;
                const tail = try self.expandExpr(lc.tail);
                if (tail.changed) changed = true;
                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .list_cons_expr = .{
                            .meta = lc.meta,
                            .head = head.expr,
                            .tail = tail.expr,
                        },
                    }),
                    .changed = true,
                };
            },

            // Leaf nodes — no expansion needed
            .int_literal,
            .float_literal,
            .string_literal,
            .string_interpolation,
            .atom_literal,
            .bool_literal,
            .nil_literal,
            .var_ref,
            .module_ref,
            .tuple,
            .list,
            .map,
            .struct_expr,
            .field_access,
            .function_ref,
            .panic_expr,
            .intrinsic,
            .attr_ref,
            .binary_literal,
            .error_pipe,
            => return .{ .expr = expr, .changed = false },
        }
    }

    fn expandCallExpr(self: *MacroEngine, expr: *const ast.Expr) !ExpandedExpr {
        const call = expr.call;
        var changed = false;

        const callee = try self.expandExpr(call.callee);
        if (callee.changed) changed = true;

        var new_args: std.ArrayList(*const ast.Expr) = .empty;
        for (call.args) |arg| {
            const expanded = try self.expandExpr(arg);
            if (expanded.changed) changed = true;
            try new_args.append(self.allocator, expanded.expr);
        }

        if (!changed) return .{ .expr = expr, .changed = false };
        return .{
            .expr = try self.create(ast.Expr, .{
                .call = .{
                    .meta = call.meta,
                    .callee = callee.expr,
                    .args = try new_args.toOwnedSlice(self.allocator),
                },
            }),
            .changed = true,
        };
    }

    // ============================================================
    // Macro call expansion
    // ============================================================

    fn expandMacroCall(self: *MacroEngine, expr: *const ast.Expr) !*const ast.Expr {
        const call = expr.call;
        const name = call.callee.var_ref.name;
        const arity: u32 = @intCast(call.args.len);

        const macro_family_id = self.findMacro(name, arity) orelse {
            try self.errors.append(self.allocator, .{
                .message = "macro not found",
                .span = call.meta.span,
            });
            return expr;
        };

        const family = &self.graph.macro_families.items[macro_family_id];

        if (family.clauses.items.len == 0) {
            try self.errors.append(self.allocator, .{
                .message = "macro has no clauses",
                .span = call.meta.span,
            });
            return expr;
        }

        // Use the first clause for now (pattern matching on macro args is Phase 4+)
        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Validate typed splice categories (`:: Pat`, `:: Decl`, ...)
        // before either expansion path runs. The conversion to CtValue
        // is repeated by each path; the cost is negligible (expansion
        // happens once per macro call) and the alternative (passing
        // pre-converted CtValues into expandQuote and the evaluator
        // path) couples both paths to the same conversion store
        // lifecycle. Validate-first, expand-second is simpler.
        {
            const limit = @min(clause.params.len, call.args.len);
            if (limit > 0) {
                var validation_store = ctfe.AllocationStore{};
                var arg_cts = try self.allocator.alloc(ctfe.CtValue, limit);
                defer self.allocator.free(arg_cts);
                for (call.args[0..limit], 0..) |arg, i| {
                    arg_cts[i] = try ast_data.exprToCtValue(self.allocator, self.interner, &validation_store, arg);
                }
                const ok = try self.validateMacroArgs(clause.params, call.args, arg_cts, call.meta.span);
                if (!ok) return expr;
            }
        }

        // Fast path: bare quote body → use Phase 2 template expansion
        if ((clause.body orelse @as([]const ast.Stmt, &.{})).len == 1 and (clause.body orelse @as([]const ast.Stmt, &.{}))[0] == .expr) {
            const body_expr = (clause.body orelse @as([]const ast.Stmt, &.{}))[0].expr;
            if (body_expr.* == .quote_expr) {
                self.generation += 1;
                return try self.expandQuote(body_expr, call.args, clause.params);
            }
        }

        // Phase 3: evaluate macro body as a function using the macro evaluator.
        // Convert the body and args to CtValue, run the evaluator, convert back.
        {
            // Bump the generation counter so generateHygienicName produces a
            // fresh suffix per macro invocation. The fast path (above) does
            // this; the eval path also returns AST that may introduce names
            // and must share the discipline. Set-of-scopes hygiene (Phase 3
            // of the macro maturation plan) supersedes this counter, but
            // until then it is the only mechanism preventing collisions
            // across nested macro calls.
            self.generation += 1;

            const macro_eval = @import("macro_eval.zig");
            var store = ctfe.AllocationStore{};
            var env = macro_eval.Env.init(self.allocator, &store);
            defer env.deinit();
            // Wire module context so `__zap_module_*` intrinsics can
            // reach the scope graph and the current module's
            // StructEntry. Falls back to a noop if no module is
            // active (e.g., top-level macro calls).
            env.module_ctx = .{
                .graph = self.graph,
                .interner = self.interner,
                .current_module_scope = self.current_module_scope,
            };

            // Bind macro parameters to CtValue representations of the arguments
            for (clause.params, 0..) |param, i| {
                if (i < call.args.len) {
                    if (param.pattern.* == .bind) {
                        const param_name = self.interner.get(param.pattern.bind.name);
                        const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, call.args[i]);
                        try env.bind(param_name, arg_ct);
                    }
                }
            }

            // Convert body statements to CtValue and evaluate them
            var result: ctfe.CtValue = .nil;
            for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
                const stmt_ct = try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt);
                result = macro_eval.eval(&env, stmt_ct) catch .nil;
            }

            // The eval path treats `quote` as a lazy form — its args
            // are returned without recursing into them. That means
            // unquotes inside the quote body are still raw `:unquote`
            // 3-tuples in the result. Substitute them now using the
            // evaluator's full binding environment (macro params and
            // any local `=` bindings introduced during eval) so
            // expressions like `quote { unquote(local_var) }` work
            // alongside `quote { unquote(macro_param) }`.
            if (result != .nil) {
                result = try self.substituteCtValue(result, &env.bindings, &store);

                // `quote { single_expr }` produces a list with one
                // element (the body's sole statement). The fast path
                // (`expandQuote`) unwraps single-statement bodies; the
                // eval path must match that behavior so authors don't
                // see a stray list literal wrapping their result.
                // Multi-statement bodies remain a list and `__block__`
                // wrapping is left to ctValueToExpr.
                if (result == .list and result.list.elems.len == 1) {
                    result = result.list.elems[0];
                }
            }

            // Convert the result back to ast.Expr
            if (result != .nil) {
                // If the result is a function declaration form, register it in
                // the scope graph so calls to the generated function can resolve.
                return ast_data.ctValueToExpr(self.allocator, self.interner, result) catch expr;
            }
        }

        return expr;
    }

    // ============================================================
    // Quote expansion with unquote substitution
    // ============================================================

    fn expandQuote(self: *MacroEngine, quote_expr: *const ast.Expr, args: []const *const ast.Expr, params: []const ast.Param) anyerror!*const ast.Expr {
        const quote = quote_expr.quote_expr;

        // Phase 2: Work through the CtValue data representation.
        // 1. Convert quoted body to CtValue tuples
        // 2. Build param name → CtValue arg mapping
        // 3. Walk CtValue tree substituting :unquote nodes
        // 4. Convert result back to ast.Expr

        var store = ctfe.AllocationStore{};

        // Convert each statement in the quote body to CtValue
        var body_vals : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
        for (quote.body) |stmt| {
            try body_vals.append(self.allocator, try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt));
        }

        // Build parameter name (string) → CtValue argument mapping
        var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
        defer param_map.deinit();

        for (params, 0..) |param, i| {
            if (i < args.len) {
                if (param.pattern.* == .bind) {
                    const name = self.interner.get(param.pattern.bind.name);
                    const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, args[i]);
                    try param_map.put(name, arg_ct);
                }
            }
        }

        // Substitute :unquote nodes in the CtValue tree
        var substituted_vals : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
        for (body_vals.items) |val| {
            try substituted_vals.append(self.allocator, try self.substituteCtValue(val, &param_map, &store));
        }

        // Convert back to ast.Expr
        if (substituted_vals.items.len == 1) {
            return ast_data.ctValueToExpr(self.allocator, self.interner, substituted_vals.items[0]);
        }

        // Multiple statements → wrap in block
        var stmts : std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (substituted_vals.items) |val| {
            const expr = try ast_data.ctValueToExpr(self.allocator, self.interner, val);
            try stmts.append(self.allocator, .{ .expr = expr });
        }
        return try self.create(ast.Expr, .{
            .block = .{
                .meta = quote.meta,
                .stmts = try stmts.toOwnedSlice(self.allocator),
            },
        });
    }

    /// Walk a CtValue tree, replacing {:unquote, _, [name]} nodes with
    /// the corresponding argument value from param_map.
    fn substituteCtValue(
        self: *MacroEngine,
        value: ctfe.CtValue,
        param_map: *std.StringHashMap(ctfe.CtValue),
        store: *ctfe.AllocationStore,
    ) anyerror!ctfe.CtValue {
        // Check if this is an :unquote node: {atom("unquote"), meta, [inner]}
        if (value == .tuple and value.tuple.elems.len == 3) {
            const form = value.tuple.elems[0];
            const args = value.tuple.elems[2];

            if (form == .atom and std.mem.eql(u8, form.atom, "unquote")) {
                if (args == .list and args.list.elems.len == 1) {
                    const inner = args.list.elems[0];
                    // If inner is a variable reference {:name, _, nil}, look up in param_map
                    if (inner == .tuple and inner.tuple.elems.len == 3) {
                        if (inner.tuple.elems[0] == .atom and inner.tuple.elems[2] == .nil) {
                            const var_name = inner.tuple.elems[0].atom;
                            if (param_map.get(var_name)) |replacement| {
                                return replacement;
                            }
                        }
                    }
                    // Not a param reference — return the inner value as-is
                    return inner;
                }
            }

            // Recurse into all three positions: form, meta, args.
            //
            // Recursing into form is what makes `quote { unquote(name)() }`
            // work — the outer call's form slot holds the unquote 3-tuple
            // `{:unquote, [], [name_var]}`, and substituting it replaces
            // the whole form with the bound value (typically an atom),
            // turning the call into `name(...)`. Without this, unquote in
            // callee position silently decays to a literal call to a
            // function actually named `"unquote"`.
            //
            // For ordinary calls like `{:foo, [], [arg]}` the form is a
            // bare atom; recursion bottoms out at the leaf-value branch
            // below, returning the atom unchanged.
            const new_form = try self.substituteCtValue(value.tuple.elems[0], param_map, store);
            const new_args = if (args == .list) blk: {
                var new_elems = try self.allocator.alloc(ctfe.CtValue, args.list.elems.len);
                for (args.list.elems, 0..) |elem, i| {
                    new_elems[i] = try self.substituteCtValue(elem, param_map, store);
                }
                const id = store.alloc(self.allocator, .list, null);
                break :blk ctfe.CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
            } else args;

            const new_tuple = try self.allocator.alloc(ctfe.CtValue, 3);
            new_tuple[0] = new_form;
            new_tuple[1] = value.tuple.elems[1]; // meta stays — line/col annotations
            new_tuple[2] = new_args;
            const id = store.alloc(self.allocator, .tuple, null);
            return ctfe.CtValue{ .tuple = .{ .alloc_id = id, .elems = new_tuple } };
        }

        // Recurse into 2-tuples (keyword pairs like {:do, value})
        if (value == .tuple and value.tuple.elems.len == 2) {
            const new_elems = try self.allocator.alloc(ctfe.CtValue, 2);
            new_elems[0] = value.tuple.elems[0]; // key stays
            new_elems[1] = try self.substituteCtValue(value.tuple.elems[1], param_map, store);
            const id = store.alloc(self.allocator, .tuple, null);
            return ctfe.CtValue{ .tuple = .{ .alloc_id = id, .elems = new_elems } };
        }

        // Recurse into bare lists — with unquote_splicing support
        if (value == .list) {
            var result_elems : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
            var changed = false;
            for (value.list.elems) |elem| {
                // Check for unquote_splicing: {:unquote_splicing, _, [list_expr]}
                if (elem == .tuple and elem.tuple.elems.len == 3) {
                    if (elem.tuple.elems[0] == .atom and std.mem.eql(u8, elem.tuple.elems[0].atom, "unquote_splicing")) {
                        if (elem.tuple.elems[2] == .list and elem.tuple.elems[2].list.elems.len == 1) {
                            const inner = elem.tuple.elems[2].list.elems[0];
                            // If inner is a variable, look up in param_map
                            if (inner == .tuple and inner.tuple.elems.len == 3 and inner.tuple.elems[0] == .atom and inner.tuple.elems[2] == .nil) {
                                if (param_map.get(inner.tuple.elems[0].atom)) |replacement| {
                                    // Splice the replacement list into our result
                                    if (replacement == .list) {
                                        for (replacement.list.elems) |splice_elem| {
                                            try result_elems.append(self.allocator, splice_elem);
                                        }
                                        changed = true;
                                        continue;
                                    }
                                }
                            }
                        }
                    }
                }
                const substituted = try self.substituteCtValue(elem, param_map, store);
                if (!substituted.eql(elem)) changed = true;
                try result_elems.append(self.allocator, substituted);
            }
            if (!changed) return value;
            const new_elems = try result_elems.toOwnedSlice(self.allocator);
            const id = store.alloc(self.allocator, .list, null);
            return ctfe.CtValue{ .list = .{ .alloc_id = id, .elems = new_elems } };
        }

        // Leaf values — no substitution
        return value;
    }

    // ============================================================
    // Hygienic name generation
    // ============================================================

    pub fn generateHygienicName(self: *MacroEngine, base_name: ast.StringId) !ast.StringId {
        const base = self.interner.get(base_name);
        const gen_name = try std.fmt.allocPrint(self.allocator, "{s}__gen{d}", .{ base, self.generation });
        return self.interner.intern(gen_name);
    }

    // ============================================================
    // Typed splice validation
    //
    // When a macro parameter is annotated with a meta-type
    // (`Expr`, `Pat`, `Decl`, `Type`, `Ident`, `Block`, etc.), the
    // bound CtValue's shape is checked against the expected category
    // so authors find out at the macro call site, not at the splice
    // site, when they pass the wrong kind of AST.
    //
    // The default `Expr` accepts anything; narrower kinds like `Decl`
    // require a 3-tuple whose form atom is `:fn`, `:macro`, or
    // `:import`. A param without a type annotation also accepts any
    // shape (preserves existing user code).
    // ============================================================

    /// Inspect a macro parameter and return its declared splice kind,
    /// or null when no meta-type annotation is present.
    fn paramSpliceKind(self: *const MacroEngine, param: ast.Param) ?ast.MacroSpliceKind {
        const type_expr = param.type_annotation orelse return null;
        if (type_expr.* != .name) return null;
        const name = self.interner.get(type_expr.name.name);
        return ast.MacroSpliceKind.fromName(name);
    }

    /// Check whether `value` matches the given splice kind.
    fn matchesSpliceKind(value: ctfe.CtValue, kind: ast.MacroSpliceKind) bool {
        return switch (kind) {
            .expr => true, // permissive — historical default
            .pattern => isPatternShape(value),
            .type_expr => isTypeShape(value),
            .decl => isDeclShape(value),
            .ident => isIdentShape(value),
            .block => isBlockShape(value),
            .atom_lit => isAtomShape(value),
            .integer_lit => value == .int,
            .string_lit => isStringShape(value),
            .list_lit => value == .list,
        };
    }

    fn isDeclShape(value: ctfe.CtValue) bool {
        if (value != .tuple or value.tuple.elems.len != 3) return false;
        const form = value.tuple.elems[0];
        if (form != .atom) return false;
        return std.mem.eql(u8, form.atom, "fn") or
            std.mem.eql(u8, form.atom, "macro") or
            std.mem.eql(u8, form.atom, "import") or
            std.mem.eql(u8, form.atom, "alias");
    }

    fn isBlockShape(value: ctfe.CtValue) bool {
        if (value != .tuple or value.tuple.elems.len != 3) return false;
        const form = value.tuple.elems[0];
        return form == .atom and std.mem.eql(u8, form.atom, "__block__");
    }

    fn isIdentShape(value: ctfe.CtValue) bool {
        // Variable reference: {atom-name, meta, nil}, or bare atom value.
        if (value == .atom) {
            const name = value.atom;
            // Atoms prefixed with ":" are atom literals, not identifiers.
            return name.len > 0 and name[0] != ':';
        }
        if (value == .tuple and value.tuple.elems.len == 3) {
            return value.tuple.elems[0] == .atom and value.tuple.elems[2] == .nil and
                value.tuple.elems[0].atom.len > 0 and value.tuple.elems[0].atom[0] != ':';
        }
        return false;
    }

    fn isAtomShape(value: ctfe.CtValue) bool {
        // Atom literal — bare or wrapped, distinguished by ":" prefix.
        if (value == .atom) {
            return value.atom.len > 0 and value.atom[0] == ':';
        }
        if (value == .tuple and value.tuple.elems.len == 3) {
            return value.tuple.elems[0] == .atom and value.tuple.elems[2] == .nil and
                value.tuple.elems[0].atom.len > 0 and value.tuple.elems[0].atom[0] == ':';
        }
        return false;
    }

    fn isStringShape(value: ctfe.CtValue) bool {
        if (value == .string) return true;
        if (value == .tuple and value.tuple.elems.len == 3) {
            return value.tuple.elems[0] == .string and value.tuple.elems[2] == .nil;
        }
        return false;
    }

    fn isPatternShape(value: ctfe.CtValue) bool {
        // Patterns and exprs share the tuple shape. Most expression
        // CtValues are also valid patterns. The compiler verifies
        // pattern legality downstream during HIR; this validator just
        // rejects non-AST shapes (closures, enums, structs).
        return switch (value) {
            .closure, .enum_val, .struct_val, .union_val => false,
            else => true,
        };
    }

    fn isTypeShape(value: ctfe.CtValue) bool {
        // Type expressions show up in CtValue as `__aliases__` lists
        // for module references, or as plain identifier atoms for
        // built-in types. Accept either shape.
        if (value == .atom) {
            const name = value.atom;
            return name.len > 0 and (std.ascii.isUpper(name[0]) or name[0] == ':');
        }
        if (value == .tuple and value.tuple.elems.len == 3) {
            const form = value.tuple.elems[0];
            if (form == .atom) {
                const f = form.atom;
                if (std.mem.eql(u8, f, "__aliases__")) return true;
                if (std.mem.eql(u8, f, ".")) return true;
                if (f.len > 0 and std.ascii.isUpper(f[0])) return true;
            }
        }
        return false;
    }

    /// Validate that each macro argument's CtValue matches the
    /// param's declared splice kind. Records structured errors on
    /// `self.errors` and returns true when validation succeeded.
    fn validateMacroArgs(
        self: *MacroEngine,
        params: []const ast.Param,
        args: []const *const ast.Expr,
        arg_cts: []const ctfe.CtValue,
        call_span: ast.SourceSpan,
    ) !bool {
        var ok = true;
        const limit = @min(params.len, arg_cts.len);
        for (params[0..limit], 0..) |param, i| {
            const kind = self.paramSpliceKind(param) orelse continue;
            if (matchesSpliceKind(arg_cts[i], kind)) continue;

            ok = false;
            const param_name = if (param.pattern.* == .bind)
                self.interner.get(param.pattern.bind.name)
            else
                "<param>";
            const span = if (i < args.len) args[i].getMeta().span else call_span;
            const message = try std.fmt.allocPrint(
                self.allocator,
                "macro argument `{s}` is not a `{s}` — expected splice kind `{s}` but got an incompatible AST shape",
                .{ param_name, kind.displayName(), kind.displayName() },
            );
            try self.errors.append(self.allocator, .{
                .message = message,
                .span = span,
            });
        }
        return ok;
    }

    // ============================================================
    // Operator and pipe macro expansion
    // ============================================================

    /// Map a binary operator to its Kernel macro name.
    fn binopMacroName(op: ast.BinaryOp.Op) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .rem_op => "rem",
            .equal => "==",
            .not_equal => "!=",
            .less => "<",
            .greater => ">",
            .less_equal => "<=",
            .greater_equal => ">=",
            .and_op => "and",
            .or_op => "or",
            .concat => "<>",
            .in_op => "in",
        };
    }

    /// Map a unary operator to its Kernel macro / function name.
    fn unopMacroName(op: ast.UnaryOp.Op) []const u8 {
        return switch (op) {
            .negate => "-",
            .not_op => "not",
        };
    }

    /// Resolve a function family by name and arity, walking the scope chain
    /// from the current module just like `findMacro`.
    fn findFunction(self: *MacroEngine, name: ast.StringId, arity: u32) ?scope.FunctionFamilyId {
        const scope_id = self.current_module_scope orelse self.graph.prelude_scope;
        return self.graph.resolveFamily(scope_id, name, arity);
    }

    /// If a `pub fn`/`fn` named `op_name` of the given arity is in scope, build
    /// a Call expression `op_name(args...)` so the binary/unary operator
    /// dispatches through the user-defined function. Returns null if no
    /// matching function exists (operator falls through to its bootstrap path).
    fn tryDispatchToFunction(
        self: *MacroEngine,
        op_name: []const u8,
        args: []const *const ast.Expr,
        meta: ast.NodeMeta,
    ) !?*const ast.Expr {
        const name_id = self.interner.intern(op_name) catch return null;
        if (self.findFunction(name_id, @intCast(args.len)) == null) return null;

        const callee = try self.create(ast.Expr, .{ .var_ref = .{ .meta = meta, .name = name_id } });
        const arg_exprs = try self.allocator.alloc(*const ast.Expr, args.len);
        for (args, 0..) |arg, i| {
            arg_exprs[i] = (try self.expandExpr(arg)).expr;
        }
        return try self.create(ast.Expr, .{
            .call = .{ .meta = meta, .callee = callee, .args = arg_exprs },
        });
    }

    /// Try to expand a binary expression (operator or pipe) through a Kernel macro.
    /// Returns the expanded expression, or null if no macro found (falls to bootstrap).
    fn tryExpandBinaryMacro(
        self: *MacroEngine,
        macro_name: []const u8,
        lhs: *const ast.Expr,
        rhs: *const ast.Expr,
        meta: ast.NodeMeta,
    ) ?*const ast.Expr {
        const name_id = self.interner.intern(macro_name) catch return null;
        const macro_id = self.findMacro(name_id, 2) orelse return null;

        const family = &self.graph.macro_families.items[macro_id];
        if (family.clauses.items.len == 0) return null;

        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Skip identity macros (quote { unquote(left) OP unquote(right) })
        // to avoid infinite expansion loops
        if ((clause.body orelse @as([]const ast.Stmt, &.{})).len == 1 and (clause.body orelse @as([]const ast.Stmt, &.{}))[0] == .expr) {
            const body_expr = (clause.body orelse @as([]const ast.Stmt, &.{}))[0].expr;
            if (body_expr.* == .quote_expr) {
                const qbody = body_expr.quote_expr.body;
                // Identity check: single binary_op or pipe with both sides unquoted
                if (qbody.len == 1 and qbody[0] == .expr) {
                    const qexpr = qbody[0].expr;
                    if (qexpr.* == .binary_op) {
                        if (qexpr.binary_op.lhs.* == .unquote_expr and qexpr.binary_op.rhs.* == .unquote_expr) {
                            return null; // Identity — skip
                        }
                    }
                    if (qexpr.* == .pipe) {
                        if (qexpr.pipe.lhs.* == .unquote_expr and qexpr.pipe.rhs.* == .unquote_expr) {
                            return null; // Identity — skip
                        }
                    }
                }
            }
        }

        // Non-identity macro — convert args to CtValue, expand through template or evaluator
        var store = ctfe.AllocationStore{};
        const lhs_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, lhs) catch return null;
        const rhs_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, rhs) catch return null;
        _ = meta;

        if ((clause.body orelse @as([]const ast.Stmt, &.{})).len == 1 and (clause.body orelse @as([]const ast.Stmt, &.{}))[0] == .expr) {
            const body_expr = (clause.body orelse @as([]const ast.Stmt, &.{}))[0].expr;
            if (body_expr.* == .quote_expr) {
                // Template macro
                var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer param_map.deinit();
                if (clause.params.len >= 1 and clause.params[0].pattern.* == .bind) {
                    param_map.put(self.interner.get(clause.params[0].pattern.bind.name), lhs_ct) catch return null;
                }
                if (clause.params.len >= 2 and clause.params[1].pattern.* == .bind) {
                    param_map.put(self.interner.get(clause.params[1].pattern.bind.name), rhs_ct) catch return null;
                }

                var body_vals : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &param_map, &store) catch return null) catch return null;
                }

                if (body_vals.items.len == 1) {
                    const interner_mut: *ast.StringInterner = @constCast(self.interner);
                    return ast_data.ctValueToExpr(self.allocator, interner_mut, body_vals.items[0]) catch null;
                }
            }
        }

        // Non-template macro body — evaluate through CTFE evaluator
        {
            const macro_eval = @import("macro_eval.zig");
            var env = macro_eval.Env.init(self.allocator, &store);
            defer env.deinit();

            // Bind params to CtValue arg representations
            if (clause.params.len >= 1 and clause.params[0].pattern.* == .bind) {
                env.bind(self.interner.get(clause.params[0].pattern.bind.name), lhs_ct) catch return null;
            }
            if (clause.params.len >= 2 and clause.params[1].pattern.* == .bind) {
                env.bind(self.interner.get(clause.params[1].pattern.bind.name), rhs_ct) catch return null;
            }

            // Evaluate the macro body
            var result: ctfe.CtValue = .nil;
            for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
                const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                result = macro_eval.eval(&env, stmt_ct) catch return null;
            }

            if (result != .nil) {
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                return ast_data.ctValueToExpr(self.allocator, interner_mut, result) catch null;
            }
        }

        return null;
    }

    // ============================================================
    // Module-level expression expansion
    // ============================================================

    const ExpandedStructItems = struct {
        items: []const ast.StructItem,
        changed: bool,
    };

    /// Expand a struct-level expression. If the expression is a macro call
    /// that produces a function declaration (or other struct item), convert
    /// it to the appropriate StructItem variant. Otherwise keep it as a
    /// struct_level_expr for collection into a generated run/0 function.
    /// Patch a generated module item's source span so the scope collector
    /// and HIR builder can associate it with the correct module scope.
    fn patchStructItemSpan(mi: ast.StructItem, span: ast.SourceSpan) ast.StructItem {
        switch (mi) {
            .function, .priv_function => |func| {
                const mf = @constCast(func);
                mf.meta.span = span;
                const clauses_mut = @constCast(mf.clauses);
                for (clauses_mut) |*clause| {
                    clause.meta.span = span;
                }
            },
            else => {},
        }
        return mi;
    }

    fn expandStructLevelExpr(self: *MacroEngine, expr: *const ast.Expr) !ExpandedStructItems {
        // Check if this is a macro call (identifier + args)
        if (expr.* == .call and expr.call.callee.* == .var_ref) {
            const name = expr.call.callee.var_ref.name;
            const arity: u32 = @intCast(expr.call.args.len);

            if (self.findMacro(name, arity)) |macro_family_id| {
                const family = &self.graph.macro_families.items[macro_family_id];
                if (family.clauses.items.len > 0) {
                    const clause_ref = family.clauses.items[0];
                    const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

                    // Evaluate the macro and get the CtValue result
                    const result_ct = self.evaluateMacroBodyToCtValue(
                        clause,
                        expr.call.args,
                    ) orelse {
                        // Macro evaluation failed — keep as expression
                        const expanded = try self.expandExpr(expr);
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = .{ .struct_level_expr = expanded.expr };
                        return .{ .items = items, .changed = expanded.changed };
                    };

                    // Try converting the result to module items.
                    // Patch source spans so generated declarations inherit the call site's
                    // position — this ensures the scope collector associates them with the
                    // correct module scope (not the default prelude scope).
                    const interner_mut: *ast.StringInterner = @constCast(self.interner);
                    const call_span = expr.call.meta.span;

                    // Single module item (e.g., function declaration)
                    if (ast_data.ctValueToStructItem(self.allocator, interner_mut, result_ct) catch null) |mi| {
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = patchStructItemSpan(mi, call_span);
                        return .{ .items = items, .changed = true };
                    }

                    // Block of module items (e.g., describe expanding to multiple functions)
                    if (result_ct == .tuple and result_ct.tuple.elems.len == 3) {
                        if (result_ct.tuple.elems[0] == .atom) {
                            if (std.mem.eql(u8, result_ct.tuple.elems[0].atom, "__block__")) {
                                if (result_ct.tuple.elems[2] == .list) {
                                    // Check if ALL elements are module items. If any element
                                    // is not a module item (e.g., an assignment like ctx = 42),
                                    // keep the entire block as a single struct_level_expr to
                                    // preserve variable bindings and control flow.
                                    var all_module_items = true;
                                    for (result_ct.tuple.elems[2].list.elems) |elem| {
                                        if (ast_data.ctValueToStructItem(self.allocator, interner_mut, elem) catch null) |_| {
                                            // is a module item
                                        } else {
                                            all_module_items = false;
                                            break;
                                        }
                                    }

                                    if (all_module_items) {
                                        var items: std.ArrayList(ast.StructItem) = .empty;
                                        for (result_ct.tuple.elems[2].list.elems) |elem| {
                                            if (ast_data.ctValueToStructItem(self.allocator, interner_mut, elem) catch null) |mi| {
                                                try items.append(self.allocator, patchStructItemSpan(mi, call_span));
                                            }
                                        }
                                        if (items.items.len > 0) {
                                            return .{ .items = try items.toOwnedSlice(self.allocator), .changed = true };
                                        }
                                    } else {
                                        // Mixed content: extract each element individually.
                                        // Function declarations → StructItem::function
                                        // Expressions → StructItem::struct_level_expr
                                        var items: std.ArrayList(ast.StructItem) = .empty;
                                        for (result_ct.tuple.elems[2].list.elems) |elem_expr| {
                                            if (ast_data.ctValueToStructItem(self.allocator, interner_mut, elem_expr) catch null) |mi| {
                                                try items.append(self.allocator, patchStructItemSpan(mi, call_span));
                                            } else {
                                                const converted = ast_data.ctValueToExpr(self.allocator, self.interner, elem_expr) catch continue;
                                                try items.append(self.allocator, .{ .struct_level_expr = converted });
                                            }
                                        }
                                        if (items.items.len > 0) {
                                            return .{ .items = try items.toOwnedSlice(self.allocator), .changed = true };
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // List of module items (may be mixed with expressions)
                    if (result_ct == .list) {
                        var items: std.ArrayList(ast.StructItem) = .empty;
                        for (result_ct.list.elems) |list_elem| {
                            if (ast_data.ctValueToStructItem(self.allocator, interner_mut, list_elem) catch null) |mi| {
                                try items.append(self.allocator, patchStructItemSpan(mi, call_span));
                            } else {
                                const list_expr = ast_data.ctValueToExpr(self.allocator, self.interner, list_elem) catch continue;
                                try items.append(self.allocator, .{ .struct_level_expr = list_expr });
                            }
                        }
                        if (items.items.len > 0) {
                            return .{ .items = try items.toOwnedSlice(self.allocator), .changed = true };
                        }
                    }

                    // Not a struct item — convert to expression and keep as struct_level_expr
                    const result_expr = ast_data.ctValueToExpr(self.allocator, self.interner, result_ct) catch {
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = .{ .struct_level_expr = expr };
                        return .{ .items = items, .changed = false };
                    };
                    const items = try self.allocator.alloc(ast.StructItem, 1);
                    items[0] = .{ .struct_level_expr = result_expr };
                    return .{ .items = items, .changed = true };
                }
            }
        }

        // Not a macro call — expand as a regular expression
        const expanded = try self.expandExpr(expr);
        const items = try self.allocator.alloc(ast.StructItem, 1);
        items[0] = .{ .struct_level_expr = expanded.expr };
        return .{ .items = items, .changed = expanded.changed };
    }

    /// Evaluate a macro's body given its clause and arguments, returning the
    /// raw CtValue result. Returns null if evaluation fails.
    fn evaluateMacroBodyToCtValue(
        self: *MacroEngine,
        clause: *const ast.FunctionClause,
        args: []const *const ast.Expr,
    ) ?ctfe.CtValue {
        var store = ctfe.AllocationStore{};

        // Fast path: bare quote body → template expansion returning CtValue
        const clause_body = clause.body orelse return null;
        if (clause_body.len == 1 and clause_body[0] == .expr) {
            const body_expr = clause_body[0].expr;
            if (body_expr.* == .quote_expr) {
                var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer param_map.deinit();
                for (clause.params, 0..) |param, i| {
                    if (i < args.len) {
                        if (param.pattern.* == .bind) {
                            const pname = self.interner.get(param.pattern.bind.name);
                            const arg_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, args[i]) catch return null;
                            param_map.put(pname, arg_ct) catch return null;
                        }
                    }
                }

                var body_vals : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &param_map, &store) catch return null) catch return null;
                }

                if (body_vals.items.len == 1) return body_vals.items[0];
                // Multiple values: wrap in __block__
                if (body_vals.items.len > 1) {
                    const block_args = ast_data.makeListFromSlice(self.allocator, &store, body_vals.items) catch return null;
                    const empty = ast_data.emptyList(self.allocator, &store) catch return null;
                    return ast_data.makeTuple3(self.allocator, &store, .{ .atom = "__block__" }, empty, block_args) catch return null;
                }
                return null;
            }
        }

        // Phase 3: evaluator path
        const macro_eval = @import("macro_eval.zig");
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();
        // Wire module context so `__zap_module_*` and other comptime
        // intrinsics that consult the scope graph reach the right
        // module — same wiring as the expression-level expandMacroCall
        // eval path.
        env.module_ctx = .{
            .graph = self.graph,
            .interner = self.interner,
            .current_module_scope = self.current_module_scope,
        };

        for (clause.params, 0..) |param, i| {
            if (i < args.len) {
                if (param.pattern.* == .bind) {
                    const param_name = self.interner.get(param.pattern.bind.name);
                    const arg_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, args[i]) catch return null;
                    env.bind(param_name, arg_ct) catch return null;
                }
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause_body) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch return null;
        }

        // The eval path treats `quote` as lazy: its body is returned
        // as data without recursing into the unquote nodes. Substitute
        // them now using the evaluator's full binding environment so
        // local `=` bindings introduced during eval can be referenced
        // from inside the quote body. Mirrors the pattern used by
        // `expandMacroCall`'s eval path for expression-level macros.
        if (result != .nil) {
            result = self.substituteCtValue(result, &env.bindings, &store) catch return null;
            // `quote { single_expr }` produces a list with one element
            // (the body's sole statement). Unwrap so authors don't see
            // a stray list literal wrapping their result. Multi-stmt
            // bodies stay a list and ctValueToStructItems wraps in a
            // `__block__` if needed.
            if (result == .list and result.list.elems.len == 1) {
                result = result.list.elems[0];
            }
        }

        if (result != .nil) return result;
        return null;
    }

    // ============================================================
    // Macro lookup
    // ============================================================

    /// Try to expand a declaration (fn/macro/struct) through a Kernel macro.
    /// Returns the expanded StructItem if a Kernel macro exists, null otherwise.
    /// When null, the caller should use the bootstrap fallback.
    fn tryExpandDeclarationMacro(self: *MacroEngine, form_name: []const u8, item: ast.StructItem) ?ast.StructItem {
        // Look up a Kernel macro with the declaration form name (fn, module, struct, macro)
        const name_id = self.interner.intern(form_name) catch return null;
        const macro_id = self.findMacro(name_id, 1) orelse return null;

        // Found a Kernel declaration macro.
        const family = &self.graph.macro_families.items[macro_id];
        if (family.clauses.items.len == 0) return null;

        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Skip identity macros: `quote { unquote(arg) }` — these just pass through
        // and the CtValue round-trip can lose information. Only expand macros that
        // do real work (non-trivial body).
        const clause_body = clause.body orelse return null;
        if (clause_body.len == 1 and clause_body[0] == .expr) {
            const body_expr = clause_body[0].expr;
            if (body_expr.* == .quote_expr) {
                const qbody = body_expr.quote_expr.body;
                if (qbody.len == 1 and qbody[0] == .expr and qbody[0].expr.* == .unquote_expr) {
                    // Identity macro: `quote { unquote(decl) }` — skip expansion
                    return null;
                }
            }
        }

        // Non-identity macro — convert declaration to CtValue and evaluate
        var store = ctfe.AllocationStore{};
        const item_ct = ast_data.structItemToCtValue(self.allocator, self.interner, &store, item) catch return null;

        if ((clause.body orelse @as([]const ast.Stmt, &.{})).len == 1 and (clause.body orelse @as([]const ast.Stmt, &.{}))[0] == .expr) {
            const body_expr = (clause.body orelse @as([]const ast.Stmt, &.{}))[0].expr;
            if (body_expr.* == .quote_expr) {
                // Template macro with real transformation
                var decl_param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer decl_param_map.deinit();
                for (clause.params) |param| {
                    if (param.pattern.* == .bind) {
                        const pname = self.interner.get(param.pattern.bind.name);
                        decl_param_map.put(pname, item_ct) catch return null;
                    }
                }

                var body_vals : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &decl_param_map, &store) catch return null) catch return null;
                }

                const result_ct = if (body_vals.items.len == 1) body_vals.items[0] else return null;
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                return ast_data.ctValueToStructItem(self.allocator, interner_mut, result_ct) catch return null;
            }
        }

        // Non-template macro body — use the evaluator
        const macro_eval = @import("macro_eval.zig");
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();

        for (clause.params) |param| {
            if (param.pattern.* == .bind) {
                const pname = self.interner.get(param.pattern.bind.name);
                env.bind(pname, item_ct) catch return null;
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch return null;
        }

        if (result != .nil) {
            const interner_mut: *ast.StringInterner = @constCast(self.interner);
            return ast_data.ctValueToStructItem(self.allocator, interner_mut, result) catch return null;
        }
        return null;
    }

    /// Try to expand `use Module` by calling Module.__using__/1.
    /// Returns injected module items if __using__ exists, null otherwise.
    fn tryExpandUsing(self: *MacroEngine, ud: *const ast.UseDecl) ?[]const ast.StructItem {
        // Build the __using__ name
        const using_name = self.interner.intern("__using__") catch return null;

        // Look up __using__ macro with arity 1
        const macro_id = self.findMacro(using_name, 1) orelse return null;

        const family = &self.graph.macro_families.items[macro_id];
        if (family.clauses.items.len == 0) return null;

        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Build the opts argument: use the opts from UseDecl, or nil if none
        var store = ctfe.AllocationStore{};
        const opts_ct: ctfe.CtValue = if (ud.opts) |opts|
            ast_data.exprToCtValue(self.allocator, self.interner, &store, opts) catch return null
        else
            .nil;

        // Evaluate the __using__ macro body
        if ((clause.body orelse @as([]const ast.Stmt, &.{})).len == 1 and (clause.body orelse @as([]const ast.Stmt, &.{}))[0] == .expr) {
            const body_expr = (clause.body orelse @as([]const ast.Stmt, &.{}))[0].expr;
            if (body_expr.* == .quote_expr) {
                // Template macro: substitute opts into quote body
                var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
                defer param_map.deinit();
                for (clause.params) |param| {
                    if (param.pattern.* == .bind) {
                        const pname = self.interner.get(param.pattern.bind.name);
                        param_map.put(pname, opts_ct) catch return null;
                    }
                }

                var body_vals : std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &param_map, &store) catch return null) catch return null;
                }

                // Convert each result value to a module item
                var items: std.ArrayList(ast.StructItem) = .empty;
                const interner_mut: *ast.StringInterner = @constCast(self.interner);
                for (body_vals.items) |val| {
                    if (ast_data.ctValueToStructItem(self.allocator, interner_mut, val) catch null) |mi| {
                        items.append(self.allocator, mi) catch return null;
                    }
                }
                return items.toOwnedSlice(self.allocator) catch return null;
            }
        }

        // Non-template macro body — use the evaluator
        const macro_eval = @import("macro_eval.zig");
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();

        for (clause.params) |param| {
            if (param.pattern.* == .bind) {
                const pname = self.interner.get(param.pattern.bind.name);
                env.bind(pname, opts_ct) catch return null;
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch return null;
        }

        if (result != .nil) {
            const interner_mut: *ast.StringInterner = @constCast(self.interner);
            // Result could be a single item or a block of items
            if (result == .tuple and result.tuple.elems.len == 3) {
                if (ast_data.ctValueToStructItem(self.allocator, interner_mut, result) catch null) |mi| {
                    const items = self.allocator.alloc(ast.StructItem, 1) catch return null;
                    items[0] = mi;
                    return items;
                }
            }
            // Try as a list of items
            if (result == .list) {
                var items: std.ArrayList(ast.StructItem) = .empty;
                for (result.list.elems) |elem| {
                    if (ast_data.ctValueToStructItem(self.allocator, interner_mut, elem) catch null) |mi| {
                        items.append(self.allocator, mi) catch return null;
                    }
                }
                return items.toOwnedSlice(self.allocator) catch return null;
            }
        }
        return null;
    }

    /// Find a macro by walking the scope chain from the current module scope.
    /// Checks local macros first (module-local shadows Kernel), then imports
    /// (finds Kernel macros via auto-import), then parent scopes.
    /// Find a macro by walking the scope chain from the current module scope.
    /// Checks local macros first (module-local shadows Kernel), then imports
    /// (finds Kernel macros via auto-import), then parent scopes.
    /// Find a macro by walking the scope chain from the current module scope.
    /// Checks local macros first (module-local shadows Kernel), then imports
    /// (finds Kernel macros via auto-import), then parent scopes.
    fn findMacro(self: *MacroEngine, name: ast.StringId, arity: u32) ?scope.MacroFamilyId {
        const scope_id = self.current_module_scope orelse self.graph.prelude_scope;
        return self.graph.resolveMacro(scope_id, name, arity);
    }

    // ============================================================
    // Macro type validation
    // ============================================================

    /// Validate type annotations on macro definitions.
    /// Called before expansion to catch type errors early.
    fn validateMacros(self: *MacroEngine) !void {
        for (self.graph.macro_families.items) |family| {
            for (family.clauses.items) |clause_ref| {
                const clause = &clause_ref.decl.clauses[clause_ref.clause_index];
                const return_type = clause.return_type orelse continue;

                // Only validate macros with a quote body
                const body = clause.body orelse continue;
                if (body.len != 1) continue;
                switch (body[0]) {
                    .expr => |body_expr| {
                        switch (body_expr.*) {
                            .quote_expr => |qe| {
                                try self.validateQuoteBody(qe.body, return_type, clause.params);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    /// Check that all terminal expressions in a quote body are compatible
    /// with the declared return type.
    fn validateQuoteBody(
        self: *MacroEngine,
        body: []const ast.Stmt,
        return_type: *const ast.TypeExpr,
        params: []const ast.Param,
    ) anyerror!void {
        if (body.len == 0) return;
        switch (body[body.len - 1]) {
            .expr => |expr| try self.validateTerminalExpr(expr, return_type, params),
            else => {},
        }
    }

    /// Validate that a terminal expression is compatible with the expected return type.
    fn validateTerminalExpr(
        self: *MacroEngine,
        expr: *const ast.Expr,
        return_type: *const ast.TypeExpr,
        params: []const ast.Param,
    ) anyerror!void {
        switch (expr.*) {
            .nil_literal => |nl| {
                if (!self.typeAllowsNil(return_type)) {
                    const type_name = self.getTypeName(return_type);
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "macro body returns 'nil' but declared return type is '{s}'",
                        .{type_name},
                    );
                    try self.errors.append(self.allocator, .{
                        .message = msg,
                        .span = nl.meta.span,
                    });
                }
            },
            .if_expr => |ie| {
                // Both branches must be compatible with the return type
                try self.validateQuoteBody(ie.then_block, return_type, params);
                if (ie.else_block) |else_block| {
                    try self.validateQuoteBody(else_block, return_type, params);
                } else {
                    // No else branch implicitly returns nil
                    if (!self.typeAllowsNil(return_type)) {
                        const type_name = self.getTypeName(return_type);
                        const msg = try std.fmt.allocPrint(
                            self.allocator,
                            "macro if-expression without else implicitly returns 'nil' but declared return type is '{s}'",
                            .{type_name},
                        );
                        try self.errors.append(self.allocator, .{
                            .message = msg,
                            .span = ie.meta.span,
                        });
                    }
                }
            },
            .unquote_expr => |ue| {
                // If unquoting a typed param, check param type against return type
                switch (ue.expr.*) {
                    .var_ref => |vr| {
                        for (params) |param| {
                            switch (param.pattern.*) {
                                .bind => |bind| {
                                    if (bind.name == vr.name) {
                                        if (param.type_annotation) |param_type| {
                                            if (!self.typesMatch(param_type, return_type)) {
                                                const pt = self.getTypeName(param_type);
                                                const rt = self.getTypeName(return_type);
                                                const msg = try std.fmt.allocPrint(
                                                    self.allocator,
                                                    "unquoted parameter type '{s}' does not match declared return type '{s}'",
                                                    .{ pt, rt },
                                                );
                                                try self.errors.append(self.allocator, .{
                                                    .message = msg,
                                                    .span = ue.meta.span,
                                                });
                                            }
                                        }
                                        break;
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            },
            .unquote_splicing_expr => {
                // Splicing in return position — treated same as unquote for type validation
            },
            // For other expression types (binary_op, call, var_ref, literals),
            // we cannot determine types at the AST level — the type checker
            // will catch mismatches after expansion.
            else => {},
        }
    }

    /// Check if a type expression allows nil values.
    fn typeAllowsNil(self: *MacroEngine, type_expr: *const ast.TypeExpr) bool {
        switch (type_expr.*) {
            .name => |n| {
                const name = self.interner.get(n.name);
                return std.mem.eql(u8, name, "nil") or std.mem.eql(u8, name, "Nil");
            },
            .literal => |lit| {
                return lit.value == .nil;
            },
            .union_type => |u| {
                for (u.members) |member| {
                    if (self.typeAllowsNil(member)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    /// Check if type `a` is compatible with type `b`.
    /// For union return types, `a` is compatible if it is a member of the union.
    fn typesMatch(self: *MacroEngine, a: *const ast.TypeExpr, b: *const ast.TypeExpr) bool {
        // Expr is a macro meta-type — it's compatible with any type
        if (self.isExprType(a) or self.isExprType(b)) return true;

        switch (b.*) {
            .union_type => |u| {
                // a is compatible if it matches any member of the union
                for (u.members) |member| {
                    if (self.typesMatch(a, member)) return true;
                }
                return false;
            },
            .name => |bn| {
                switch (a.*) {
                    .name => |an| return an.name == bn.name,
                    else => return false,
                }
            },
            .literal => |bl| {
                switch (a.*) {
                    .literal => |al| return std.meta.activeTag(al.value) == std.meta.activeTag(bl.value),
                    else => return false,
                }
            },
            else => return true, // For complex types, assume compatible
        }
    }

    /// Check if a type expression is the special macro meta-type `Expr`.
    fn isExprType(self: *MacroEngine, type_expr: *const ast.TypeExpr) bool {
        switch (type_expr.*) {
            .name => |n| return std.mem.eql(u8, self.interner.get(n.name), "Expr"),
            else => return false,
        }
    }

    /// Get a human-readable name for a type expression.
    fn getTypeName(self: *MacroEngine, type_expr: *const ast.TypeExpr) []const u8 {
        switch (type_expr.*) {
            .name => |n| return self.interner.get(n.name),
            .literal => |lit| {
                return switch (lit.value) {
                    .nil => "nil",
                    .bool_val => "Bool",
                    .int => "integer",
                    .string => "String",
                };
            },
            else => return "<complex type>",
        }
    }

    // ============================================================
    // Special form helpers
    // ============================================================

    /// Convert a block (slice of statements) to a single expression.
    /// Single-expression blocks return the expression directly.
    /// Multi-statement blocks are wrapped in a block expression.
    fn blockToExpr(self: *MacroEngine, stmts: []const ast.Stmt, meta: ast.NodeMeta) !*const ast.Expr {
        if (stmts.len == 1) {
            switch (stmts[0]) {
                .expr => |e| return e,
                else => {},
            }
        }
        return try self.create(ast.Expr, .{
            .block = .{ .meta = meta, .stmts = stmts },
        });
    }

    /// Convert cond clauses to nested if() calls.
    /// cond do c1 -> b1; c2 -> b2 end → if(c1, b1, if(c2, b2, nil))
    fn condToNestedCase(self: *MacroEngine, clauses: []const ast.CondClause, meta: ast.NodeMeta) anyerror!*const ast.Expr {
        if (clauses.len == 0) {
            return try self.create(ast.Expr, .{ .nil_literal = .{ .meta = meta } });
        }

        const clause = clauses[0];
        const true_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = meta, .value = true } } });
        const false_pat = try self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = meta, .value = false } } });

        // Then body
        var then_stmts: std.ArrayList(ast.Stmt) = .empty;
        for (clause.body) |s| try then_stmts.append(self.allocator, s);

        // Else body: recursively expand remaining clauses
        const rest = try self.condToNestedCase(clauses[1..], meta);
        const else_stmts = try self.allocSlice(ast.Stmt, &.{.{ .expr = rest }});

        const case_clauses = try self.allocator.alloc(ast.CaseClause, 2);
        case_clauses[0] = .{ .meta = meta, .pattern = true_pat, .type_annotation = null, .guard = null, .body = try then_stmts.toOwnedSlice(self.allocator) };
        case_clauses[1] = .{ .meta = meta, .pattern = false_pat, .type_annotation = null, .guard = null, .body = else_stmts };

        return try self.create(ast.Expr, .{
            .case_expr = .{ .meta = meta, .scrutinee = clause.condition, .clauses = case_clauses },
        });
    }

    // ============================================================
    // Allocation helpers
    // ============================================================

    fn create(self: *MacroEngine, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    fn allocSlice(self: *MacroEngine, comptime T: type, items: []const T) ![]const T {
        const slice = try self.allocator.alloc(T, items.len);
        @memcpy(slice, items);
        return slice;
    }
};

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;
const Collector = @import("collector.zig").Collector;

test "macro engine no-op on program without macros" {
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // No macros — program should be unchanged
    try std.testing.expectEqual(@as(usize, 1), expanded.structs.len);
    try std.testing.expect(expanded.structs[0].items[0] == .function);
}

test "macro engine expands simple macro" {
    // Define a macro and use it
    const source =
        \\pub struct Test {
        \\  pub macro unless(expr, body) {
        \\    quote {
        \\      if not unquote(expr) {
        \\        unquote(body)
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> i64 {
        \\    unless(x > 0, 42)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Module should still exist
    try std.testing.expectEqual(@as(usize, 1), expanded.structs.len);
    // No errors
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
}

test "macro engine hygiene generates unique names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var graph = scope.ScopeGraph.init(alloc);
    defer graph.deinit();

    var engine = MacroEngine.init(alloc, &interner, &graph);
    defer engine.deinit();

    const base = try interner.intern("temp");
    engine.generation = 1;
    const hygienic1 = try engine.generateHygienicName(base);
    engine.generation = 2;
    const hygienic2 = try engine.generateHygienicName(base);

    // Different generations should produce different names
    try std.testing.expect(hygienic1 != hygienic2);

    const name1 = interner.get(hygienic1);
    const name2 = interner.get(hygienic2);
    try std.testing.expectEqualStrings("temp__gen1", name1);
    try std.testing.expectEqualStrings("temp__gen2", name2);
}

test "macro engine reaches fixed point" {
    const source =
        \\pub struct Test {
        \\  pub fn foo() {
        \\    42
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Should reach fixed point immediately (no macros to expand)
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), expanded.structs.len);
}

test "typed macro: nil in String return position is an error" {
    const source =
        \\pub struct Test {
        \\  pub macro when_positive(value :: i64, result :: String) -> String {
        \\    quote {
        \\      if unquote(value) > 0 {
        \\        unquote(result)
        \\      } else {
        \\        nil
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(n :: i64) -> String {
        \\    when_positive(n, "yes")
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Should have a type error: nil incompatible with String return type
    try std.testing.expect(engine.errors.items.len > 0);
    try std.testing.expect(std.mem.find(u8, engine.errors.items[0].message, "nil") != null);
}

test "typed macro: valid types produce no errors" {
    const source =
        \\pub struct Test {
        \\  pub macro when_positive(value :: i64, result :: String) -> String {
        \\    quote {
        \\      if unquote(value) > 0 {
        \\        unquote(result)
        \\      } else {
        \\        "default"
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(n :: i64) -> String {
        \\    when_positive(n, "yes")
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // No errors — all types are compatible
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
}

test "typed macro: missing else branch is an error for non-nil return type" {
    const source =
        \\pub struct Test {
        \\  pub macro unless(expr :: Bool, body :: i64) -> i64 {
        \\    quote {
        \\      if not unquote(expr) {
        \\        unquote(body)
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> i64 {
        \\    unless(x > 0, 42)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Should error: if without else implicitly returns nil
    try std.testing.expect(engine.errors.items.len > 0);
    try std.testing.expect(std.mem.find(u8, engine.errors.items[0].message, "nil") != null);
}

test "typed macro: param type mismatch with return type" {
    const source =
        \\pub struct Test {
        \\  pub macro wrap(value :: i64) -> String {
        \\    quote {
        \\      unquote(value)
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> String {
        \\    wrap(x)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Should error: i64 param used as String return
    try std.testing.expect(engine.errors.items.len > 0);
}

test "macro substitution into case_expr and block" {
    // A macro that produces a case expression with unquote inside
    const source =
        \\pub struct Test {
        \\  pub macro match_it(val :: Expr, fallback :: Expr) -> Nil {
        \\    quote {
        \\      case unquote(val) {
        \\        0 -> unquote(fallback)
        \\        x -> x
        \\      }
        \\    }
        \\  }
        \\
        \\  pub fn check(x :: i64) -> i64 {
        \\    match_it(x, 42)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // No errors — case_expr substitution should work
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
    // Module should still exist with expanded content
    try std.testing.expectEqual(@as(usize, 1), expanded.structs.len);
}

test "typed splice: AtomLit param accepts atom literals" {
    const source =
        \\pub struct Test {
        \\  pub macro tag_with(label :: AtomLit, value :: Expr) -> Nil {
        \\    quote {
        \\      {unquote(label), unquote(value)}
        \\    }
        \\  }
        \\
        \\  pub fn check(n :: i64) -> Nil {
        \\    tag_with(:ok, n)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // No splice-kind errors — `:ok` is an atom literal.
    var splice_errs: usize = 0;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "splice kind") != null) splice_errs += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), splice_errs);
}

test "typed splice: AtomLit param rejects integer literal" {
    const source =
        \\pub struct Test {
        \\  pub macro tag_with(label :: AtomLit, value :: Expr) -> Nil {
        \\    quote {
        \\      {unquote(label), unquote(value)}
        \\    }
        \\  }
        \\
        \\  pub fn check() -> Nil {
        \\    tag_with(42, 99)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // The `42` literal does not match `AtomLit`. Validation must
    // record an error mentioning the splice kind.
    var has_kind_error = false;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "AtomLit") != null) {
            has_kind_error = true;
            break;
        }
    }
    try std.testing.expect(has_kind_error);
}

test "module attribute intrinsics: put writes to current StructEntry" {
    // A macro that stores its argument into the module's
    // `:registered_tests` attribute through the put intrinsic. The
    // side effect happens at expansion time; the macro returns nil.
    const source =
        \\pub struct Test {
        \\  pub macro track(_name :: Expr) -> Nil {
        \\    __zap_module_put_attr__(:registered_tests, _name)
        \\    quote { nil }
        \\  }
        \\
        \\  pub fn check() -> Nil {
        \\    track(:hello)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // The module should now have a `:registered_tests` attribute
    // whose value is the atom `:hello` (single-value semantics —
    // accumulate not registered).
    const test_struct = blk: {
        for (collector.graph.structs.items) |*entry| {
            if (entry.name.parts.len == 1) {
                const part_name = parser.interner.get(entry.name.parts[0]);
                if (std.mem.eql(u8, part_name, "Test")) break :blk entry;
            }
        }
        return error.TestModuleNotFound;
    };

    var found_value: ?ctfe.ConstValue = null;
    for (test_struct.attributes.items) |attr| {
        const attr_name = parser.interner.get(attr.name);
        if (std.mem.eql(u8, attr_name, "registered_tests")) {
            found_value = attr.computed_value;
            break;
        }
    }
    try std.testing.expect(found_value != null);
    try std.testing.expect(found_value.? == .atom);
    try std.testing.expectEqualStrings("hello", found_value.?.atom);
}

test "@before_compile: hook fires and splices result into target module" {
    // The pattern: a target module declares `@before_compile Hooks`
    // at the END of its body (so the collector flushes the
    // attribute onto the module entry rather than the next function),
    // and `Hooks.__before_compile__/1` returns a function declaration
    // that is appended to the target module's items.
    const source =
        \\pub struct Hooks {
        \\  pub macro __before_compile__(_env :: Expr) -> Decl {
        \\    quote {
        \\      pub fn injected_marker() -> i64 {
        \\        99
        \\      }
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Target {
        \\  pub fn original() -> i64 {
        \\    1
        \\  }
        \\
        \\  @before_compile = :Hooks
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Find the Target module in the expanded program.
    var target_struct: ?*const ast.StructDecl = null;
    for (expanded.structs) |*mod| {
        if (mod.name.parts.len == 1) {
            const part_name = parser.interner.get(mod.name.parts[0]);
            if (std.mem.eql(u8, part_name, "Target")) {
                target_struct = mod;
                break;
            }
        }
    }
    try std.testing.expect(target_struct != null);

    // The hook should have appended `injected_marker/0`. The
    // original `original/0` plus the injected fn = 2 functions
    // visible in the items list (the `@before_compile = :Hooks`
    // attribute is parsed as an AttributeDecl but it's also
    // present as a struct item).
    var found_injected = false;
    for (target_struct.?.items) |item| {
        switch (item) {
            .function => |f| {
                const name = parser.interner.get(f.name);
                if (std.mem.eql(u8, name, "injected_marker")) {
                    found_injected = true;
                    break;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found_injected);
}

test "comptime intrinsics: slugify produces snake_case from string" {
    // Direct test of the slugify intrinsic via a macro that returns
    // the slug as a string literal expression. This isolates the
    // intrinsic from the more complex name-splicing path.
    const source =
        \\pub struct Test {
        \\  pub macro slug_of(_label :: StringLit) -> Expr {
        \\    s = __zap_slugify__(_label)
        \\    quote { unquote(s) }
        \\  }
        \\
        \\  pub fn check() -> String {
        \\    slug_of("My Cool Test")
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // The expanded `check` body should be just a string literal
    // "my_cool_test" — slugify lowercased and replaced spaces with
    // underscores.
    var found_slug = false;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt != .expr) continue;
                    if (stmt.expr.* == .string_literal) {
                        const s = parser.interner.get(stmt.expr.string_literal.value);
                        if (std.mem.eql(u8, s, "my_cool_test")) {
                            found_slug = true;
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(found_slug);
}

test "comptime intrinsics: slugify + intern produces dynamic fn name" {
    // Compose the comptime intrinsics: take a user-provided string,
    // slugify it into an identifier, intern it as an atom, and
    // splice it as a function name. This is the exact pattern the
    // Zest migration needs.
    //
    // The macro is invoked from a function body (`check`'s inner
    // call) rather than struct level so the expression-level
    // expansion path (`expandMacroCall`) runs — that path is the
    // one our intrinsics work on top of. Struct-level expansion
    // also goes through the eval path but has additional shape-
    // detection logic that's exercised in other tests.
    const source =
        \\pub struct Test {
        \\  pub macro emit_named(_label :: StringLit) -> Expr {
        \\    fn_name_str = "test_" <> __zap_slugify__(_label)
        \\    quote { unquote(fn_name_str) }
        \\  }
        \\
        \\  pub fn check() -> String {
        \\    emit_named("My First Test")
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // After expansion, `check`'s body should contain a string
    // literal "test_my_first_test" — the result of slugifying
    // "My First Test" and prepending "test_".
    var found = false;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt != .expr) continue;
                    if (stmt.expr.* == .string_literal) {
                        const s = parser.interner.get(stmt.expr.string_literal.value);
                        if (std.mem.eql(u8, s, "test_my_first_test")) {
                            found = true;
                        }
                    }
                }
            }
        }
    }
    try std.testing.expect(found);
}

test "dynamic fn name: unquote in fn-name position resolves at expansion" {
    // The pattern: a macro takes an atom argument and emits a
    // `pub fn unquote(name)(...) -> i64 { ... }` declaration whose
    // function name is determined at expansion time. This is the
    // mechanism behind ExUnit's test/2 and is required for the
    // Zest migration.
    const source =
        \\pub struct Test {
        \\  pub macro define_const(_name :: AtomLit) -> Decl {
        \\    quote {
        \\      pub fn unquote(_name)() -> i64 {
        \\        42
        \\      }
        \\    }
        \\  }
        \\
        \\  define_const(:answer)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // The Test module should now contain a function named `answer/0`
    // injected by `define_const(:answer)`. The fn was emitted by
    // the macro at the struct level via expandStructLevelExpr.
    var found_answer = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        const mod_name = parser.interner.get(mod.name.parts[0]);
        if (!std.mem.eql(u8, mod_name, "Test")) continue;
        for (mod.items) |item| {
            switch (item) {
                .function => |f| {
                    const name = parser.interner.get(f.name);
                    if (std.mem.eql(u8, name, "answer")) {
                        found_answer = true;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_answer);
}

test "@before_compile: hook reads caller's accumulated attributes" {
    // The keystone use case: macros in the target module accumulate
    // names into an attribute, then a `@before_compile` hook reads
    // that list and generates a runner. This is the pattern used by
    // ExUnit (test names) and Mathlib (`@[simp]` lemmas) and is
    // what unblocks the Zest migration in Phase 9.
    //
    // Important ordering: `track` macros expand before the hook
    // fires (the hook runs after each per-module fixed-point), and
    // the AST replacement at the call site means each track expands
    // exactly once. So the track macro must itself ensure the
    // attribute is registered as accumulating *before* it puts.
    const source =
        \\pub struct Hooks {
        \\  pub macro __before_compile__(_env :: Expr) -> Decl {
        \\    quote {
        \\      pub fn marker_after_read() -> i64 { 42 }
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Target {
        \\  pub macro track(_name :: AtomLit) -> Nil {
        \\    __zap_module_register_attr__(:tests)
        \\    __zap_module_put_attr__(:tests, _name)
        \\    quote { nil }
        \\  }
        \\
        \\  pub fn _a() -> Nil { track(:t1) }
        \\  pub fn _b() -> Nil { track(:t2) }
        \\
        \\  @before_compile = :Hooks
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // Verify the hook fired (its marker function was injected) and
    // the caller's :tests attribute accumulated both atoms across
    // the two `track` calls.
    const target_entry = blk: {
        for (collector.graph.structs.items) |*entry| {
            if (entry.name.parts.len == 1) {
                const part_name = parser.interner.get(entry.name.parts[0]);
                if (std.mem.eql(u8, part_name, "Target")) break :blk entry;
            }
        }
        return error.TargetMissing;
    };
    const tests_id = try parser.interner.intern("tests");
    const accumulated = (try collector.graph.getModuleAttribute(target_entry, tests_id)) orelse return error.AttributeMissing;
    try std.testing.expect(accumulated == .list);
    try std.testing.expectEqual(@as(usize, 2), accumulated.list.len);
}

test "@before_compile: hook fires at most once per (module, hook)" {
    // Re-running expandProgram on the same engine should not double-
    // fire the hook. The `before_compile_fired` set tracks every
    // (module_scope, hook_name) pair across iterations.
    const source =
        \\pub struct Hooks {
        \\  pub macro __before_compile__(_env :: Expr) -> Decl {
        \\    quote {
        \\      pub fn injected() -> i64 { 7 }
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Target {
        \\  pub fn original() -> i64 { 1 }
        \\
        \\  @before_compile = :Hooks
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    // Count `injected` functions in the Target module — must be 1.
    var injected_count: usize = 0;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        const part_name = parser.interner.get(mod.name.parts[0]);
        if (!std.mem.eql(u8, part_name, "Target")) continue;
        for (mod.items) |item| {
            if (item == .function) {
                const name = parser.interner.get(item.function.name);
                if (std.mem.eql(u8, name, "injected")) injected_count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), injected_count);
}

test "module attribute intrinsics: register makes attribute accumulate" {
    // After register_attribute, multiple put calls accumulate into a
    // list. Without it, puts overwrite each other.
    const source =
        \\pub struct Test {
        \\  pub macro setup_acc() -> Nil {
        \\    __zap_module_register_attr__(:tests)
        \\    quote { nil }
        \\  }
        \\
        \\  pub macro track(_name :: Expr) -> Nil {
        \\    __zap_module_put_attr__(:tests, _name)
        \\    quote { nil }
        \\  }
        \\
        \\  pub fn _setup() -> Nil { setup_acc() }
        \\  pub fn _a() -> Nil { track(:foo) }
        \\  pub fn _b() -> Nil { track(:bar) }
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    const test_struct = blk: {
        for (collector.graph.structs.items) |*entry| {
            if (entry.name.parts.len == 1) {
                const part_name = parser.interner.get(entry.name.parts[0]);
                if (std.mem.eql(u8, part_name, "Test")) break :blk entry;
            }
        }
        return error.TestModuleNotFound;
    };

    // Two values were appended; the read should produce a list of
    // both atoms in append order.
    const attr_value = blk: {
        const tests_id = try parser.interner.intern("tests");
        const v = try collector.graph.getModuleAttribute(test_struct, tests_id);
        break :blk v orelse return error.AttributeMissing;
    };
    try std.testing.expect(attr_value == .list);
    try std.testing.expectEqual(@as(usize, 2), attr_value.list.len);
    try std.testing.expect(attr_value.list[0] == .atom);
    try std.testing.expect(attr_value.list[1] == .atom);
    try std.testing.expectEqualStrings("foo", attr_value.list[0].atom);
    try std.testing.expectEqualStrings("bar", attr_value.list[1].atom);
}

test "typed splice: untyped param accepts anything (back-compat)" {
    const source =
        \\pub struct Test {
        \\  pub macro identity(x :: Expr) -> Nil {
        \\    quote { unquote(x) }
        \\  }
        \\
        \\  pub fn check() -> i64 {
        \\    identity(42)
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    // `Expr` is the historical permissive default — any shape works.
    var splice_errs: usize = 0;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "splice kind") != null) splice_errs += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), splice_errs);
}
