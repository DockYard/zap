const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");
const ast_data = @import("ast_data.zig");
const ctfe = @import("ctfe.zig");
const ir = @import("ir.zig");

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

pub const CompiledMacroExecutor = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    family_functions: std.AutoHashMap(scope.MacroFamilyId, ir.FunctionId),

    pub fn init(allocator: std.mem.Allocator, program: *const ir.Program) CompiledMacroExecutor {
        return .{
            .allocator = allocator,
            .program = program,
            .family_functions = std.AutoHashMap(scope.MacroFamilyId, ir.FunctionId).init(allocator),
        };
    }

    pub fn deinit(self: *CompiledMacroExecutor) void {
        self.family_functions.deinit();
    }

    pub fn registerMacroFunction(
        self: *CompiledMacroExecutor,
        family_id: scope.MacroFamilyId,
        function_id: ir.FunctionId,
    ) !void {
        try self.family_functions.put(family_id, function_id);
    }

    pub fn hasMacro(self: *const CompiledMacroExecutor, family_id: scope.MacroFamilyId) bool {
        return self.family_functions.contains(family_id);
    }

    pub fn functionIdFor(self: *const CompiledMacroExecutor, family_id: scope.MacroFamilyId) ?ir.FunctionId {
        return self.family_functions.get(family_id);
    }
};

pub const MacroEngine = struct {
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    graph: *scope.ScopeGraph,
    /// The struct scope currently being expanded, for registering generated declarations.
    current_struct_scope: ?scope.ScopeId = null,
    max_expansions: u32,
    errors: std.ArrayList(Error),
    /// Optional CTFE-backed executor for macro families whose provider
    /// structs have already been compiled to IR. When a family is
    /// registered here, expansion must use compiled CTFE and must not
    /// fall back to the tree-walking evaluator on failure.
    compiled_executor: ?*CompiledMacroExecutor = null,
    /// Tracks which `@before_compile` callbacks have already fired
    /// for each struct scope. The callback runs at most once per
    /// struct per `expandProgram` invocation; subsequent expansion
    /// iterations re-check but skip already-fired hooks. Keyed by
    /// the (struct_scope, hook_struct_name_id) pair so the same
    /// struct can register multiple distinct hooks.
    before_compile_fired: std.AutoHashMap(BeforeCompileKey, void),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub const BeforeCompileKey = struct {
        struct_scope: scope.ScopeId,
        hook_name: ast.StringId,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *ast.StringInterner, graph: *scope.ScopeGraph) MacroEngine {
        return .{
            .allocator = allocator,
            .interner = interner,
            .graph = graph,
            .max_expansions = 100,
            .errors = .empty,
            .compiled_executor = null,
            .before_compile_fired = std.AutoHashMap(BeforeCompileKey, void).init(allocator),
        };
    }

    pub fn setCompiledExecutor(self: *MacroEngine, executor: *CompiledMacroExecutor) void {
        self.compiled_executor = executor;
    }

    fn compiledProgram(self: *const MacroEngine) ?*const ir.Program {
        return if (self.compiled_executor) |executor| executor.program else null;
    }

    /// Lazily allocate (or look up) the macro-introduction scope for
    /// the given macro family. The intro_scope tags every identifier
    /// in the template body during expansion. Caching it on the
    /// MacroFamily means every expansion of clauses in that family
    /// shares a single intro_scope — Flatt's algorithm works equally
    /// well with a per-call fresh scope, but per-family is cheaper and
    /// keeps the scope-graph from growing unboundedly with expansion
    /// iteration count.
    fn introScopeFor(self: *MacroEngine, family_id: scope.MacroFamilyId) !scope.ScopeId {
        const family = &self.graph.macro_families.items[family_id];
        if (family.intro_scope) |id| return id;
        const new_id = try self.graph.createScope(null, .macro_expansion);
        family.intro_scope = new_id;
        return new_id;
    }

    /// Allocate a fresh per-call macro-use scope. Called once per
    /// macro invocation. The use_scope is *added* to user-supplied
    /// argument identifiers on entry and *flipped* on the result on
    /// exit — so user identifiers come back to their original scope
    /// set while template identifiers (which never received the
    /// use_scope on entry) acquire it via the flip.
    fn freshUseScope(self: *MacroEngine) !scope.ScopeId {
        return self.graph.createScope(null, .macro_expansion);
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
                try new_structs.append(self.allocator, expanded.decl);
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

            // Fire `@before_compile` hooks once per (struct, hook)
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
    // Struct expansion
    // ============================================================

    const ExpandedStruct = struct {
        decl: ast.StructDecl,
        changed: bool,
    };

    fn expandStruct(self: *MacroEngine, mod: *const ast.StructDecl) !ExpandedStruct {
        var changed = false;
        var new_items: std.ArrayList(ast.StructItem) = .empty;

        // Find the struct's scope by name (not pointer) so it works across
        // expansion iterations where the StructDecl is a copy.
        const mod_scope: ?scope.ScopeId = self.graph.findStructScope(mod.name);
        self.current_struct_scope = mod_scope;
        defer self.current_struct_scope = null;

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
                    // Step 1: Always emit `import Struct` for function access
                    const import_decl = try self.create(ast.ImportDecl, .{
                        .meta = ud.meta,
                        .struct_path = ud.struct_path,
                        .filter = null,
                    });
                    try new_items.append(self.allocator, .{ .import_decl = import_decl });
                    changed = true;

                    // Step 2: Look up Struct.__using__/1 and inject returned items
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

        // Also try expanding the struct declaration itself through Kernel.struct
        // (only if a Kernel macro for "struct" exists)

        return .{
            .decl = .{
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
            .impl_decl => |impl| {
                const expanded = try self.expandImplDecl(impl);
                return .{ .item = .{ .impl_decl = expanded.decl }, .changed = expanded.changed };
            },
            .priv_impl_decl => |impl| {
                const expanded = try self.expandImplDecl(impl);
                return .{ .item = .{ .priv_impl_decl = expanded.decl }, .changed = expanded.changed };
            },
            else => return .{ .item = item, .changed = false },
        }
    }

    const ExpandedImpl = struct {
        decl: *const ast.ImplDecl,
        changed: bool,
    };

    /// Walk each function in a protocol impl and run its body
    /// through `expandFunctionDecl`. Without this, Kernel macros
    /// like `if`, `and`, `or`, `unless`, `cond`, and `<>` survive
    /// inside impl bodies as raw `if_expr`/operator AST nodes,
    /// which the HIR builder rejects with `unreachable`.
    /// Reuses the per-function expander so impls and struct
    /// methods follow the same rules.
    fn expandImplDecl(self: *MacroEngine, impl: *const ast.ImplDecl) !ExpandedImpl {
        var changed = false;
        var new_functions: std.ArrayList(*const ast.FunctionDecl) = .empty;

        for (impl.functions) |func| {
            const expanded = try self.expandFunctionDecl(func);
            if (expanded.changed) changed = true;
            try new_functions.append(self.allocator, expanded.decl);
        }

        if (!changed) return .{ .decl = impl, .changed = false };

        const new_impl = try self.create(ast.ImplDecl, .{
            .meta = impl.meta,
            .protocol_name = impl.protocol_name,
            .protocol_type_args = impl.protocol_type_args,
            .target_type = impl.target_type,
            .type_params = impl.type_params,
            .functions = try new_functions.toOwnedSlice(self.allocator),
            .is_private = impl.is_private,
        });
        return .{ .decl = new_impl, .changed = true };
    }

    // ============================================================
    // @before_compile callback firing
    //
    // After per-struct macro expansion, every struct is checked for
    // `@before_compile` attributes (single-value or accumulated) and
    // each registered hook struct's `__before_compile__/1` macro is
    // invoked at most once per `expandProgram` call. The hook returns
    // a CtValue tree of declarations which is spliced into the
    // struct's items via the same path `expandStructLevelExpr` uses
    // for inline macro returns. New items can themselves contain
    // macro calls; the outer fixed-point loop catches those.
    // ============================================================

    const HookFireResult = struct {
        structs: []const ast.StructDecl,
        changed: bool,
    };

    /// Fire all not-yet-fired `@before_compile` hooks across structs
    /// and append their results into the corresponding struct's
    /// items. Returns either the input slice unchanged (when no hook
    /// fired) or a freshly allocated slice with the affected structs
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
                // `@before_compile = :SomeStruct` is an atom literal
                // we can resolve immediately. Hook targets are
                // expected to be plain atoms (or lists of atoms via
                // `Struct.put_attribute`), not arbitrary
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
                    .struct_scope = mod_scope,
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
            .string => |name| try out.append(alloc, name),
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
            .string_literal => |s| try out.append(alloc, interner.get(s.value)),
            .list => |l| for (l.elements) |elem| {
                try collectHookAtomsFromExpr(out, alloc, interner, elem);
            },
            .struct_ref => |m| {
                if (m.name.parts.len > 0) {
                    try out.append(alloc, try m.name.toDottedString(alloc, interner));
                }
            },
            else => {},
        }
    }

    /// Invoke `<hook_name>.__before_compile__/1` and convert its
    /// result CtValue into a slice of StructItems for splicing.
    /// The argument passed to the hook is a CtValue describing the
    /// caller struct (currently just an atom of the struct's name).
    fn invokeBeforeCompileHook(
        self: *MacroEngine,
        caller_struct_scope: scope.ScopeId,
        caller_struct_name: ast.StructName,
        hook_struct_name: []const u8,
    ) ![]ast.StructItem {
        // Resolve hook struct name → scope id → __before_compile__/1
        // macro family.
        const hook_struct_path = try dottedHookNameToStructName(self.allocator, self.interner, hook_struct_name);
        const hook_scope = self.graph.findStructScope(hook_struct_path) orelse {
            // Hook struct not found — emit error and return empty.
            try self.errors.append(self.allocator, .{
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "@before_compile target struct not found: {s}",
                    .{hook_struct_name},
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
                    .{hook_struct_name},
                ),
                .span = .{ .start = 0, .end = 0 },
            });
            return &.{};
        };
        const family = &self.graph.macro_families.items[family_id];
        if (family.clauses.items.len == 0) return &.{};
        const clause_ref = family.clauses.items[0];
        const clause = &clause_ref.decl.clauses[clause_ref.clause_index];

        // Build the env-arg CtValue: an atom of the caller's struct
        // name. A richer __ENV__ struct can come later; the atom is
        // enough for hooks that just want to read the caller's
        // attributes.
        const macro_eval = @import("macro_eval.zig");
        var store = ctfe.AllocationStore{};
        var env = macro_eval.Env.init(self.allocator, &store);
        defer env.deinit();
        env.compiled_program = self.compiledProgram();
        env.struct_ctx = .{
            .graph = self.graph,
            .interner = self.interner,
            // Hooks read attributes from the *caller* struct, not the
            // hook struct — that's the whole point of the pattern.
            .current_struct_scope = caller_struct_scope,
        };

        if (clause.params.len > 0 and clause.params[0].pattern.* == .bind) {
            const param_name = self.interner.get(clause.params[0].pattern.bind.name);
            const env_arg = try self.structNameToAliasCtValue(&store, caller_struct_name);
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

    fn structNameToAliasCtValue(
        self: *MacroEngine,
        store: *ctfe.AllocationStore,
        struct_name: ast.StructName,
    ) !ctfe.CtValue {
        const parts = try self.allocator.alloc(ctfe.CtValue, struct_name.parts.len);
        for (struct_name.parts, 0..) |part_id, index| {
            parts[index] = .{ .atom = self.interner.get(part_id) };
        }

        return ast_data.makeTuple3(
            self.allocator,
            store,
            .{ .atom = "__aliases__" },
            try ast_data.emptyList(self.allocator, store),
            try ast_data.makeListFromSlice(self.allocator, store, parts),
        );
    }

    fn dottedHookNameToStructName(
        allocator: std.mem.Allocator,
        interner: *ast.StringInterner,
        hook_name: []const u8,
    ) !ast.StructName {
        var parts: std.ArrayListUnmanaged(ast.StringId) = .empty;
        errdefer parts.deinit(allocator);

        var split = std.mem.splitScalar(u8, hook_name, '.');
        while (split.next()) |part| {
            if (part.len == 0) continue;
            try parts.append(allocator, try interner.intern(part));
        }

        return .{
            .parts = try parts.toOwnedSlice(allocator),
            .span = .{ .start = 0, .end = 0 },
        };
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
                .attribute => |attr| {
                    if (attr.value) |value| {
                        const expanded = try self.expandExpr(value);
                        if (expanded.changed) {
                            changed = true;
                            const new_attr = try self.create(ast.AttributeDecl, .{
                                .meta = attr.meta,
                                .name = attr.name,
                                .type_expr = attr.type_expr,
                                .value = expanded.expr,
                            });
                            try new_stmts.append(self.allocator, .{ .attribute = new_attr });
                        } else {
                            try new_stmts.append(self.allocator, stmt);
                        }
                    } else {
                        try new_stmts.append(self.allocator, stmt);
                    }
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
                const arity: u32 = @intCast(call.args.len);

                // Bare macro call: `name(args)`. A function family with
                // the same name+arity in scope shadows any imported
                // macro of the same shape — `pub fn <op>` wins over a
                // Kernel `pub macro <op>`.
                if (call.callee.* == .var_ref) {
                    const callee_name = call.callee.var_ref.name;
                    if (self.findFunction(callee_name, arity) == null) {
                        if (self.findMacro(callee_name, arity)) |mid| {
                            if (self.isDirectUnderscoreCallName(callee_name)) {
                                try self.rejectDirectUnderscoreCall(callee_name, arity, call.meta.span);
                                return .{ .expr = expr, .changed = false };
                            }
                            const expanded = try self.expandMacroCall(expr, callee_name, mid);
                            return .{ .expr = expanded, .changed = true };
                        }
                    }
                }

                // Qualified macro call: `Struct.name(args)` or
                // `Outer.Inner.name(args)`. The parser shapes these as
                // `field_access { object: struct_ref, field: name }`.
                // Look up the macro directly in the named struct's
                // scope — the calling scope does not participate.
                if (call.callee.* == .field_access) {
                    const fa = call.callee.field_access;
                    if (fa.object.* == .struct_ref) {
                        const mod_name = fa.object.struct_ref.name;
                        if (self.findMacroInStruct(mod_name, fa.field, arity)) |mid| {
                            if (self.isDirectUnderscoreCallName(fa.field)) {
                                try self.rejectDirectUnderscoreCall(fa.field, arity, call.meta.span);
                                return .{ .expr = expr, .changed = false };
                            }
                            const expanded = try self.expandMacroCall(expr, fa.field, mid);
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

            .error_pipe => |ep| {
                var changed = false;
                const chain = try self.expandErrorPipeChain(ep.chain);
                if (chain.changed) changed = true;

                const handler: ast.ErrorHandler = switch (ep.handler) {
                    .function => |function| blk: {
                        const expanded = try self.expandExpr(function);
                        if (expanded.changed) changed = true;
                        break :blk .{ .function = expanded.expr };
                    },
                    .block => |clauses| blk: {
                        var new_clauses: std.ArrayList(ast.CaseClause) = .empty;
                        for (clauses) |clause| {
                            const guard = if (clause.guard) |guard_expr| guard_blk: {
                                const expanded = try self.expandExpr(guard_expr);
                                if (expanded.changed) changed = true;
                                break :guard_blk expanded.expr;
                            } else null;
                            const body = try self.expandBlock(clause.body);
                            if (body.changed) changed = true;
                            try new_clauses.append(self.allocator, .{
                                .meta = clause.meta,
                                .pattern = clause.pattern,
                                .type_annotation = clause.type_annotation,
                                .guard = guard,
                                .body = body.stmts,
                            });
                        }
                        break :blk .{ .block = try new_clauses.toOwnedSlice(self.allocator) };
                    },
                };

                if (!changed) return .{ .expr = expr, .changed = false };
                return .{
                    .expr = try self.create(ast.Expr, .{
                        .error_pipe = .{
                            .meta = ep.meta,
                            .chain = chain.expr,
                            .handler = handler,
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
            .struct_ref,
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
            => return .{ .expr = expr, .changed = false },
        }
    }

    fn expandErrorPipeChain(self: *MacroEngine, expr: *const ast.Expr) anyerror!ExpandedExpr {
        if (expr.* != .pipe) {
            return self.expandExpr(expr);
        }

        const pipe = expr.pipe;
        var changed = false;
        const lhs = try self.expandErrorPipeChain(pipe.lhs);
        if (lhs.changed) changed = true;
        const rhs = try self.expandErrorPipeChain(pipe.rhs);
        if (rhs.changed) changed = true;

        if (!changed) return .{ .expr = expr, .changed = false };
        return .{
            .expr = try self.create(ast.Expr, .{
                .pipe = .{
                    .meta = pipe.meta,
                    .lhs = lhs.expr,
                    .rhs = rhs.expr,
                },
            }),
            .changed = true,
        };
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

    fn isDirectUnderscoreCallName(self: *const MacroEngine, name: ast.StringId) bool {
        const text = self.interner.get(name);
        return text.len > 0 and text[0] == '_';
    }

    fn rejectDirectUnderscoreCall(self: *MacroEngine, name: ast.StringId, arity: u32, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{
            .message = try std.fmt.allocPrint(
                self.allocator,
                "cannot call underscore-prefixed function `{s}/{d}`",
                .{ self.interner.get(name), arity },
            ),
            .span = span,
        });
    }

    fn expandMacroCall(
        self: *MacroEngine,
        expr: *const ast.Expr,
        name: ast.StringId,
        macro_family_id: scope.MacroFamilyId,
    ) !*const ast.Expr {
        const call = expr.call;

        const family = &self.graph.macro_families.items[macro_family_id];

        if (family.clauses.items.len == 0) {
            try self.errors.append(self.allocator, .{
                .message = "macro has no clauses",
                .span = call.meta.span,
            });
            return expr;
        }

        // Allocate the per-call ExpansionInfo. Lives for the lifetime
        // of the macro engine's allocator (the compile session). Every
        // node produced by this expansion will be stamped with this
        // pointer so a downstream tool (LSP, diagnostic) can group them
        // by call site and walk the parent chain back to user source.
        //
        // The parent frame is the call expression's *current* expansion
        // stamp (if any). When this `expr` itself was synthesised by an
        // outer macro expansion, the outer ExpansionInfo is already on
        // its meta — chain to it so nested-macro provenance is
        // preserved without needing a thread-local "current expansion"
        // stack.
        const expansion_info = try self.allocator.create(ast.ExpansionInfo);
        expansion_info.* = .{
            .call_site = call.meta.span,
            .macro_name = name,
            .parent = expr.getMeta().expansion,
        };

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

        // Allocate the Flatt-2016 hygiene scopes for this expansion:
        //   use_scope:   fresh per call site, added to the user's arg
        //                identifiers and flipped on the result. After
        //                the flip, identifiers originally from the
        //                user are unmarked while template-introduced
        //                identifiers carry the use_scope.
        //   intro_scope: per-family (cached on MacroFamily), added to
        //                every identifier in the template body so
        //                names introduced by the macro carry a
        //                distinguishing mark independent of the call
        //                site.
        const use_scope = try self.freshUseScope();
        const intro_scope = try self.introScopeFor(macro_family_id);

        // Fast path: bare quote body → use Phase 2 template expansion
        if ((clause.body orelse @as([]const ast.Stmt, &.{})).len == 1 and (clause.body orelse @as([]const ast.Stmt, &.{}))[0] == .expr) {
            const body_expr = (clause.body orelse @as([]const ast.Stmt, &.{}))[0].expr;
            if (body_expr.* == .quote_expr) {
                const expanded = try self.expandQuoteHygienic(body_expr, call.args, clause.params, use_scope, intro_scope);
                stampExpansionOnExpr(expanded, expansion_info);
                return expanded;
            }
        }

        // Phase 3: evaluate macro body as a function using the macro evaluator.
        // Convert the body and args to CtValue, run the evaluator, convert back.
        if (self.compiled_executor) |executor| {
            if (executor.hasMacro(macro_family_id)) {
                return try self.expandCompiledMacroCall(
                    expr,
                    macro_family_id,
                    use_scope,
                    intro_scope,
                    expansion_info,
                );
            }
        }

        // Phase 3 fallback: evaluate macro body as a function using the
        // legacy macro evaluator. This path remains for macro families
        // whose provider structs have not yet been staged and compiled.
        {
            const macro_eval = @import("macro_eval.zig");
            var store = ctfe.AllocationStore{};
            var env = macro_eval.Env.init(self.allocator, &store);
            defer env.deinit();
            env.compiled_program = self.compiledProgram();
            // Wire struct context so struct attribute intrinsics can
            // reach the scope graph and the current struct's
            // StructEntry. Falls back to a noop if no struct is
            // active (e.g., top-level macro calls).
            env.struct_ctx = .{
                .graph = self.graph,
                .interner = self.interner,
                .current_struct_scope = self.current_struct_scope,
            };
            // Narrow the evaluator's capability set to whatever the
            // macro family declared via `@requires`. The body's calls
            // to impure intrinsics (and to other macros) will be
            // checked against this set. Macros without an annotation
            // default to `pure_only` — so adding the first impure call
            // surfaces an under-declaration error.
            env.current_macro_caps = family.required_caps;
            env.current_macro_name = self.interner.get(name);
            env.current_macro_span = call.meta.span;
            env.current_macro_source_path = blk: {
                if (clause_ref.decl.meta.span.source_id) |source_id| {
                    break :blk self.graph.sourcePathById(source_id);
                }
                break :blk null;
            };

            // Bind macro parameters to CtValue representations of the
            // arguments. Each argument's identifiers are tagged with
            // the per-call use_scope so substitution embeds them into
            // the template carrying that mark; the post-substitution
            // flip then removes use_scope from the user identifiers.
            for (clause.params, 0..) |param, i| {
                if (i < call.args.len) {
                    if (param.pattern.* == .bind) {
                        const param_name = self.interner.get(param.pattern.bind.name);
                        const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, call.args[i]);
                        const marked_arg = try ast_data.addScopeToIdentifiers(self.allocator, &store, arg_ct, use_scope);
                        try env.bind(param_name, marked_arg);
                    }
                }
            }

            // Convert body statements to CtValue and evaluate them.
            // A capability_violation surfaces as `EvalFailed` with a
            // diagnostic stashed in `env.last_capability_error`; turn
            // that into a real macro engine error so the author sees
            // an actionable message at the macro call site.
            var result: ctfe.CtValue = .nil;
            var capability_failed = false;
            for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
                const stmt_ct = try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt);
                result = macro_eval.eval(&env, stmt_ct) catch blk: {
                    if (env.last_capability_error) |msg| {
                        try self.errors.append(self.allocator, .{
                            .message = msg,
                            .span = call.meta.span,
                        });
                        capability_failed = true;
                    }
                    break :blk .nil;
                };
                if (capability_failed) break;
            }
            if (capability_failed) return expr;

            // The eval path treats `quote` as a lazy form — its args
            // are returned without recursing into them. That means
            // unquotes inside the quote body are still raw `:unquote`
            // 3-tuples in the result. Tag every identifier in the
            // template with the macro-introduction scope BEFORE
            // substitution (the inner var refs of `:unquote` markers
            // pick up the mark too, but those nodes are about to be
            // replaced wholesale by the user's value, so the
            // marker-internal mark has no effect). Then substitute.
            // After substitution, flip the use_scope on the result so
            // user-supplied identifiers shed the mark they came in
            // with while template identifiers acquire it.
            if (result != .nil) {
                result = try ast_data.addScopeToIdentifiers(self.allocator, &store, result, intro_scope);
                result = try self.substituteCtValue(result, &env.bindings, &store);
                result = try ast_data.flipScopeOnIdentifiers(self.allocator, &store, result, use_scope);

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
                const expanded = ast_data.ctValueToExpr(self.allocator, self.interner, result) catch return expr;
                stampExpansionOnExpr(expanded, expansion_info);
                return expanded;
            }
        }

        return expr;
    }

    fn expandCompiledMacroCall(
        self: *MacroEngine,
        expr: *const ast.Expr,
        macro_family_id: scope.MacroFamilyId,
        use_scope: scope.ScopeId,
        intro_scope: scope.ScopeId,
        expansion_info: *ast.ExpansionInfo,
    ) !*const ast.Expr {
        const executor = self.compiled_executor orelse return expr;
        const function_id = executor.functionIdFor(macro_family_id) orelse return expr;
        const call = expr.call;
        const family = &self.graph.macro_families.items[macro_family_id];

        var store = ctfe.AllocationStore{};
        const compiled_args = try self.allocator.alloc(ctfe.CtValue, call.args.len);
        for (call.args, 0..) |arg, index| {
            const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, arg);
            compiled_args[index] = try ast_data.addScopeToIdentifiers(self.allocator, &store, arg_ct, use_scope);
        }

        var interpreter = ctfe.Interpreter.init(self.allocator, executor.program);
        defer interpreter.deinit();
        interpreter.scope_graph = self.graph;
        interpreter.interner = self.interner;
        interpreter.current_struct_scope = self.current_struct_scope;
        interpreter.capabilities = family.required_caps;
        interpreter.steps_remaining = interpreter.step_budget;

        var result = interpreter.evalFunction(function_id, compiled_args) catch |err| {
            if (interpreter.errors.items.len > 0) {
                for (interpreter.errors.items) |ctfe_err| {
                    const formatted = ctfe.formatCtfeError(self.allocator, ctfe_err) catch
                        try std.fmt.allocPrint(self.allocator, "compiled macro CTFE failed: {s}", .{ctfe_err.message});
                    try self.errors.append(self.allocator, .{
                        .message = formatted,
                        .span = call.meta.span,
                    });
                }
            } else {
                try self.errors.append(self.allocator, .{
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "compiled macro CTFE failed for `{s}`: {s}",
                        .{ self.interner.get(family.name), @errorName(err) },
                    ),
                    .span = call.meta.span,
                });
            }
            return expr;
        };

        if (result == .nil) return expr;

        result = try ast_data.addScopeToIdentifiers(self.allocator, &store, result, intro_scope);
        result = try ast_data.flipScopeOnIdentifiers(self.allocator, &store, result, use_scope);

        const expanded = ast_data.ctValueToExpr(self.allocator, self.interner, result) catch return expr;
        stampExpansionOnExpr(expanded, expansion_info);
        return expanded;
    }

    // ============================================================
    // Quote expansion with unquote substitution
    // ============================================================

    fn expandQuote(self: *MacroEngine, quote_expr: *const ast.Expr, args: []const *const ast.Expr, params: []const ast.Param) anyerror!*const ast.Expr {
        // Legacy entry point — used by callers that don't yet plumb
        // use/intro scopes (declaration macros, `use`, operator macros).
        // Allocates a one-shot pair so even the legacy paths produce
        // hygiene-marked output. Once those callers thread their own
        // scope ids, this wrapper can shrink to a forwarder.
        const use_scope = try self.freshUseScope();
        const intro_scope = try self.graph.createScope(null, .macro_expansion);
        return self.expandQuoteHygienic(quote_expr, args, params, use_scope, intro_scope);
    }

    /// Hygiene-aware quote expansion. The caller supplies a fresh
    /// `use_scope` (per-call) and an `intro_scope` (typically per
    /// macro family). Walks the user's argument CtValues to add
    /// `use_scope`; walks the template body to add `intro_scope`;
    /// substitutes; then flips `use_scope` over the whole result so
    /// user-supplied identifiers shed the use_scope while template
    /// identifiers acquire it (Flatt-2016 set-of-scopes hygiene).
    fn expandQuoteHygienic(
        self: *MacroEngine,
        quote_expr: *const ast.Expr,
        args: []const *const ast.Expr,
        params: []const ast.Param,
        use_scope: scope.ScopeId,
        intro_scope: scope.ScopeId,
    ) anyerror!*const ast.Expr {
        const quote = quote_expr.quote_expr;

        var store = ctfe.AllocationStore{};

        // Convert each statement in the quote body to CtValue, then
        // tag every identifier in the template with the macro-
        // introduction scope. The intro_scope distinguishes
        // template-introduced names from any same-name identifier the
        // user passes in: after the use_scope flip on the final
        // result, only template identifiers carry the use_scope, so
        // resolution sees them as different bindings even when their
        // textual names collide.
        var body_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
        for (quote.body) |stmt| {
            const stmt_ct = try ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt);
            const marked = try ast_data.addScopeToIdentifiers(self.allocator, &store, stmt_ct, intro_scope);
            try body_vals.append(self.allocator, marked);
        }

        // Build parameter name (string) → CtValue argument mapping.
        // Every user-supplied identifier inside an argument picks up
        // the use_scope here; substitution then embeds them into the
        // template, where the final flip will *remove* the use_scope
        // (since the user's ids already had it). Template ids never
        // had it, so the flip *adds* it for them.
        var param_map = std.StringHashMap(ctfe.CtValue).init(self.allocator);
        defer param_map.deinit();

        for (params, 0..) |param, i| {
            if (i < args.len) {
                if (param.pattern.* == .bind) {
                    const name = self.interner.get(param.pattern.bind.name);
                    const arg_ct = try ast_data.exprToCtValue(self.allocator, self.interner, &store, args[i]);
                    const marked_arg = try ast_data.addScopeToIdentifiers(self.allocator, &store, arg_ct, use_scope);
                    try param_map.put(name, marked_arg);
                }
            }
        }

        // Substitute :unquote nodes in the CtValue tree.
        var substituted_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
        for (body_vals.items) |val| {
            try substituted_vals.append(self.allocator, try self.substituteCtValue(val, &param_map, &store));
        }

        // Flip the use_scope across the whole result. User-supplied
        // identifiers (which had use_scope added) shed it; template
        // identifiers (which didn't) acquire it. After this flip,
        // template ids carry both intro_scope and use_scope while
        // user ids carry their original scope set unchanged.
        var flipped_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
        for (substituted_vals.items) |val| {
            const flipped = try ast_data.flipScopeOnIdentifiers(self.allocator, &store, val, use_scope);
            try flipped_vals.append(self.allocator, flipped);
        }

        // Convert back to ast.Expr
        if (flipped_vals.items.len == 1) {
            return ast_data.ctValueToExpr(self.allocator, self.interner, flipped_vals.items[0]);
        }

        // Multiple statements → wrap in block
        var stmts: std.ArrayListUnmanaged(ast.Stmt) = .empty;
        for (flipped_vals.items) |val| {
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
            var result_elems: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
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
        // for struct references, or as plain identifier atoms for
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
    /// from the current struct just like `findMacro`.
    fn findFunction(self: *MacroEngine, name: ast.StringId, arity: u32) ?scope.FunctionFamilyId {
        const scope_id = self.current_struct_scope orelse self.graph.prelude_scope;
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

                var body_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
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
            env.compiled_program = self.compiledProgram();

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
    // Struct-level expression expansion
    // ============================================================

    const ExpandedStructItems = struct {
        items: []const ast.StructItem,
        changed: bool,
    };

    /// Expand a struct-level expression. If the expression is a macro call
    /// that produces a function declaration (or other struct item), convert
    /// it to the appropriate StructItem variant. Otherwise keep it as a
    /// struct_level_expr for collection into a generated run/0 function.
    /// Patch a generated struct item's source span so the scope collector
    /// and HIR builder can associate it with the correct struct scope.
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

    /// Recursively flatten nested `__block__` AST nodes into a flat
    /// list of CtValues. A macro that composes other macros (e.g.
    /// `describe` emitting a `test()` call which itself returns a
    /// `__block__` of [fn_decl, tracking_call]) produces nested
    /// blocks; without flattening, the inner blocks survive as
    /// opaque expressions at struct scope and the per-element
    /// struct-item conversion never sees the underlying decls.
    fn flattenNestedBlocks(
        self: *MacroEngine,
        value: ctfe.CtValue,
        out: *std.ArrayList(ctfe.CtValue),
    ) std.mem.Allocator.Error!void {
        if (value != .tuple or value.tuple.elems.len != 3) {
            try out.append(self.allocator, value);
            return;
        }
        const form = value.tuple.elems[0];
        if (form != .atom or !std.mem.eql(u8, form.atom, "__block__")) {
            try out.append(self.allocator, value);
            return;
        }
        if (value.tuple.elems[2] == .list) {
            for (value.tuple.elems[2].list.elems) |elem| {
                try self.flattenNestedBlocks(elem, out);
            }
        }
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

                    // Allocate Flatt-2016 hygiene scopes for this
                    // expansion. See `expandMacroCall` for the full
                    // rationale; this struct-level path mirrors it.
                    const use_scope = self.freshUseScope() catch {
                        const expanded = try self.expandExpr(expr);
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = .{ .struct_level_expr = expanded.expr };
                        return .{ .items = items, .changed = expanded.changed };
                    };
                    const intro_scope = self.introScopeFor(macro_family_id) catch {
                        const expanded = try self.expandExpr(expr);
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = .{ .struct_level_expr = expanded.expr };
                        return .{ .items = items, .changed = expanded.changed };
                    };

                    // Evaluate the macro and get the CtValue result
                    const result_ct = self.evaluateMacroBodyToCtValue(
                        clause,
                        expr.call.args,
                        use_scope,
                        intro_scope,
                    ) orelse {
                        // Macro evaluation failed — keep as expression
                        const expanded = try self.expandExpr(expr);
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = .{ .struct_level_expr = expanded.expr };
                        return .{ .items = items, .changed = expanded.changed };
                    };

                    // Try converting the result to struct items.
                    // Patch source spans so generated declarations inherit the call site's
                    // position — this ensures the scope collector associates them with the
                    // correct struct scope (not the default prelude scope).
                    const interner_mut: *ast.StringInterner = @constCast(self.interner);
                    const call_span = expr.call.meta.span;

                    // Single struct item (e.g., function declaration)
                    if (ast_data.ctValueToStructItem(self.allocator, interner_mut, result_ct) catch null) |mi| {
                        const items = try self.allocator.alloc(ast.StructItem, 1);
                        items[0] = patchStructItemSpan(mi, call_span);
                        return .{ .items = items, .changed = true };
                    }

                    // Block of struct items (e.g., describe expanding to multiple functions).
                    // Recursively flatten nested __block__ tuples first so a macro that
                    // composes other macros (each of which returns its own __block__)
                    // produces a flat list of struct items instead of opaque inner blocks
                    // surviving as struct_level_exprs.
                    if (result_ct == .tuple and result_ct.tuple.elems.len == 3) {
                        if (result_ct.tuple.elems[0] == .atom) {
                            if (std.mem.eql(u8, result_ct.tuple.elems[0].atom, "__block__")) {
                                if (result_ct.tuple.elems[2] == .list) {
                                    var flattened: std.ArrayList(ctfe.CtValue) = .empty;
                                    defer flattened.deinit(self.allocator);
                                    for (result_ct.tuple.elems[2].list.elems) |elem| {
                                        try self.flattenNestedBlocks(elem, &flattened);
                                    }

                                    // Check if ALL elements are struct items. If any element
                                    // is not a struct item (e.g., an assignment like ctx = 42),
                                    // keep the entire block as a single struct_level_expr to
                                    // preserve variable bindings and control flow.
                                    var all_struct_items = true;
                                    for (flattened.items) |elem| {
                                        if (ast_data.ctValueToStructItem(self.allocator, interner_mut, elem) catch null) |_| {
                                            // is a struct item
                                        } else {
                                            all_struct_items = false;
                                            break;
                                        }
                                    }

                                    if (all_struct_items) {
                                        var items: std.ArrayList(ast.StructItem) = .empty;
                                        for (flattened.items) |elem| {
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
                                        for (flattened.items) |elem_expr| {
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

                    // List of struct items (may be mixed with expressions)
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
    /// `use_scope` is a fresh per-call scope added to user-supplied
    /// argument identifiers and flipped on the result; `intro_scope`
    /// is the per-family macro-introduction scope added to template
    /// identifiers. See `expandMacroCall` for the full algorithm.
    fn evaluateMacroBodyToCtValue(
        self: *MacroEngine,
        clause: *const ast.FunctionClause,
        args: []const *const ast.Expr,
        use_scope: scope.ScopeId,
        intro_scope: scope.ScopeId,
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
                            // Mark user-supplied identifiers with the
                            // per-call use_scope so the post-result
                            // flip can shed it (template ids that
                            // never had it then acquire it instead).
                            const marked = ast_data.addScopeToIdentifiers(self.allocator, &store, arg_ct, use_scope) catch return null;
                            param_map.put(pname, marked) catch return null;
                        }
                    }
                }

                var body_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    // Tag template identifiers with the per-family
                    // intro_scope before substitution embeds the
                    // user's args into them.
                    const marked = ast_data.addScopeToIdentifiers(self.allocator, &store, stmt_ct, intro_scope) catch return null;
                    const substituted = self.substituteCtValue(marked, &param_map, &store) catch return null;
                    const flipped = ast_data.flipScopeOnIdentifiers(self.allocator, &store, substituted, use_scope) catch return null;
                    body_vals.append(self.allocator, flipped) catch return null;
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
        env.compiled_program = self.compiledProgram();
        // Wire struct context so struct attribute and other comptime
        // intrinsics that consult the scope graph reach the right
        // struct — same wiring as the expression-level expandMacroCall
        // eval path.
        env.struct_ctx = .{
            .graph = self.graph,
            .interner = self.interner,
            .current_struct_scope = self.current_struct_scope,
        };

        for (clause.params, 0..) |param, i| {
            if (i < args.len) {
                if (param.pattern.* == .bind) {
                    const param_name = self.interner.get(param.pattern.bind.name);
                    const arg_ct = ast_data.exprToCtValue(self.allocator, self.interner, &store, args[i]) catch return null;
                    const marked_arg = ast_data.addScopeToIdentifiers(self.allocator, &store, arg_ct, use_scope) catch return null;
                    env.bind(param_name, marked_arg) catch return null;
                }
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause_body) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch return null;
        }

        // The eval path treats `quote` as lazy: its body is returned
        // as data without recursing into the unquote nodes. Tag
        // template identifiers with the intro_scope, substitute, then
        // flip the use_scope across the whole result so user ids shed
        // the use_scope they came in with while template ids acquire
        // it. Mirrors the pattern used by `expandMacroCall`'s eval
        // path for expression-level macros.
        if (result != .nil) {
            result = ast_data.addScopeToIdentifiers(self.allocator, &store, result, intro_scope) catch return null;
            result = self.substituteCtValue(result, &env.bindings, &store) catch return null;
            result = ast_data.flipScopeOnIdentifiers(self.allocator, &store, result, use_scope) catch return null;
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
        // Look up a Kernel macro with the declaration form name (fn, struct, struct, macro)
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

                var body_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
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
        env.compiled_program = self.compiledProgram();

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

    /// Try to expand `use Struct` by calling Struct.__using__/1.
    /// Returns injected struct items if __using__ exists, null otherwise.
    ///
    /// Looks up `__using__/1` in the use TARGET's scope, not in the calling
    /// scope. A general scope-walk lookup would find the first `__using__/1`
    /// reachable through the consumer's imports — so when a consumer does
    /// `use Foo` and `use Bar` (both defining `__using__/1`), `use Bar` would
    /// silently invoke Foo's `__using__` instead of Bar's.
    fn tryExpandUsing(self: *MacroEngine, ud: *const ast.UseDecl) ?[]const ast.StructItem {
        // Build the __using__ name
        const using_name = self.interner.intern("__using__") catch return null;

        // Look up __using__/1 directly in the use target's scope
        const macro_id = self.findMacroInStruct(ud.struct_path, using_name, 1) orelse return null;

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

                var body_vals: std.ArrayListUnmanaged(ctfe.CtValue) = .empty;
                for (body_expr.quote_expr.body) |stmt| {
                    const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
                    body_vals.append(self.allocator, self.substituteCtValue(stmt_ct, &param_map, &store) catch return null) catch return null;
                }

                // Convert each result value to a struct item
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
        env.compiled_program = self.compiledProgram();
        env.struct_ctx = .{
            .graph = self.graph,
            .interner = self.interner,
            .current_struct_scope = self.current_struct_scope,
        };
        env.current_macro_caps = family.required_caps;
        env.current_macro_name = self.interner.get(family.name);
        env.current_macro_span = ud.meta.span;
        env.current_macro_source_path = blk: {
            if (clause_ref.decl.meta.span.source_id) |source_id| {
                break :blk self.graph.sourcePathById(source_id);
            }
            break :blk null;
        };

        for (clause.params) |param| {
            if (param.pattern.* == .bind) {
                const pname = self.interner.get(param.pattern.bind.name);
                env.bind(pname, opts_ct) catch return null;
            }
        }

        var result: ctfe.CtValue = .nil;
        for (clause.body orelse @as([]const ast.Stmt, &.{})) |stmt| {
            const stmt_ct = ast_data.stmtToCtValue(self.allocator, self.interner, &store, stmt) catch return null;
            result = macro_eval.eval(&env, stmt_ct) catch {
                if (env.last_capability_error) |msg| {
                    self.errors.append(self.allocator, .{
                        .message = msg,
                        .span = ud.meta.span,
                    }) catch return null;
                }
                return null;
            };
        }

        if (result != .nil) {
            return self.ctValueToStructItems(result) catch return null;
        }
        return null;
    }

    /// Find a macro by walking the scope chain from the current struct scope.
    /// Checks local macros first (struct-local shadows Kernel), then imports
    /// (finds Kernel macros via auto-import), then parent scopes.
    /// Find a macro by walking the scope chain from the current struct scope.
    /// Checks local macros first (struct-local shadows Kernel), then imports
    /// (finds Kernel macros via auto-import), then parent scopes.
    /// Find a macro by walking the scope chain from the current struct scope.
    /// Checks local macros first (struct-local shadows Kernel), then imports
    /// (finds Kernel macros via auto-import), then parent scopes.
    fn findMacro(self: *MacroEngine, name: ast.StringId, arity: u32) ?scope.MacroFamilyId {
        const scope_id = self.current_struct_scope orelse self.graph.prelude_scope;
        return self.graph.resolveMacro(scope_id, name, arity);
    }

    /// Resolve a macro by qualified name (`Struct.macro` or
    /// `Outer.Inner.macro`). Looks directly in the named struct's
    /// scope — the calling scope's parent chain is not walked, so a
    /// shadowing macro in the caller never wins over the qualified
    /// target. Returns null if the struct is unknown or the macro is
    /// not defined there at the requested arity.
    fn findMacroInStruct(
        self: *MacroEngine,
        struct_name: ast.StructName,
        name: ast.StringId,
        arity: u32,
    ) ?scope.MacroFamilyId {
        const mod_scope_id = self.graph.findStructScope(struct_name) orelse return null;
        const mod_scope = self.graph.getScope(mod_scope_id);
        const key = scope.FamilyKey{ .name = name, .arity = arity };
        return mod_scope.macros.get(key);
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
// Expansion-info stamping
//
// After macro expansion converts the result CtValue back to AST, we
// walk the resulting tree and write `meta.expansion = info` on every
// node. The pointer is shared by all nodes from a single expansion so a
// downstream tool can cluster them by expansion frame and walk
// `info.parent` back to user source for nested macros.
//
// Nodes that already carry an `expansion` pointer (because they were
// produced by an inner macro that already expanded) are left alone:
// their existing `info.parent` chain is the truth, and overwriting
// would lose the inner provenance. The outer call's frame is reachable
// from the inner one via `parent`.
//
// The walker is exhaustive over every AST union variant — when a new
// variant is added, the corresponding `inline else` falls through and
// the variant-count tripwire test in `ast.zig` will catch the omission.
// ============================================================

fn stampMetaIfUnset(meta_ptr: *ast.NodeMeta, info: *const ast.ExpansionInfo) void {
    if (meta_ptr.expansion == null) {
        meta_ptr.expansion = info;
    }
}

fn stampExpansionOnExpr(expr: *const ast.Expr, info: *const ast.ExpansionInfo) void {
    const mut: *ast.Expr = @constCast(expr);
    switch (mut.*) {
        .int_literal => |*v| stampMetaIfUnset(&v.meta, info),
        .float_literal => |*v| stampMetaIfUnset(&v.meta, info),
        .string_literal => |*v| stampMetaIfUnset(&v.meta, info),
        .string_interpolation => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.parts) |part| switch (part) {
                .literal => {},
                .expr => |child| stampExpansionOnExpr(child, info),
            };
        },
        .atom_literal => |*v| stampMetaIfUnset(&v.meta, info),
        .bool_literal => |*v| stampMetaIfUnset(&v.meta, info),
        .nil_literal => |*v| stampMetaIfUnset(&v.meta, info),
        .var_ref => |*v| stampMetaIfUnset(&v.meta, info),
        .struct_ref => |*v| stampMetaIfUnset(&v.meta, info),
        .tuple => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.elements) |elem| stampExpansionOnExpr(elem, info);
        },
        .list => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.elements) |elem| stampExpansionOnExpr(elem, info);
        },
        .map => |*v| {
            stampMetaIfUnset(&v.meta, info);
            if (v.update_source) |src| stampExpansionOnExpr(src, info);
            for (v.fields) |field| {
                stampExpansionOnExpr(field.key, info);
                stampExpansionOnExpr(field.value, info);
            }
        },
        .struct_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            if (v.update_source) |src| stampExpansionOnExpr(src, info);
            for (v.fields) |field| stampExpansionOnExpr(field.value, info);
        },
        .range => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.start, info);
            stampExpansionOnExpr(v.end, info);
            if (v.step) |s| stampExpansionOnExpr(s, info);
        },
        .binary_op => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.lhs, info);
            stampExpansionOnExpr(v.rhs, info);
        },
        .unary_op => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.operand, info);
        },
        .call => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.callee, info);
            for (v.args) |arg| stampExpansionOnExpr(arg, info);
        },
        .field_access => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.object, info);
        },
        .pipe => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.lhs, info);
            stampExpansionOnExpr(v.rhs, info);
        },
        .unwrap => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.expr, info);
        },
        .if_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.condition, info);
            for (v.then_block) |stmt| stampExpansionOnStmt(stmt, info);
            if (v.else_block) |else_block| {
                for (else_block) |stmt| stampExpansionOnStmt(stmt, info);
            }
        },
        .case_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.scrutinee, info);
            for (v.clauses) |*clause| stampExpansionOnCaseClause(clause, info);
        },
        .cond_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.clauses) |*clause| {
                stampMetaIfUnset(&@as(*ast.CondClause, @constCast(clause)).meta, info);
                stampExpansionOnExpr(clause.condition, info);
                for (clause.body) |stmt| stampExpansionOnStmt(stmt, info);
            }
        },
        .for_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnPattern(v.var_pattern, info);
            if (v.var_type_annotation) |ta| stampExpansionOnTypeExpr(ta, info);
            stampExpansionOnExpr(v.iterable, info);
            if (v.filter) |f| stampExpansionOnExpr(f, info);
            stampExpansionOnExpr(v.body, info);
        },
        .list_cons_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.head, info);
            stampExpansionOnExpr(v.tail, info);
        },
        .quote_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.body) |stmt| stampExpansionOnStmt(stmt, info);
        },
        .unquote_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.expr, info);
        },
        .unquote_splicing_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.expr, info);
        },
        .panic_expr => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.message, info);
        },
        .error_pipe => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.chain, info);
            switch (v.handler) {
                .block => |arms| for (arms) |*clause| stampExpansionOnCaseClause(clause, info),
                .function => |fn_expr| stampExpansionOnExpr(fn_expr, info),
            }
        },
        .block => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.stmts) |stmt| stampExpansionOnStmt(stmt, info);
        },
        .intrinsic => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.args) |arg| stampExpansionOnExpr(arg, info);
        },
        .attr_ref => |*v| stampMetaIfUnset(&v.meta, info),
        .binary_literal => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.segments) |*seg| stampExpansionOnBinarySegment(seg, info);
        },
        .function_ref => |*v| stampMetaIfUnset(&v.meta, info),
        .anonymous_function => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnFunctionDecl(v.decl, info);
        },
        .type_annotated => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnExpr(v.expr, info);
            stampExpansionOnTypeExpr(v.type_expr, info);
        },
    }
}

fn stampExpansionOnStmt(stmt: ast.Stmt, info: *const ast.ExpansionInfo) void {
    switch (stmt) {
        .expr => |e| stampExpansionOnExpr(e, info),
        .assignment => |a| {
            const mut: *ast.Assignment = @constCast(a);
            stampMetaIfUnset(&mut.meta, info);
            stampExpansionOnPattern(a.pattern, info);
            stampExpansionOnExpr(a.value, info);
        },
        .function_decl => |fd| stampExpansionOnFunctionDecl(fd, info),
        .macro_decl => |fd| stampExpansionOnFunctionDecl(fd, info),
        .import_decl => |id| {
            const mut: *ast.ImportDecl = @constCast(id);
            stampMetaIfUnset(&mut.meta, info);
        },
        .attribute => |attr| {
            const mut: *ast.AttributeDecl = @constCast(attr);
            stampMetaIfUnset(&mut.meta, info);
            if (attr.value) |value| stampExpansionOnExpr(value, info);
        },
    }
}

fn stampExpansionOnPattern(pattern: *const ast.Pattern, info: *const ast.ExpansionInfo) void {
    const mut: *ast.Pattern = @constCast(pattern);
    switch (mut.*) {
        .wildcard => |*v| stampMetaIfUnset(&v.meta, info),
        .bind => |*v| stampMetaIfUnset(&v.meta, info),
        .literal => |*lit| switch (lit.*) {
            .int => |*v| stampMetaIfUnset(&v.meta, info),
            .float => |*v| stampMetaIfUnset(&v.meta, info),
            .string => |*v| stampMetaIfUnset(&v.meta, info),
            .atom => |*v| stampMetaIfUnset(&v.meta, info),
            .bool_lit => |*v| stampMetaIfUnset(&v.meta, info),
            .nil => |*v| stampMetaIfUnset(&v.meta, info),
        },
        .tuple => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.elements) |elem| stampExpansionOnPattern(elem, info);
        },
        .list => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.elements) |elem| stampExpansionOnPattern(elem, info);
        },
        .list_cons => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.heads) |h| stampExpansionOnPattern(h, info);
            stampExpansionOnPattern(v.tail, info);
        },
        .map => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.fields) |field| {
                stampExpansionOnExpr(field.key, info);
                stampExpansionOnPattern(field.value, info);
            }
        },
        .struct_pattern => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.fields) |field| stampExpansionOnPattern(field.pattern, info);
        },
        .pin => |*v| stampMetaIfUnset(&v.meta, info),
        .paren => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnPattern(v.inner, info);
        },
        .binary => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.segments) |*seg| stampExpansionOnBinarySegment(seg, info);
        },
    }
}

fn stampExpansionOnTypeExpr(type_expr: *const ast.TypeExpr, info: *const ast.ExpansionInfo) void {
    const mut: *ast.TypeExpr = @constCast(type_expr);
    switch (mut.*) {
        .name => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.args) |arg| stampExpansionOnTypeExpr(arg, info);
        },
        .variable => |*v| stampMetaIfUnset(&v.meta, info),
        .tuple => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.elements) |elem| stampExpansionOnTypeExpr(elem, info);
        },
        .list => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnTypeExpr(v.element, info);
        },
        .map => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.fields) |field| {
                stampExpansionOnTypeExpr(field.key, info);
                stampExpansionOnTypeExpr(field.value, info);
            }
        },
        .struct_type => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.fields) |field| stampExpansionOnTypeExpr(field.type_expr, info);
        },
        .union_type => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.members) |m| stampExpansionOnTypeExpr(m, info);
        },
        .function => |*v| {
            stampMetaIfUnset(&v.meta, info);
            for (v.params) |p| stampExpansionOnTypeExpr(p, info);
            stampExpansionOnTypeExpr(v.return_type, info);
        },
        .literal => |*v| stampMetaIfUnset(&v.meta, info),
        .never => |*v| stampMetaIfUnset(&v.meta, info),
        .paren => |*v| {
            stampMetaIfUnset(&v.meta, info);
            stampExpansionOnTypeExpr(v.inner, info);
        },
    }
}

fn stampExpansionOnCaseClause(clause: *const ast.CaseClause, info: *const ast.ExpansionInfo) void {
    const mut: *ast.CaseClause = @constCast(clause);
    stampMetaIfUnset(&mut.meta, info);
    stampExpansionOnPattern(clause.pattern, info);
    if (clause.type_annotation) |ta| stampExpansionOnTypeExpr(ta, info);
    if (clause.guard) |g| stampExpansionOnExpr(g, info);
    for (clause.body) |stmt| stampExpansionOnStmt(stmt, info);
}

fn stampExpansionOnFunctionDecl(decl: *const ast.FunctionDecl, info: *const ast.ExpansionInfo) void {
    const mut: *ast.FunctionDecl = @constCast(decl);
    stampMetaIfUnset(&mut.meta, info);
    if (decl.name_expr) |ne| stampExpansionOnExpr(ne, info);
    for (decl.clauses) |*clause| {
        const cmut: *ast.FunctionClause = @constCast(clause);
        stampMetaIfUnset(&cmut.meta, info);
        for (clause.params) |*param| {
            const pmut: *ast.Param = @constCast(param);
            stampMetaIfUnset(&pmut.meta, info);
            stampExpansionOnPattern(param.pattern, info);
            if (param.type_annotation) |ta| stampExpansionOnTypeExpr(ta, info);
            if (param.default) |d| stampExpansionOnExpr(d, info);
        }
        if (clause.return_type) |rt| stampExpansionOnTypeExpr(rt, info);
        if (clause.refinement) |r| stampExpansionOnExpr(r, info);
        if (clause.body) |body| {
            for (body) |stmt| stampExpansionOnStmt(stmt, info);
        }
    }
}

fn stampExpansionOnBinarySegment(seg: *const ast.BinarySegment, info: *const ast.ExpansionInfo) void {
    const mut: *ast.BinarySegment = @constCast(seg);
    stampMetaIfUnset(&mut.meta, info);
    switch (seg.value) {
        .expr => |e| stampExpansionOnExpr(e, info),
        .pattern => |p| stampExpansionOnPattern(p, info),
        .string_literal => {},
    }
}

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

    // Struct should still exist
    try std.testing.expectEqual(@as(usize, 1), expanded.structs.len);
    // No errors
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);
}

test "macro engine expands qualified Struct.macro calls" {
    // Regression: `Function.identity(42)` and similar qualified macro
    // invocations are first-class — the dispatcher previously only
    // recognised macro calls when the callee was a bare var_ref, so
    // dotted names fell through to the function-call path, which then
    // emitted broken IR (a `zap_runtime.Function` lookup that doesn't
    // exist).
    const source =
        \\pub struct Lib {
        \\  pub macro identity(x) {
        \\    quote { unquote(x) }
        \\  }
        \\}
        \\
        \\pub struct Caller {
        \\  pub fn use_it() -> i64 {
        \\    Lib.identity(42)
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

    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);

    // Find Caller.use_it's body. After macro expansion the call
    // `Lib.identity(42)` must collapse to the bare integer literal
    // `42`. If the dispatcher missed it, the body would still be a
    // .call expression and IR lowering would fail downstream.
    var caller_body: ?[]const ast.Stmt = null;
    for (expanded.structs) |mod| {
        const last_part = parser.interner.get(mod.name.parts[mod.name.parts.len - 1]);
        if (!std.mem.eql(u8, last_part, "Caller")) continue;
        for (mod.items) |item| switch (item) {
            .function => |fd| {
                if (fd.clauses.len > 0) caller_body = fd.clauses[0].body;
            },
            else => {},
        };
    }
    try std.testing.expect(caller_body != null);
    try std.testing.expectEqual(@as(usize, 1), caller_body.?.len);
    const stmt = caller_body.?[0];
    try std.testing.expect(stmt == .expr);
    try std.testing.expect(stmt.expr.* == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), stmt.expr.int_literal.value);
}

test "macro engine invokes registered compiled macro through CTFE" {
    const source =
        \\pub struct Provider {
        \\  pub macro answer() -> Expr {
        \\    0
        \\  }
        \\}
        \\
        \\pub struct Consumer {
        \\  import Provider
        \\
        \\  pub fn use_it() -> i64 {
        \\    answer()
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

    const provider_scope = collector.graph.findStructScope(program.structs[0].name).?;
    const answer_name = try parser.interner.intern("answer");
    const macro_family_id = collector.graph.resolveMacro(provider_scope, answer_name, 0).?;

    const compiled_body = [_]ir.Instruction{
        .{ .const_int = .{ .dest = 0, .value = 42 } },
        .{ .ret = .{ .value = 0 } },
    };
    const compiled_blocks = [_]ir.Block{
        .{ .label = 0, .instructions = &compiled_body },
    };
    const compiled_functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "Provider__answer__0",
            .struct_name = "Provider",
            .local_name = "answer__0",
            .scope_id = provider_scope,
            .arity = 0,
            .params = &.{},
            .return_type = .any,
            .body = &compiled_blocks,
            .is_closure = false,
            .captures = &.{},
            .local_count = 1,
        },
    };
    const compiled_program = ir.Program{
        .functions = &compiled_functions,
        .type_defs = &.{},
        .entry = null,
    };

    var executor = CompiledMacroExecutor.init(alloc, &compiled_program);
    defer executor.deinit();
    try executor.registerMacroFunction(macro_family_id, 0);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    engine.setCompiledExecutor(&executor);
    const expanded = try engine.expandProgram(&program);

    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);

    var consumer_body: ?[]const ast.Stmt = null;
    for (expanded.structs) |mod| {
        const last_part = parser.interner.get(mod.name.parts[mod.name.parts.len - 1]);
        if (!std.mem.eql(u8, last_part, "Consumer")) continue;
        for (mod.items) |item| switch (item) {
            .function => |fd| {
                if (fd.clauses.len > 0) consumer_body = fd.clauses[0].body;
            },
            else => {},
        };
    }

    try std.testing.expect(consumer_body != null);
    try std.testing.expectEqual(@as(usize, 1), consumer_body.?.len);
    try std.testing.expect(consumer_body.?[0] == .expr);
    try std.testing.expect(consumer_body.?[0].expr.* == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), consumer_body.?[0].expr.int_literal.value);
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
    // Struct should still exist with expanded content
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

test "struct attribute intrinsics: put writes to current StructEntry" {
    // A macro that stores its argument into the struct's
    // `:registered_tests` attribute through the put intrinsic. The
    // side effect happens at expansion time; the macro returns nil.
    const source =
        \\pub struct Test {
        \\  pub macro track(_name :: Expr) -> Nil {
        \\    struct_put_attribute(:registered_tests, _name)
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

    // The struct should now have a `:registered_tests` attribute
    // whose value is the atom `:hello` (single-value semantics —
    // accumulate not registered).
    const test_struct = blk: {
        for (collector.graph.structs.items) |*entry| {
            if (entry.name.parts.len == 1) {
                const part_name = parser.interner.get(entry.name.parts[0]);
                if (std.mem.eql(u8, part_name, "Test")) break :blk entry;
            }
        }
        return error.TestStructNotFound;
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

test "@before_compile: hook fires and splices result into target struct" {
    // The pattern: a target struct declares `@before_compile Hooks`
    // at the END of its body (so the collector flushes the
    // attribute onto the struct entry rather than the next function),
    // and `Hooks.__before_compile__/1` returns a function declaration
    // that is appended to the target struct's items.
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

    // Find the Target struct in the expanded program.
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

test "@before_compile: hook target may be a nested struct" {
    const source =
        \\pub struct Hooks.Nested {
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
        \\  @before_compile = Hooks.Nested
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

    var found_injected = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Target")) continue;

        for (mod.items) |item| {
            if (item != .function) continue;
            const name = parser.interner.get(item.function.name);
            if (std.mem.eql(u8, name, "injected_marker")) {
                found_injected = true;
                break;
            }
        }
    }

    try std.testing.expect(found_injected);
}

test "use macro struct attributes apply to the caller struct" {
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
        \\pub struct Provider {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    struct_register_attribute(:before_compile)
        \\    struct_put_attribute(:before_compile, "Hooks")
        \\    quote { nil }
        \\  }
        \\}
        \\
        \\pub struct Target {
        \\  use Provider
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

    var found_injected = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Target")) continue;

        for (mod.items) |item| {
            if (item != .function) continue;
            const name = parser.interner.get(item.function.name);
            if (std.mem.eql(u8, name, "injected_marker")) {
                found_injected = true;
                break;
            }
        }
    }

    try std.testing.expect(found_injected);
}

test "Zest test/2 macro: multi-stmt quote body matches lib/zest/case.zap shape" {
    // This is the exact shape `lib/zest/case.zap`'s test macro
    // produces: a 6-statement quote body (fn decl + 5 tracking
    // statements). The earlier 2-statement test passed; this version
    // exercises the multi-statement list path in expandStructLevelExpr
    // which is what zap-test-suite hits.
    const source =
        \\pub struct Test {
        \\  pub macro tm(_name :: Expr, body :: Expr) -> Expr {
        \\    fn_name = intern_atom("test_" <> slugify(_name))
        \\    quote {
        \\      pub fn unquote(fn_name)() -> i64 {
        \\        unquote(body)
        \\      }
        \\
        \\      1
        \\      unquote(fn_name)()
        \\      2
        \\      3
        \\      "x"
        \\    }
        \\  }
        \\
        \\  pub macro wrap(_label :: Expr, body :: Expr) -> Expr {
        \\    body
        \\  }
        \\
        \\  wrap("g") {
        \\    tm("foo bar", 42)
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

    var any_colon_prefixed = false;
    var seen_test_call = false;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .struct_level_expr) continue;
            if (item.struct_level_expr.* != .call) continue;
            const callee = item.struct_level_expr.call.callee;
            if (callee.* != .var_ref) continue;
            const name = parser.interner.get(callee.var_ref.name);
            if (name.len > 0 and name[0] == ':') any_colon_prefixed = true;
            if (std.mem.eql(u8, name, "test_foo_bar")) seen_test_call = true;
        }
    }
    try std.testing.expect(!any_colon_prefixed);
    try std.testing.expect(seen_test_call);
}

test "Zest test/2 macro: multiple tests with setup/teardown sibling calls" {
    // Reproduces the actual zap-test-suite scenario more closely:
    // tests inside a passthrough wrapper, alongside `setup` and
    // `teardown` macro calls (whose bodies just `quote { body }`).
    // The setup/teardown calls become struct_level_exprs after their
    // own expansion and live alongside the test fn decls + tracking
    // calls in the parent struct's items list.
    const source =
        \\pub struct Test {
        \\  pub macro test_macro(_name :: Expr, body :: Expr) -> Expr {
        \\    fn_name = intern_atom("test_" <> slugify(_name))
        \\    quote {
        \\      pub fn unquote(fn_name)() -> i64 {
        \\        unquote(body)
        \\      }
        \\
        \\      unquote(fn_name)()
        \\    }
        \\  }
        \\
        \\  pub macro setup_helper(body :: Expr) -> Expr {
        \\    quote { unquote(body) }
        \\  }
        \\
        \\  pub macro wrap(_label :: Expr, body :: Expr) -> Expr {
        \\    body
        \\  }
        \\
        \\  wrap("group") {
        \\    setup_helper(7)
        \\    test_macro("first one", 1)
        \\    test_macro("second one", 2)
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

    var any_colon_prefixed = false;
    var seen_first = false;
    var seen_second = false;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .struct_level_expr) continue;
            if (item.struct_level_expr.* != .call) continue;
            const callee = item.struct_level_expr.call.callee;
            if (callee.* != .var_ref) continue;
            const name = parser.interner.get(callee.var_ref.name);
            if (name.len > 0 and name[0] == ':') any_colon_prefixed = true;
            if (std.mem.eql(u8, name, "test_first_one")) seen_first = true;
            if (std.mem.eql(u8, name, "test_second_one")) seen_second = true;
        }
    }
    try std.testing.expect(!any_colon_prefixed);
    try std.testing.expect(seen_first);
    try std.testing.expect(seen_second);
}

test "Zest test/2 macro: multiple tests through a passthrough wrapper" {
    // Reproduces the multi-test case more precisely. Two tests
    // inside a passthrough wrapper, each with a name that contains
    // spaces (so slugify is exercised). The tracking call for both
    // must resolve to bare identifiers.
    const source =
        \\pub struct Test {
        \\  pub macro test_macro(_name :: Expr, body :: Expr) -> Expr {
        \\    fn_name = intern_atom("test_" <> slugify(_name))
        \\    quote {
        \\      pub fn unquote(fn_name)() -> i64 {
        \\        unquote(body)
        \\      }
        \\
        \\      unquote(fn_name)()
        \\    }
        \\  }
        \\
        \\  pub macro wrap(_label :: Expr, body :: Expr) -> Expr {
        \\    body
        \\  }
        \\
        \\  wrap("group") {
        \\    test_macro("first one", 1)
        \\    test_macro("second one", 2)
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

    // Collect every tracking-call callee name. Each must be a bare
    // identifier — none should carry the `:` prefix.
    var seen_first = false;
    var seen_second = false;
    var any_colon_prefixed = false;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .struct_level_expr) continue;
            if (item.struct_level_expr.* != .call) continue;
            const callee = item.struct_level_expr.call.callee;
            if (callee.* != .var_ref) continue;
            const name = parser.interner.get(callee.var_ref.name);
            if (name.len > 0 and name[0] == ':') any_colon_prefixed = true;
            if (std.mem.eql(u8, name, "test_first_one")) seen_first = true;
            if (std.mem.eql(u8, name, "test_second_one")) seen_second = true;
        }
    }
    try std.testing.expect(!any_colon_prefixed);
    try std.testing.expect(seen_first);
    try std.testing.expect(seen_second);
}

test "Zest test/2 macro: works through a passthrough wrapper macro" {
    // Reproduces the failure mode the describe-passthrough revealed:
    // when a wrapper macro returns its body unchanged and the body
    // contains a test_macro call, the test_macro expands in a later
    // iteration and its tracking call's callee should still resolve
    // to a bare identifier (no colon prefix). Failure mode is the
    // tracking call having callee ':test_X' instead of 'test_X'.
    const source =
        \\pub struct Test {
        \\  pub macro test_macro(_name :: Expr, body :: Expr) -> Expr {
        \\    fn_name = intern_atom("test_" <> slugify(_name))
        \\    quote {
        \\      pub fn unquote(fn_name)() -> i64 {
        \\        unquote(body)
        \\      }
        \\
        \\      unquote(fn_name)()
        \\    }
        \\  }
        \\
        \\  pub macro wrap(body :: Expr) -> Expr {
        \\    body
        \\  }
        \\
        \\  wrap(test_macro("foo", 42))
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

    // The tracking call's callee must be a bare identifier
    // (`test_foo`), never the colon-prefixed atom.
    var tracking_callee_name: ?[]const u8 = null;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        const mod_name = parser.interner.get(mod.name.parts[0]);
        if (!std.mem.eql(u8, mod_name, "Test")) continue;
        for (mod.items) |item| {
            if (item != .struct_level_expr) continue;
            if (item.struct_level_expr.* != .call) continue;
            const callee = item.struct_level_expr.call.callee;
            if (callee.* == .var_ref) {
                tracking_callee_name = parser.interner.get(callee.var_ref.name);
            }
        }
    }
    try std.testing.expect(tracking_callee_name != null);
    try std.testing.expectEqualStrings("test_foo", tracking_callee_name.?);
}

test "Zest test/2 macro: generates dynamically-named fn + tracking call" {
    // Validates the migrated `test` macro in lib/zest/case.zap works
    // end-to-end through the new comptime intrinsics + dynamic fn
    // name path. The macro takes a name string and a body, slugifies
    // the name, builds an atom, splices it as a function name, and
    // returns a __block__ containing both the fn decl and the
    // tracking call sequence that invokes it.
    //
    // We bypass the actual Zest struct (which depends on the runtime
    // Zest struct) and inline the same logic as a one-off macro.
    const source =
        \\pub struct Test {
        \\  pub macro test_macro(_name :: Expr, body :: Expr) -> Expr {
        \\    fn_name = intern_atom("test_" <> slugify(_name))
        \\    quote {
        \\      pub fn unquote(fn_name)() -> i64 {
        \\        unquote(body)
        \\      }
        \\
        \\      unquote(fn_name)()
        \\    }
        \\  }
        \\
        \\  test_macro("hello world", 42)
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

    // Test struct should now contain (in order):
    //   - the test_macro definition (still there)
    //   - a fn `test_hello_world` (the generated test fn)
    //   - a struct_level_expr calling `test_hello_world()` (tracking)
    var found_fn = false;
    var found_call = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        const mod_name = parser.interner.get(mod.name.parts[0]);
        if (!std.mem.eql(u8, mod_name, "Test")) continue;
        for (mod.items) |item| {
            switch (item) {
                .function => |f| {
                    const name = parser.interner.get(f.name);
                    if (std.mem.eql(u8, name, "test_hello_world")) {
                        found_fn = true;
                    }
                },
                .struct_level_expr => |e| {
                    if (e.* == .call and e.call.callee.* == .var_ref) {
                        const callee_name = parser.interner.get(e.call.callee.var_ref.name);
                        if (std.mem.eql(u8, callee_name, "test_hello_world")) {
                            found_call = true;
                        }
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_fn);
    try std.testing.expect(found_call);
}

test "comptime function dispatch: refuses impure function (zig interop)" {
    // A function whose body calls `:zig.X.Y` is impure. The
    // dispatcher must refuse and leave the call as runtime AST so
    // the impure work happens at runtime where it belongs. The
    // macro would otherwise see mangled output (an AST tuple in a
    // place expecting a scalar).
    const source =
        \\pub struct Test {
        \\  pub fn impure_log(value :: i64) -> i64 {
        \\    :zig.IO.println(value)
        \\    value
        \\  }
        \\
        \\  pub macro try_log() -> Expr {
        \\    result = impure_log(42)
        \\    quote { unquote(result) }
        \\  }
        \\
        \\  pub fn check() -> i64 {
        \\    try_log()
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

    // After expansion, `check`'s body should NOT contain a bare
    // int_literal `42` (which would mean dispatch incorrectly
    // reduced an impure function). It should still contain the
    // unreduced `impure_log(42)` call.
    var body_first_expr_tag: ?[]const u8 = null;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const fn_name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, fn_name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt == .expr) {
                        body_first_expr_tag = @tagName(stmt.expr.*);
                        break;
                    }
                }
            }
        }
    }
    try std.testing.expect(body_first_expr_tag != null);
    // The body should not be a bare int_literal — that would
    // indicate dispatch reduced an impure function.
    try std.testing.expect(!std.mem.eql(u8, body_first_expr_tag.?, "int_literal"));
}

test "comptime function dispatch: transitive — function calls function" {
    // `quadruple(x)` calls `double(x)` calls `n + n`. The dispatcher
    // recurses into each call, evaluates pure arithmetic, returns
    // the final scalar. Validates that env.dispatch_depth bumps
    // correctly and child envs inherit the struct context.
    const source =
        \\pub struct Test {
        \\  pub fn double(n :: i64) -> i64 {
        \\    n + n
        \\  }
        \\
        \\  pub fn quadruple(n :: i64) -> i64 {
        \\    double(double(n))
        \\  }
        \\
        \\  pub macro emit_quad() -> Expr {
        \\    result = quadruple(7)
        \\    quote { unquote(result) }
        \\  }
        \\
        \\  pub fn check() -> i64 {
        \\    emit_quad()
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

    var found_int: ?i64 = null;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const fn_name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, fn_name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt == .expr and stmt.expr.* == .int_literal) {
                        found_int = stmt.expr.int_literal.value;
                    }
                }
            }
        }
    }
    try std.testing.expect(found_int != null);
    // 7 doubled = 14; 14 doubled = 28
    try std.testing.expectEqual(@as(i64, 28), found_int.?);
}

test "comptime function dispatch: macro calls pure user-defined function" {
    // A macro body invokes `double(x)` where `double/1` is an
    // ordinary `pub fn` defined in the same struct. The comptime
    // dispatcher resolves it through the scope graph and recursively
    // evaluates the body, so the macro sees the function's return
    // value as a CtValue rather than an unresolved call AST.
    const source =
        \\pub struct Test {
        \\  pub fn double(n :: i64) -> i64 {
        \\    n + n
        \\  }
        \\
        \\  pub macro emit_doubled() -> Expr {
        \\    result = double(21)
        \\    quote { unquote(result) }
        \\  }
        \\
        \\  pub fn check() -> i64 {
        \\    emit_doubled()
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

    // After expansion, `check`'s body should contain the integer
    // literal 42 (= 21 + 21). The macro's call to `double(21)` was
    // resolved at comptime and inlined.
    var found_int: ?i64 = null;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const fn_name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, fn_name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt == .expr and stmt.expr.* == .int_literal) {
                        found_int = stmt.expr.int_literal.value;
                    }
                }
            }
        }
    }
    try std.testing.expect(found_int != null);
    try std.testing.expectEqual(@as(i64, 42), found_int.?);
}

test "comptime for: iterates list and accumulates body results" {
    // The macro evaluator runs `for x <- [1, 2, 3] { x + 10 }` at
    // expansion time. The accumulated list of body values is
    // returned as a CtValue.list which ctValueToExpr renders as a
    // list literal in the expanded AST.
    const source =
        \\pub struct Test {
        \\  pub macro emit_list() -> Expr {
        \\    nums = [1, 2, 3]
        \\    incremented = for n <- nums { n + 10 }
        \\    quote { unquote(incremented) }
        \\  }
        \\
        \\  pub fn check() -> [i64] {
        \\    emit_list()
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

    // After expansion `check`'s body should contain a list literal
    // `[11, 12, 13]`.
    var found_list: ?*const ast.Expr = null;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const fn_name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, fn_name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt == .expr and stmt.expr.* == .list) {
                        found_list = stmt.expr;
                    }
                }
            }
        }
    }
    try std.testing.expect(found_list != null);
    const elems = found_list.?.list.elements;
    try std.testing.expectEqual(@as(usize, 3), elems.len);
    // Each element should be int_literal with the incremented value.
    try std.testing.expect(elems[0].* == .int_literal);
    try std.testing.expectEqual(@as(i64, 11), elems[0].int_literal.value);
    try std.testing.expectEqual(@as(i64, 12), elems[1].int_literal.value);
    try std.testing.expectEqual(@as(i64, 13), elems[2].int_literal.value);
}

test "comptime for: filter clause excludes elements" {
    // `for n <- [1, 2, 3, 4, 5], n >= 3 { n + 10 }` produces
    // [13, 14, 15] — only elements meeting the filter contribute.
    // The comma after the iterable introduces the filter expression.
    const source =
        \\pub struct Test {
        \\  pub macro emit_filtered() -> Expr {
        \\    nums = [1, 2, 3, 4, 5]
        \\    big = for n <- nums, n >= 3 { n + 10 }
        \\    quote { unquote(big) }
        \\  }
        \\
        \\  pub fn check() -> [i64] {
        \\    emit_filtered()
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

    var found_list: ?*const ast.Expr = null;
    for (expanded.structs) |mod| {
        for (mod.items) |item| {
            if (item != .function) continue;
            const fn_name = parser.interner.get(item.function.name);
            if (!std.mem.eql(u8, fn_name, "check")) continue;
            for (item.function.clauses) |clause| {
                const body = clause.body orelse continue;
                for (body) |stmt| {
                    if (stmt == .expr and stmt.expr.* == .list) {
                        found_list = stmt.expr;
                    }
                }
            }
        }
    }
    try std.testing.expect(found_list != null);
    const elems = found_list.?.list.elements;
    try std.testing.expectEqual(@as(usize, 3), elems.len);
    try std.testing.expectEqual(@as(i64, 13), elems[0].int_literal.value);
    try std.testing.expectEqual(@as(i64, 14), elems[1].int_literal.value);
    try std.testing.expectEqual(@as(i64, 15), elems[2].int_literal.value);
}

test "comptime intrinsics: slugify produces snake_case from string" {
    // Direct test of the slugify intrinsic via a macro that returns
    // the slug as a string literal expression. This isolates the
    // intrinsic from the more complex name-splicing path.
    const source =
        \\pub struct Test {
        \\  pub macro slug_of(_label :: StringLit) -> Expr {
        \\    s = slugify(_label)
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
        \\    fn_name_str = "test_" <> slugify(_label)
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

    // The Test struct should now contain a function named `answer/0`
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
    // The keystone use case: macros in the target struct accumulate
    // names into an attribute, then a `@before_compile` hook reads
    // that list and generates a runner. This is the pattern used by
    // ExUnit (test names) and Mathlib (`@[simp]` lemmas) and is
    // what unblocks the Zest migration in Phase 9.
    //
    // Important ordering: `track` macros expand before the hook
    // fires (the hook runs after each per-struct fixed-point), and
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
        \\    struct_register_attribute(:tests)
        \\    struct_put_attribute(:tests, _name)
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
    const accumulated = (try collector.graph.getStructAttribute(target_entry, tests_id)) orelse return error.AttributeMissing;
    try std.testing.expect(accumulated == .list);
    try std.testing.expectEqual(@as(usize, 2), accumulated.list.len);
}

test "@before_compile: hook fires at most once per (struct, hook)" {
    // Re-running expandProgram on the same engine should not double-
    // fire the hook. The `before_compile_fired` set tracks every
    // (struct_scope, hook_name) pair across iterations.
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

    // Count `injected` functions in the Target struct — must be 1.
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

test "struct attribute intrinsics: register makes attribute accumulate" {
    // After register_attribute, multiple put calls accumulate into a
    // list. Without it, puts overwrite each other.
    const source =
        \\pub struct Test {
        \\  pub macro setup_acc() -> Nil {
        \\    struct_register_attribute(:tests)
        \\    quote { nil }
        \\  }
        \\
        \\  pub macro track(_name :: Expr) -> Nil {
        \\    struct_put_attribute(:tests, _name)
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
        return error.TestStructNotFound;
    };

    // Two values were appended; the read should produce a list of
    // both atoms in append order.
    const attr_value = blk: {
        const tests_id = try parser.interner.intern("tests");
        const v = try collector.graph.getStructAttribute(test_struct, tests_id);
        break :blk v orelse return error.AttributeMissing;
    };
    try std.testing.expect(attr_value == .list);
    try std.testing.expectEqual(@as(usize, 2), attr_value.list.len);
    try std.testing.expect(attr_value.list[0] == .atom);
    try std.testing.expect(attr_value.list[1] == .atom);
    try std.testing.expectEqualStrings("foo", attr_value.list[0].atom);
    try std.testing.expectEqualStrings("bar", attr_value.list[1].atom);
}

// ============================================================
// Capability tests (Task #15)
//
// Capabilities are inferred by `capability_inference.zig` from each
// macro's call graph; authors no longer write `@requires` annotations.
// These tests stage small Zap programs and assert that the inferred
// `MacroFamily.required_caps` matches what the body actually does.
// ============================================================

test "capability inference: macro using read_file gets read_file in its set" {
    const source =
        \\pub struct Test {
        \\  pub macro embed(path :: Expr) {
        \\    read_file("doesnotmatter")
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
    try std.testing.expectEqual(@as(usize, 0), collector.errors.items.len);

    try @import("capability_inference.zig").inferAndApply(alloc, &collector.graph, parser.interner);

    try std.testing.expect(collector.graph.macro_families.items.len > 0);
    const family = collector.graph.macro_families.items[0];
    try std.testing.expect(family.required_caps.has(.read_file));
    try std.testing.expect(!family.required_caps.has(.read_env));
}

test "capability inference: pure macro has empty cap set" {
    const source =
        \\pub struct Test {
        \\  pub macro id(x :: Expr) {
        \\    quote { unquote(x) }
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

    try @import("capability_inference.zig").inferAndApply(alloc, &collector.graph, parser.interner);

    try std.testing.expect(collector.graph.macro_families.items.len > 0);
    const family = collector.graph.macro_families.items[0];
    try std.testing.expectEqual(@as(u8, 0), family.required_caps.flags);
}

test "capability inference: caps propagate transitively through macro-to-macro calls" {
    const source =
        \\pub struct Test {
        \\  pub macro inner() {
        \\    read_file("x")
        \\  }
        \\  pub macro outer() {
        \\    inner()
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

    try @import("capability_inference.zig").inferAndApply(alloc, &collector.graph, parser.interner);

    // Both macros must have read_file in their inferred set: `inner`
    // because it directly calls `read_file`, and `outer` because the
    // call graph propagates `inner`'s caps up to its caller.
    try std.testing.expectEqual(@as(usize, 2), collector.graph.macro_families.items.len);
    for (collector.graph.macro_families.items) |family| {
        try std.testing.expect(family.required_caps.has(.read_file));
    }
}

test "capability inference: writing @requires is a compile error" {
    const source =
        \\pub struct Test {
        \\  @requires = [:read_file]
        \\  pub macro deprecated() {
        \\    quote { 1 }
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

    var saw_deprecation_error = false;
    for (collector.errors.items) |err| {
        if (std.mem.find(u8, err.message, "@requires") != null and
            std.mem.find(u8, err.message, "no longer supported") != null)
        {
            saw_deprecation_error = true;
            break;
        }
    }
    try std.testing.expect(saw_deprecation_error);
}

/// Build a Zap source string that exercises the given macro
/// declarations and a fn that calls `entry_macro_name`. Centralizes
/// the boilerplate so each capability test focuses on the body shape
/// under test rather than test scaffolding.
fn buildCapTestSource(
    alloc: std.mem.Allocator,
    macros_decls: []const u8,
    entry_macro_call: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\pub struct Test {{
        \\{s}
        \\
        \\  pub fn fixture_text() -> String {{
        \\    {s}
        \\  }}
        \\}}
        \\
    , .{ macros_decls, entry_macro_call });
}

test "capability: macro using read_file expands without diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "fixture.txt",
        .data = "fixture contents",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "fixture.txt", alloc);

    const macros_decl = try std.fmt.allocPrint(alloc,
        \\  pub macro embed_fixture() {{
        \\    read_file("{s}")
        \\  }}
    , .{tmp_path});
    const source = try buildCapTestSource(alloc, macros_decl, "embed_fixture()");

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), collector.errors.items.len);

    try @import("capability_inference.zig").inferAndApply(alloc, &collector.graph, parser.interner);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    for (engine.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "read_file") == null);
    }
}

test "macro eval rejects bare underscore-prefixed call in macro body" {
    const source =
        \\pub struct Test {
        \\  pub macro bad() -> Expr {
        \\    _helper()
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    bad()
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

    var found_error = false;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_helper` from macro code") != null) {
            found_error = true;
            break;
        }
    }
    try std.testing.expect(found_error);
}

test "macro eval rejects qualified underscore-prefixed call in macro body" {
    const source =
        \\pub struct Helper {
        \\  pub macro _hidden() -> Expr {
        \\    quote { 1 }
        \\  }
        \\}
        \\
        \\pub struct Test {
        \\  pub macro bad() -> Expr {
        \\    Helper._hidden()
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    bad()
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

    var found_error = false;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_hidden` from macro code") != null) {
            found_error = true;
            break;
        }
    }
    try std.testing.expect(found_error);
}

test "macro engine rejects direct bare underscore-prefixed macro call" {
    const source =
        \\pub struct Test {
        \\  pub macro _hidden() -> Expr {
        \\    quote { 1 }
        \\  }
        \\
        \\  pub fn run() -> i64 {
        \\    _hidden()
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

    var found_error = false;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `_hidden/0`") != null) {
            found_error = true;
            break;
        }
    }
    try std.testing.expect(found_error);
}

test "macro engine rejects direct qualified __using__ macro call" {
    const source =
        \\pub struct Provider {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    quote {
        \\      pub fn injected() -> i64 { 1 }
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Test {
        \\  pub fn run() -> i64 {
        \\    Provider.__using__([])
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

    var found_error = false;
    for (engine.errors.items) |err| {
        if (std.mem.find(u8, err.message, "cannot call underscore-prefixed function `__using__/1`") != null) {
            found_error = true;
            break;
        }
    }
    try std.testing.expect(found_error);
}

test "capability: macro-to-macro chain expands cleanly when inference grants caps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "fixture.txt",
        .data = "fixture",
    });
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(std.Options.debug_io, "fixture.txt", alloc);

    const macros_decl = try std.fmt.allocPrint(alloc,
        \\  pub macro inner_io() {{
        \\    read_file("{s}")
        \\  }}
        \\
        \\  pub macro outer_io() {{
        \\    inner_io()
        \\  }}
    , .{tmp_path});
    const source = try buildCapTestSource(alloc, macros_decl, "outer_io()");

    var parser = Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);
    try std.testing.expectEqual(@as(usize, 0), collector.errors.items.len);

    try @import("capability_inference.zig").inferAndApply(alloc, &collector.graph, parser.interner);

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    _ = try engine.expandProgram(&program);

    for (engine.errors.items) |err| {
        try std.testing.expect(std.mem.find(u8, err.message, "read_file") == null);
        try std.testing.expect(std.mem.find(u8, err.message, "capabilit") == null);
    }
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

// ============================================================
// Zest describe migration tests (Task #5: pure-Zap describe macro)
//
// These tests validate the Architecture A approach: `describe`
// directly walks its body's statements, generating per-test fn
// declarations + tracking calls in pure Zap. No Zig builtin
// `build_test_fns` is invoked — every transformation is expressed
// through comptime intrinsics (`for`, `list_at`,
// `intern_atom`, `slugify`, `make_call`,
// list-ops) and `quote`. Setup/teardown bodies are captured as
// macro-local CtValues and spliced into the per-test fn bodies; no
// struct-attribute side channel is used.
//
// The describe macro definition is inlined in each test so the
// tests document the exact shape expected of the migrated
// `lib/zest/case.zap` `describe` macro.
// ============================================================

const ZEST_DESCRIBE_INLINE_PRELUDE =
    \\  pub macro setup(body :: Expr) -> Expr {
    \\    quote { unquote(body) }
    \\  }
    \\
    \\  pub macro teardown(body :: Expr) -> Expr {
    \\    quote { unquote(body) }
    \\  }
    \\
    \\  pub macro describe(_name :: Expr, body :: Expr) -> Expr {
    \\    _stmts = elem(body, 2)
    \\    _setup_matches = for _s <- _stmts, elem(_s, 0) == :setup { list_at(elem(_s, 2), -1) }
    \\    _teardown_matches = for _s <- _stmts, elem(_s, 0) == :teardown { list_at(elem(_s, 2), -1) }
    \\    _setup_body = list_at(_setup_matches, 0)
    \\    _teardown_body = list_at(_teardown_matches, 0)
    \\    _desc_slug = slugify(_name)
    \\
    \\    _per_test = for _t <- _stmts, elem(_t, 0) == :test {
    \\      quote {
    \\        pub fn unquote(intern_atom("test_" <> _desc_slug <> "_" <> slugify(list_at(elem(_t, 2), 0))))() -> String {
    \\          unquote(make_call("__block__", list_concat(list_concat(list_concat(if list_length(elem(_t, 2)) == 3 and _setup_body != nil { [make_call("=", [ctx, _setup_body])] } else { [] }, if elem(list_at(elem(_t, 2), -1), 0) == :__block__ { elem(list_at(elem(_t, 2), -1), 2) } else { [list_at(elem(_t, 2), -1)] }), if _teardown_body != nil { [_teardown_body] } else { [] }), ["ok"])))
    \\        }
    \\        :zig.Zest.begin_test()
    \\        unquote(intern_atom("test_" <> _desc_slug <> "_" <> slugify(list_at(elem(_t, 2), 0))))()
    \\        :zig.Zest.end_test()
    \\        :zig.Zest.print_result()
    \\        "."
    \\      }
    \\    }
    \\
    \\    _passthrough = for _s <- _stmts, elem(_s, 0) != :test and elem(_s, 0) != :setup and elem(_s, 0) != :teardown { _s }
    \\
    \\    _all = list_concat(_per_test, _passthrough)
    \\
    \\    quote { unquote_splicing(_all) }
    \\  }
;

test "Zest describe migration T1: single test generates fn test_<group>_<test> with bare-name tracking call" {
    const source = "pub struct Test {\n" ++ ZEST_DESCRIBE_INLINE_PRELUDE ++
        \\
        \\  describe("group") {
        \\    test("t1") {
        \\      1
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    var found_fn = false;
    var found_tracking_call = false;
    var any_colon_prefixed = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            switch (item) {
                .function => |f| {
                    const name = parser.interner.get(f.name);
                    if (std.mem.eql(u8, name, "test_group_t1")) found_fn = true;
                },
                .struct_level_expr => |e| {
                    if (e.* == .call and e.call.callee.* == .var_ref) {
                        const callee_name = parser.interner.get(e.call.callee.var_ref.name);
                        if (callee_name.len > 0 and callee_name[0] == ':') any_colon_prefixed = true;
                        if (std.mem.eql(u8, callee_name, "test_group_t1")) found_tracking_call = true;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(found_fn);
    try std.testing.expect(found_tracking_call);
    try std.testing.expect(!any_colon_prefixed);
}

test "Zest describe migration T2: two tests in describe produce two distinct fn names and two tracking calls" {
    const source = "pub struct Test {\n" ++ ZEST_DESCRIBE_INLINE_PRELUDE ++
        \\
        \\  describe("group") {
        \\    test("alpha") {
        \\      1
        \\    }
        \\
        \\    test("beta") {
        \\      2
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    var seen_alpha_fn = false;
    var seen_beta_fn = false;
    var seen_alpha_tracking = false;
    var seen_beta_tracking = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            switch (item) {
                .function => |f| {
                    const name = parser.interner.get(f.name);
                    if (std.mem.eql(u8, name, "test_group_alpha")) seen_alpha_fn = true;
                    if (std.mem.eql(u8, name, "test_group_beta")) seen_beta_fn = true;
                },
                .struct_level_expr => |e| {
                    if (e.* == .call and e.call.callee.* == .var_ref) {
                        const callee_name = parser.interner.get(e.call.callee.var_ref.name);
                        if (std.mem.eql(u8, callee_name, "test_group_alpha")) seen_alpha_tracking = true;
                        if (std.mem.eql(u8, callee_name, "test_group_beta")) seen_beta_tracking = true;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(seen_alpha_fn);
    try std.testing.expect(seen_beta_fn);
    try std.testing.expect(seen_alpha_tracking);
    try std.testing.expect(seen_beta_tracking);
}

test "Zest describe migration T3: setup body threads through ctx binding into test/3 body" {
    // describe with `setup() { 42 }` and `test("uses ctx", ctx) { ctx }`.
    // The generated test fn body MUST start with an assignment binding
    // `ctx` to the setup body's value, so the `ctx` reference inside
    // the test resolves at runtime. The migration assembles the fn
    // body as `[ctx = setup_body, test_body_stmts..., "ok"]`.
    const source = "pub struct Test {\n" ++ ZEST_DESCRIBE_INLINE_PRELUDE ++
        \\
        \\  describe("group") {
        \\    setup() {
        \\      42
        \\    }
        \\
        \\    test("uses ctx", ctx) {
        \\      ctx
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    var test_fn: ?*const ast.FunctionDecl = null;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            if (item == .function) {
                const name = parser.interner.get(item.function.name);
                if (std.mem.eql(u8, name, "test_group_uses_ctx")) test_fn = item.function;
            }
        }
    }
    try std.testing.expect(test_fn != null);
    const decl = test_fn.?;
    try std.testing.expect(decl.clauses.len >= 1);
    const body = decl.clauses[0].body orelse return error.TestExpectedABody;
    // First stmt should be the ctx assignment.
    try std.testing.expect(body.len >= 1);
    try std.testing.expect(body[0] == .assignment);
    const assign = body[0].assignment;
    try std.testing.expect(assign.pattern.* == .bind);
    const ctx_name = parser.interner.get(assign.pattern.bind.name);
    try std.testing.expectEqualStrings("ctx", ctx_name);
}

test "Zest describe migration T4: teardown body appended as a statement in each test fn body" {
    // Both test fns should contain the teardown expression as a stmt
    // before the trailing "ok". We detect by checking each fn body
    // contains an integer literal `99` (the teardown's body).
    const source = "pub struct Test {\n" ++ ZEST_DESCRIBE_INLINE_PRELUDE ++
        \\
        \\  describe("group") {
        \\    test("a") {
        \\      1
        \\    }
        \\
        \\    test("b") {
        \\      2
        \\    }
        \\
        \\    teardown() {
        \\      99
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

    var engine = MacroEngine.init(alloc, parser.interner, &collector.graph);
    defer engine.deinit();
    const expanded = try engine.expandProgram(&program);

    var saw_99_in_a = false;
    var saw_99_in_b = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            if (item != .function) continue;
            const name = parser.interner.get(item.function.name);
            const is_a = std.mem.eql(u8, name, "test_group_a");
            const is_b = std.mem.eql(u8, name, "test_group_b");
            if (!is_a and !is_b) continue;
            const body = item.function.clauses[0].body orelse continue;
            for (body) |stmt| {
                // Teardown body is appended as a `__block__` stmt; in
                // ctValueToStmt that becomes either an int_literal
                // (single-stmt block unwrapped) or an `Expr.block`
                // wrapping the int. Either way the integer literal
                // 99 is reachable in the fn body.
                const e = if (stmt == .expr) stmt.expr else continue;
                switch (e.*) {
                    .int_literal => |lit| if (lit.value == 99) {
                        if (is_a) saw_99_in_a = true;
                        if (is_b) saw_99_in_b = true;
                    },
                    .block => |blk| for (blk.stmts) |inner| {
                        if (inner == .expr and inner.expr.* == .int_literal and inner.expr.int_literal.value == 99) {
                            if (is_a) saw_99_in_a = true;
                            if (is_b) saw_99_in_b = true;
                        }
                    },
                    else => {},
                }
            }
        }
    }
    try std.testing.expect(saw_99_in_a);
    try std.testing.expect(saw_99_in_b);
}

test "Zest describe migration T5: bare test outside describe produces test_<slug> via test/2 macro" {
    // The migrated `test/2` macro (sibling of describe in
    // `lib/zest/case.zap`) handles the no-describe case and emits
    // `test_<slug>` directly. Crucially the fn body contains ONLY
    // the user's body + "ok"; the begin_test/end_test/print_result
    // tracking calls live at struct scope, NOT inside the fn body
    // (matches the build_test_fn-equivalent path the deleted Zig
    // builtin produced).
    const source =
        \\pub struct Test {
        \\  pub macro test(_name :: Expr, body :: Expr) -> Expr {
        \\    _fn_atom = intern_atom("test_" <> slugify(_name))
        \\    quote {
        \\      pub fn unquote(_fn_atom)() -> String {
        \\        unquote(body)
        \\        "ok"
        \\      }
        \\      :zig.Zest.begin_test()
        \\      unquote(_fn_atom)()
        \\      :zig.Zest.end_test()
        \\      :zig.Zest.print_result()
        \\      "."
        \\    }
        \\  }
        \\
        \\  test("solo") {
        \\    1
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

    var saw_fn = false;
    var saw_tracking = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            switch (item) {
                .function => |f| {
                    if (std.mem.eql(u8, parser.interner.get(f.name), "test_solo")) saw_fn = true;
                },
                .struct_level_expr => |e| {
                    if (e.* == .call and e.call.callee.* == .var_ref) {
                        if (std.mem.eql(u8, parser.interner.get(e.call.callee.var_ref.name), "test_solo")) saw_tracking = true;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(saw_fn);
    try std.testing.expect(saw_tracking);
}

test "Flatt-2016 hygiene: swap-macro discriminates user vs template identifiers via scope sets" {
    // Canonical swap-macro test for set-of-scopes hygiene. The macro
    // introduces `tmp` in its template body and references the user's
    // identifier via `unquote(...)`. When the user passes the symbol
    // `tmp` as the macro argument, both `tmp` occurrences in the
    // expanded body must carry distinct `meta.scopes` so resolution
    // can disambiguate them: the template-introduced `tmp` carries
    // the macro-introduction scope plus the use-site scope (via the
    // result-flip), while the user-supplied `tmp` carries its
    // original scope set unchanged.
    //
    // Under the previous generation-counter mechanism, no scope
    // marks were set and the two `tmp` references would resolve to
    // the same binding. Under Flatt-2016, their scope sets must
    // differ — and `ScopeGraph.resolveBindingByScopes` must be able
    // to distinguish synthetic bindings keyed by those sets.
    const source =
        \\pub struct Test {
        \\  pub macro hyg_swap(user_id) {
        \\    quote {
        \\      tmp + unquote(user_id)
        \\    }
        \\  }
        \\
        \\  pub fn caller() -> i64 {
        \\    hyg_swap(tmp)
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

    // Locate `caller`'s expanded body: it should contain a binary
    // `+` whose left operand is the template-introduced `tmp` and
    // whose right operand is the user-supplied `tmp`. Both refer to
    // the same name string but must carry different scope sets.
    var caller_fn: ?*const ast.FunctionDecl = null;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            if (item == .function) {
                if (std.mem.eql(u8, parser.interner.get(item.function.name), "caller")) {
                    caller_fn = item.function;
                }
            }
        }
    }
    try std.testing.expect(caller_fn != null);

    const decl = caller_fn.?;
    try std.testing.expect(decl.clauses.len >= 1);
    const body = decl.clauses[0].body orelse return error.TestExpectedABody;
    try std.testing.expect(body.len >= 1);

    // Drill into the trailing expression. The macro produced a
    // single quote-body statement (`tmp + unquote(user_id)`), so
    // after expansion the function body's terminal stmt is the
    // binary `+`. Iterate forward from the last stmt through any
    // wrapper blocks until we land on the binary op.
    const tmp_name = try parser.interner.intern("tmp");

    var binop: ?*const ast.BinaryOp = null;
    var cursor: ?*const ast.Expr = if (body[body.len - 1] == .expr) body[body.len - 1].expr else null;
    while (cursor) |e| {
        switch (e.*) {
            .binary_op => |bop| {
                if (bop.op == .add) {
                    binop = &e.binary_op;
                    break;
                }
                cursor = null;
            },
            .block => |blk| {
                if (blk.stmts.len == 0) {
                    cursor = null;
                } else {
                    cursor = if (blk.stmts[blk.stmts.len - 1] == .expr) blk.stmts[blk.stmts.len - 1].expr else null;
                }
            },
            else => cursor = null,
        }
    }
    try std.testing.expect(binop != null);
    const op = binop.?;
    try std.testing.expect(op.lhs.* == .var_ref);
    try std.testing.expect(op.rhs.* == .var_ref);

    const left_ref = op.lhs.var_ref;
    const right_ref = op.rhs.var_ref;
    try std.testing.expectEqual(tmp_name, left_ref.name);
    try std.testing.expectEqual(tmp_name, right_ref.name);

    // Both refs share the textual name `tmp` but the macro engine
    // must have stamped distinct scope sets onto them. Empty == empty
    // is the failure mode under the deleted generation-counter
    // mechanism, so we explicitly assert the sets differ.
    const left_scopes = left_ref.meta.scopes;
    const right_scopes = right_ref.meta.scopes;
    try std.testing.expect(!left_scopes.eq(right_scopes));

    // Identify which side is which by membership: the template-
    // introduced `tmp` must carry strictly more scopes (intro_scope
    // + use_scope from the flip) than the user-supplied `tmp` (which
    // came in with the empty set and the use_scope was flipped off).
    const template_ref = if (left_scopes.len() > right_scopes.len()) left_ref else right_ref;
    const user_ref = if (left_scopes.len() > right_scopes.len()) right_ref else left_ref;
    try std.testing.expect(template_ref.meta.scopes.len() > 0);
    try std.testing.expectEqual(@as(usize, 0), user_ref.meta.scopes.len());

    // The discriminating property: if we register two synthetic
    // bindings — one whose scope set matches the template ref, one
    // whose scope set is empty — then a reference carrying each side's
    // scope set must resolve to the correct binding. This is the
    // contract `resolveBindingByScopes` provides; the swap-macro is
    // the canonical case it discriminates.
    // `addOne` returns a pointer into the bindings ArrayList; a
    // subsequent append can reallocate that list and invalidate the
    // earlier pointer, so we capture the assigned ids by value before
    // adding the second binding.
    const template_binding_scopes = try template_ref.meta.scopes.clone(alloc);
    const template_binding_id: scope.BindingId = @intCast(collector.graph.bindings.items.len);
    {
        const slot = try collector.graph.bindings.addOne(collector.graph.allocator);
        slot.* = .{
            .id = template_binding_id,
            .name = tmp_name,
            .scope_id = 0,
            .kind = .variable,
            .span = .{ .start = 0, .end = 0 },
            .scopes = template_binding_scopes,
        };
    }

    const user_binding_scopes: scope.ScopeSet = .empty;
    const user_binding_id: scope.BindingId = @intCast(collector.graph.bindings.items.len);
    {
        const slot = try collector.graph.bindings.addOne(collector.graph.allocator);
        slot.* = .{
            .id = user_binding_id,
            .name = tmp_name,
            .scope_id = 0,
            .kind = .variable,
            .span = .{ .start = 0, .end = 0 },
            .scopes = user_binding_scopes,
        };
    }

    // Reference scope sets:
    //   template_ref's set must dominate template_binding.scopes
    //   user_ref's set is empty; only the user_binding (with empty
    //   scopes) is a subset, so it wins.
    const template_resolved = collector.graph.resolveBindingByScopes(template_ref.meta.scopes, tmp_name);
    const user_resolved = collector.graph.resolveBindingByScopes(user_ref.meta.scopes, tmp_name);

    try std.testing.expect(template_resolved != null);
    try std.testing.expect(user_resolved != null);
    try std.testing.expect(template_resolved.? != user_resolved.?);
    try std.testing.expectEqual(template_binding_id, template_resolved.?);
    try std.testing.expectEqual(user_binding_id, user_resolved.?);
}

test "Flatt-2016 hygiene: resolveBindingHygienic discriminates user vs macro-introduced tmp at the resolver layer" {
    // Companion to the swap-macro scope-set test above. That test
    // proves the macro engine stamps distinct scope sets onto the
    // template-introduced `tmp` and the user-supplied `tmp`. THIS
    // test proves the resolver call sites (types.zig, hir.zig,
    // resolver.zig) consume those marks via the unified
    // `resolveBindingHygienic` helper and pick distinct bindings —
    // the contract every production resolver was migrated to in
    // Phase-3 step 8.
    //
    // Under the lexical-chain-only `resolveBinding`, both `tmp`
    // identifiers would share the same lexical scope and resolve
    // to whichever binding happened to be registered last in the
    // scope chain — the macro's hidden `tmp` would shadow the user's
    // `tmp`, breaking hygiene. With the scope-set path active, the
    // template-introduced reference (carrying intro_scope +
    // use_scope) resolves to the binding tagged with those scopes;
    // the user-supplied reference (carrying its original empty set)
    // resolves to the binding registered in the user's lexical
    // scope.
    const source =
        \\pub struct Test {
        \\  pub macro hyg_swap(user_id) {
        \\    quote {
        \\      tmp + unquote(user_id)
        \\    }
        \\  }
        \\
        \\  pub fn caller() -> i64 {
        \\    hyg_swap(tmp)
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

    var caller_fn: ?*const ast.FunctionDecl = null;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Test")) continue;
        for (mod.items) |item| {
            if (item == .function) {
                if (std.mem.eql(u8, parser.interner.get(item.function.name), "caller")) {
                    caller_fn = item.function;
                }
            }
        }
    }
    try std.testing.expect(caller_fn != null);

    const decl = caller_fn.?;
    try std.testing.expect(decl.clauses.len >= 1);
    const body = decl.clauses[0].body orelse return error.TestExpectedABody;
    try std.testing.expect(body.len >= 1);

    const tmp_name = try parser.interner.intern("tmp");

    var binop: ?*const ast.BinaryOp = null;
    var cursor: ?*const ast.Expr = if (body[body.len - 1] == .expr) body[body.len - 1].expr else null;
    while (cursor) |e| {
        switch (e.*) {
            .binary_op => |bop| {
                if (bop.op == .add) {
                    binop = &e.binary_op;
                    break;
                }
                cursor = null;
            },
            .block => |blk| {
                if (blk.stmts.len == 0) {
                    cursor = null;
                } else {
                    cursor = if (blk.stmts[blk.stmts.len - 1] == .expr) blk.stmts[blk.stmts.len - 1].expr else null;
                }
            },
            else => cursor = null,
        }
    }
    try std.testing.expect(binop != null);
    const op = binop.?;
    try std.testing.expect(op.lhs.* == .var_ref);
    try std.testing.expect(op.rhs.* == .var_ref);

    const left_ref = op.lhs.var_ref;
    const right_ref = op.rhs.var_ref;
    try std.testing.expectEqual(tmp_name, left_ref.name);
    try std.testing.expectEqual(tmp_name, right_ref.name);

    // The template-introduced ref carries strictly more scopes than
    // the user-supplied ref; pick the right side via length.
    const template_ref = if (left_ref.meta.scopes.len() > right_ref.meta.scopes.len()) left_ref else right_ref;
    const user_ref = if (left_ref.meta.scopes.len() > right_ref.meta.scopes.len()) right_ref else left_ref;

    // Register two real bindings via the public createBindingWithScopes
    // API — one in the user's lexical scope (caller's clause scope),
    // matching the empty user scope set; one tagged with the template's
    // scope set, mimicking what the collector would record when it
    // walks a macro-introduced `let tmp = ...` binder. The lexical
    // scope_id we hand the API is the same for both bindings; the
    // discriminator is the scope set, not the chain. That is the
    // entire premise of Flatt-2016 hygiene.
    const caller_meta = decl.clauses[0].meta;
    const caller_clause_scope = collector.graph.resolveClauseScope(caller_meta) orelse caller_meta.scope_id;

    const user_binding_id = try collector.graph.createBindingWithScopes(
        tmp_name,
        caller_clause_scope,
        .pattern_bind,
        .{ .start = 0, .end = 0 },
        user_ref.meta.scopes,
    );

    // For the second binding we must NOT call createBindingWithScopes
    // directly into the same scope_id with the same name — it would
    // overwrite the scope.bindings hashmap entry and wipe out the
    // user binding's scope-table registration, which the lexical
    // resolver still needs as a fallback. Append the synthetic
    // template binding directly to graph.bindings so the scope-set
    // resolver can see it without disturbing the lexical chain.
    const template_binding_scopes = try template_ref.meta.scopes.clone(alloc);
    const template_binding_id: scope.BindingId = @intCast(collector.graph.bindings.items.len);
    {
        const slot = try collector.graph.bindings.addOne(collector.graph.allocator);
        slot.* = .{
            .id = template_binding_id,
            .name = tmp_name,
            .scope_id = caller_clause_scope,
            .kind = .pattern_bind,
            .span = .{ .start = 0, .end = 0 },
            .scopes = template_binding_scopes,
        };
    }

    // The contract under test:
    //   resolveBindingHygienic(scope, name, template_ref.scopes)
    //     => template_binding_id
    //   resolveBindingHygienic(scope, name, user_ref.scopes)
    //     => user_binding_id
    // Distinct identifiers, distinct bindings, even though both
    // share the lexical scope and the textual name. Lexical-only
    // resolution would collapse them to a single binding.
    const template_resolved = collector.graph.resolveBindingHygienic(
        caller_clause_scope,
        tmp_name,
        template_ref.meta.scopes,
    );
    const user_resolved = collector.graph.resolveBindingHygienic(
        caller_clause_scope,
        tmp_name,
        user_ref.meta.scopes,
    );

    try std.testing.expect(template_resolved != null);
    try std.testing.expect(user_resolved != null);
    try std.testing.expect(template_resolved.? != user_resolved.?);
    try std.testing.expectEqual(template_binding_id, template_resolved.?);
    try std.testing.expectEqual(user_binding_id, user_resolved.?);
}

// ============================================================
// Phase 10: ExpansionInfo provenance — TDD tests
//
// These tests lock in the contract that every node produced by a
// macro expansion carries a NodeMeta.expansion pointer to a shared
// ExpansionInfo describing the call site, and that nested macros
// chain via `parent`. They run independently of any LSP consumer; the
// goal is to prevent silent regression of the provenance plumbing.
// ============================================================

/// Walk an Expr and return the first non-null `meta.expansion`
/// pointer encountered (preorder). Used by tests to confirm that
/// macro output carries provenance regardless of which expansion
/// path produced it (fast path vs eval path may wrap results
/// differently).
fn findFirstExpansion(expr: *const ast.Expr) ?*const ast.ExpansionInfo {
    if (expr.getMeta().expansion) |info| return info;
    return switch (expr.*) {
        .if_expr => |ie| blk: {
            if (findFirstExpansion(ie.condition)) |info| break :blk info;
            for (ie.then_block) |stmt| switch (stmt) {
                .expr => |e| if (findFirstExpansion(e)) |info| break :blk info,
                else => {},
            };
            if (ie.else_block) |else_block| {
                for (else_block) |stmt| switch (stmt) {
                    .expr => |e| if (findFirstExpansion(e)) |info| break :blk info,
                    else => {},
                };
            }
            break :blk null;
        },
        .case_expr => |ce| blk: {
            if (findFirstExpansion(ce.scrutinee)) |info| break :blk info;
            for (ce.clauses) |clause| {
                for (clause.body) |stmt| switch (stmt) {
                    .expr => |e| if (findFirstExpansion(e)) |info| break :blk info,
                    else => {},
                };
            }
            break :blk null;
        },
        .block => |b| blk: {
            for (b.stmts) |stmt| switch (stmt) {
                .expr => |e| if (findFirstExpansion(e)) |info| break :blk info,
                else => {},
            };
            break :blk null;
        },
        .call => |c| blk: {
            if (findFirstExpansion(c.callee)) |info| break :blk info;
            for (c.args) |arg| if (findFirstExpansion(arg)) |info| break :blk info;
            break :blk null;
        },
        .binary_op => |b| findFirstExpansion(b.lhs) orelse findFirstExpansion(b.rhs),
        .unary_op => |u| findFirstExpansion(u.operand),
        else => null,
    };
}

/// Locate the first expression in the body of a top-level function by
/// name. Returns null if not found. Used by provenance tests to reach
/// the macro-produced node from the expanded program.
fn findFunctionBodyExpr(
    program: *const ast.Program,
    interner: *const ast.StringInterner,
    fn_name: []const u8,
) ?*const ast.Expr {
    for (program.structs) |s| {
        for (s.items) |item| switch (item) {
            .function => |fd| {
                if (std.mem.eql(u8, interner.get(fd.name), fn_name)) {
                    if (fd.clauses.len == 0) return null;
                    const body = fd.clauses[0].body orelse return null;
                    if (body.len == 0) return null;
                    return switch (body[0]) {
                        .expr => |e| e,
                        else => null,
                    };
                }
            },
            else => {},
        };
    }
    return null;
}

test "expansion provenance: macro output carries call_site and macro_name" {
    const source =
        \\pub struct Test {
        \\  pub macro double(value) {
        \\    quote {
        \\      unquote(value) + unquote(value)
        \\    }
        \\  }
        \\
        \\  pub fn foo(x :: i64) -> i64 {
        \\    double(x)
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
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);

    const body_expr = findFunctionBodyExpr(&expanded, parser.interner, "foo") orelse {
        try std.testing.expect(false);
        return;
    };

    const info = findFirstExpansion(body_expr) orelse {
        try std.testing.expect(false);
        return;
    };

    try std.testing.expectEqualStrings("double", parser.interner.get(info.macro_name));
    // The call_site span must not be the zero default — it should
    // point at the macro call inside the function body.
    try std.testing.expect(info.call_site.end > info.call_site.start);
    // Outermost expansion: no parent.
    try std.testing.expect(info.parent == null);
}

test "expansion provenance: nested macro chains via parent" {
    const source =
        \\pub struct Test {
        \\  pub macro inner(x) {
        \\    quote {
        \\      unquote(x) + 1
        \\    }
        \\  }
        \\
        \\  pub macro outer(x) {
        \\    quote {
        \\      inner(unquote(x))
        \\    }
        \\  }
        \\
        \\  pub fn foo(n :: i64) -> i64 {
        \\    outer(n)
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
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);

    const body_expr = findFunctionBodyExpr(&expanded, parser.interner, "foo") orelse {
        try std.testing.expect(false);
        return;
    };

    const info = findFirstExpansion(body_expr) orelse {
        try std.testing.expect(false);
        return;
    };

    // The body's first node was produced by the inner expansion. Its
    // parent chain must reach up through the outer expansion to user
    // source.
    try std.testing.expect(info.parent != null);
    const parent = info.parent.?;
    try std.testing.expect(parent.parent == null);

    // Macro names: leaf is `inner`, parent is `outer`.
    try std.testing.expectEqualStrings("inner", parser.interner.get(info.macro_name));
    try std.testing.expectEqualStrings("outer", parser.interner.get(parent.macro_name));
}

test "expansion provenance: source-level nodes have no expansion stamp" {
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
    try std.testing.expectEqual(@as(usize, 0), engine.errors.items.len);

    const body_expr = findFunctionBodyExpr(&expanded, parser.interner, "add") orelse {
        try std.testing.expect(false);
        return;
    };

    // No macro was invoked; nothing in this body should carry a
    // provenance stamp.
    try std.testing.expect(body_expr.getMeta().expansion == null);
    try std.testing.expect(findFirstExpansion(body_expr) == null);
}

test "use macro receives explicit empty option list" {
    const source =
        \\pub struct Provider {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    quote {
        \\      @received_opts = unquote(_opts)
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Consumer {
        \\  use Provider, []
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

    var found_received_opts = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Consumer")) continue;
        for (mod.items) |item| {
            if (item != .attribute) continue;
            const attr = item.attribute;
            if (!std.mem.eql(u8, parser.interner.get(attr.name), "received_opts")) continue;
            found_received_opts = true;
            const value = attr.value orelse return error.MissingReceivedOptionsValue;
            try std.testing.expect(value.* == .list);
            try std.testing.expectEqual(@as(usize, 0), value.list.elements.len);
        }
    }

    try std.testing.expect(found_received_opts);
}

test "use macro receives bare pattern keyword option list" {
    const source =
        \\pub struct Provider {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    quote {
        \\      @received_opts = unquote(_opts)
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Consumer {
        \\  use Provider, pattern: "test/**/*_test.zap"
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

    var found_received_opts = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Consumer")) continue;
        for (mod.items) |item| {
            if (item != .attribute) continue;
            const attr = item.attribute;
            if (!std.mem.eql(u8, parser.interner.get(attr.name), "received_opts")) continue;
            found_received_opts = true;
            const value = attr.value orelse return error.MissingReceivedOptionsValue;
            try std.testing.expect(value.* == .list);
            try std.testing.expectEqual(@as(usize, 1), value.list.elements.len);

            const option = value.list.elements[0];
            try std.testing.expect(option.* == .tuple);
            try std.testing.expectEqual(@as(usize, 2), option.tuple.elements.len);
            try std.testing.expect(option.tuple.elements[0].* == .atom_literal);
            try std.testing.expectEqualStrings("pattern", parser.interner.get(option.tuple.elements[0].atom_literal.value));
            try std.testing.expect(option.tuple.elements[1].* == .string_literal);
            try std.testing.expectEqualStrings("test/**/*_test.zap", parser.interner.get(option.tuple.elements[1].string_literal.value));
        }
    }

    try std.testing.expect(found_received_opts);
}

// When a consumer struct does multiple `use` declarations and several of
// the targets define `__using__/1`, every target's `__using__` must run
// against the consumer — not just the first one reachable through the
// consumer's import chain.
test "use macro looks up __using__ in the use target's own scope, not the consumer's import-walk" {
    const source =
        \\pub struct First {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    quote {
        \\      pub fn first_marker() -> i64 {
        \\        1
        \\      }
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Second {
        \\  pub macro __using__(_opts :: Expr) -> Expr {
        \\    quote {
        \\      pub fn second_marker() -> i64 {
        \\        2
        \\      }
        \\    }
        \\  }
        \\}
        \\
        \\pub struct Consumer {
        \\  use First
        \\  use Second
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

    var found_first_marker = false;
    var found_second_marker = false;
    for (expanded.structs) |mod| {
        if (mod.name.parts.len != 1) continue;
        if (!std.mem.eql(u8, parser.interner.get(mod.name.parts[0]), "Consumer")) continue;
        for (mod.items) |item| {
            if (item != .function) continue;
            const name = parser.interner.get(item.function.name);
            if (std.mem.eql(u8, name, "first_marker")) found_first_marker = true;
            if (std.mem.eql(u8, name, "second_marker")) found_second_marker = true;
        }
    }

    try std.testing.expect(found_first_marker);
    try std.testing.expect(found_second_marker);
}
