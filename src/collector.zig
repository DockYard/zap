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
    /// Pre-interned StringId for "Kernel" — used to inject auto-import.
    kernel_name_id: ?ast.StringId,

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(allocator: std.mem.Allocator, interner: *const ast.StringInterner, kernel_name_id: ?ast.StringId) Collector {
        return .{
            .allocator = allocator,
            .graph = scope.ScopeGraph.init(allocator),
            .interner = interner,
            .errors = .empty,
            .kernel_name_id = kernel_name_id,
        };
    }

    pub fn deinit(self: *Collector) void {
        self.graph.deinit();
        self.errors.deinit(self.allocator);
    }

    /// Check if a module has an explicit `import Kernel` or `import Kernel, except: [...]`.
    fn hasExplicitKernelImport(_: *const Collector, mod: *const ast.StructDecl, kernel_id: ast.StringId) bool {
        for (mod.items) |item| {
            switch (item) {
                .import_decl => |id_decl| {
                    if (id_decl.module_path.parts.len == 1 and id_decl.module_path.parts[0] == kernel_id)
                        return true;
                },
                .use_decl => |ud| {
                    if (ud.module_path.parts.len == 1 and ud.module_path.parts[0] == kernel_id)
                        return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn addError(self: *Collector, message: []const u8, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    // ============================================================
    // Top-level collection entry point
    // ============================================================

    pub fn collectProgram(self: *Collector, program: *const ast.Program) !void {
        try self.collectProgramSurface(program);

        // Second pass: resolve struct extends (copy parent fields into children)
        try self.resolveNestedStructExtends();

        // Third pass: resolve module extends (copy parent function families into children)
        try self.resolveStructExtends(program);
    }

    pub fn collectProgramSurface(self: *Collector, program: *const ast.Program) !void {
        // Process top-level structs
        for (program.structs) |*mod| {
            try self.collectStruct(mod, self.graph.prelude_scope);
        }

        // Process top-level items (functions, types outside structs)
        // Structs are already processed above via program.structs, skip them here.
        // Top-level @doc attributes are attached to the next definition.
        var pending_top_doc: ?scope.Attribute = null;
        for (program.top_items) |item| {
            switch (item) {
                .attribute => |attr| {
                    pending_top_doc = .{
                        .name = attr.name,
                        .type_expr = attr.type_expr,
                        .value = attr.value,
                    };
                },
                .struct_decl, .priv_struct_decl => |sd| {
                    // Struct already collected above. Attach pending @doc if any.
                    if (pending_top_doc) |doc_attr| {
                        for (self.graph.structs.items) |*mod_entry| {
                            if (mod_entry.decl == sd) {
                                try mod_entry.attributes.append(self.allocator, doc_attr);
                                break;
                            }
                        }
                        pending_top_doc = null;
                    }
                },
                .union_decl => |ed| {
                    try self.collectUnion(ed, self.graph.prelude_scope);
                    if (pending_top_doc) |_| {
                        // TODO: attach doc to union type entry when attribute storage is added
                        pending_top_doc = null;
                    }
                },
                .protocol, .priv_protocol => |proto| {
                    try self.collectProtocol(proto);
                    if (pending_top_doc) |doc_attr| {
                        // Attach doc to the protocol entry
                        for (self.graph.protocols.items) |*proto_entry| {
                            if (proto_entry.decl == proto) {
                                try proto_entry.attributes.append(self.allocator, doc_attr);
                                break;
                            }
                        }
                        pending_top_doc = null;
                    }
                },
                .function => |func| {
                    try self.collectFunction(func, self.graph.prelude_scope);
                    pending_top_doc = null;
                },
                .priv_function => |func| {
                    try self.collectFunction(func, self.graph.prelude_scope);
                    pending_top_doc = null;
                },
                .macro => |mac| {
                    try self.collectMacro(mac, self.graph.prelude_scope);
                    pending_top_doc = null;
                },
                .priv_macro => |mac| {
                    try self.collectMacro(mac, self.graph.prelude_scope);
                    pending_top_doc = null;
                },
                .type_decl => |td| {
                    try self.collectType(td, self.graph.prelude_scope);
                    pending_top_doc = null;
                },
                .opaque_decl => |od| {
                    try self.collectOpaque(od, self.graph.prelude_scope);
                    pending_top_doc = null;
                },
                .impl_decl, .priv_impl_decl => |impl_d| {
                    try self.collectImpl(impl_d);
                    pending_top_doc = null;
                },
            }
        }
    }

    pub fn finalizeCollectedPrograms(self: *Collector, programs: []const ast.Program) !void {
        // Second pass: resolve struct extends (copy parent fields into children)
        try self.resolveNestedStructExtends();

        // Third pass: resolve module extends (copy parent function families into children)
        for (programs) |program| {
            try self.resolveStructExtends(&program);
        }
    }

    // ============================================================
    // Module collection
    // ============================================================

    fn collectStruct(self: *Collector, mod: *const ast.StructDecl, parent_scope: scope.ScopeId) !void {
        // Check for duplicate module declarations (only for module-like structs with items)
        if (mod.items.len > 0) {
            for (self.graph.structs.items) |existing| {
                if (existing.name.parts.len == mod.name.parts.len) {
                    var all_equal = true;
                    for (existing.name.parts, mod.name.parts) |a, b| {
                        if (a != b) {
                            all_equal = false;
                            break;
                        }
                    }
                    if (all_equal) {
                        // Build the full qualified name for the error message
                        var name_parts: std.ArrayListUnmanaged(u8) = .empty;
                        for (mod.name.parts, 0..) |part, i| {
                            if (i > 0) name_parts.appendSlice(self.allocator, ".") catch {};
                            name_parts.appendSlice(self.allocator, self.interner.get(part)) catch {};
                        }
                        const full_name = name_parts.items;
                        const msg = std.fmt.allocPrint(self.allocator, "struct '{s}' is already defined", .{full_name}) catch return error.OutOfMemory;
                        try self.addError(msg, mod.meta.span);
                        return;
                    }
                }
            }
        }

        const mod_scope = try self.graph.createScope(parent_scope, .module);
        try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(mod.meta.span), mod_scope);
        try self.graph.registerStruct(mod.name, mod_scope, mod);

        // If the struct has fields, also register it as a type so the type checker can find it
        if (mod.fields.len > 0 and mod.name.parts.len > 0) {
            // Build the full qualified name (e.g., "Zap.Env") for type registration
            const type_name_id = if (mod.name.parts.len == 1)
                mod.name.parts[0]
            else blk: {
                var name_buf: std.ArrayListUnmanaged(u8) = .empty;
                for (mod.name.parts, 0..) |part, i| {
                    if (i > 0) name_buf.appendSlice(self.allocator, ".") catch {};
                    name_buf.appendSlice(self.allocator, self.interner.get(part)) catch {};
                }
                const interner_mut = @constCast(self.interner);
                break :blk try interner_mut.intern(name_buf.items);
            };
            _ = try self.graph.registerType(
                type_name_id,
                mod_scope,
                .{ .struct_type = mod },
                &.{},
            );
        }

        // Auto-import Kernel into every module (Elixir-style).
        // Skip if: (a) this IS Kernel, or (b) module has an explicit Kernel import.
        if (self.kernel_name_id) |kid| {
            const is_kernel = mod.name.parts.len == 1 and mod.name.parts[0] == kid;
            if (!is_kernel and !self.hasExplicitKernelImport(mod, kid)) {
                const parts = try self.allocator.alloc(ast.StringId, 1);
                parts[0] = kid;
                try self.graph.getScopeMut(mod_scope).imports.append(self.allocator, .{
                    .source_module = .{ .parts = parts, .span = mod.meta.span },
                    .filter = .all,
                    .imported_families = std.AutoHashMap(scope.FamilyKey, scope.FunctionFamilyId).init(self.allocator),
                    .imported_types = std.AutoHashMap(ast.StringId, scope.TypeId).init(self.allocator),
                });
            }
        }

        // Track pending attributes to attach to the next function/macro
        var pending_attrs: std.ArrayListUnmanaged(scope.Attribute) = .empty;

        for (mod.items) |item| {
            switch (item) {
                .function => |func| {
                    try self.collectFunctionWithAttrs(func, mod_scope, &pending_attrs);
                    pending_attrs = .empty;
                },
                .priv_function => |func| {
                    try self.collectFunctionWithAttrs(func, mod_scope, &pending_attrs);
                    pending_attrs = .empty;
                },
                .macro => |mac| {
                    try self.collectMacroWithAttrs(mac, mod_scope, &pending_attrs);
                    pending_attrs = .empty;
                },
                .priv_macro => |mac| {
                    try self.collectMacroWithAttrs(mac, mod_scope, &pending_attrs);
                    pending_attrs = .empty;
                },
                .attribute => |attr| {
                    // All attributes inside struct bodies are pending for the next definition
                    try pending_attrs.append(self.allocator, .{
                        .name = attr.name,
                        .type_expr = attr.type_expr,
                        .value = attr.value,
                    });
                },
                .type_decl => |td| try self.collectType(td, mod_scope),
                .opaque_decl => |od| try self.collectOpaque(od, mod_scope),
                .struct_decl => |sd| try self.collectNestedStruct(sd, mod_scope),
                .union_decl => |ed| try self.collectUnion(ed, mod_scope),
                .alias_decl => |ad| try self.collectAlias(ad, mod_scope),
                .import_decl => |id_decl| try self.collectImport(id_decl, mod_scope),
                .use_decl => |ud| {
                    // `use Module` expands to `import Module` — collect the import directly
                    const import_decl = try self.allocator.create(ast.ImportDecl);
                    import_decl.* = .{
                        .meta = ud.meta,
                        .module_path = ud.module_path,
                        .filter = null, // import all
                    };
                    try self.collectImport(import_decl, mod_scope);
                },
                .struct_level_expr => |expr| {
                    try self.collectExprScopes(expr, mod_scope);
                },
            }
        }

        // Any remaining pending attributes are module-level (not attached to a function)
        if (pending_attrs.items.len > 0) {
            // Find the module entry and attach the attributes
            for (self.graph.structs.items) |*mod_entry| {
                if (mod_entry.scope_id == mod_scope) {
                    for (pending_attrs.items) |attr| {
                        try mod_entry.attributes.append(self.allocator, attr);
                    }
                    break;
                }
            }
        }
    }

    // ============================================================
    // Function collection — family grouping
    // ============================================================

    fn collectFunctionWithAttrs(
        self: *Collector,
        func: *const ast.FunctionDecl,
        parent_scope: scope.ScopeId,
        pending_attrs: *std.ArrayListUnmanaged(scope.Attribute),
    ) !void {
        try self.collectFunction(func, parent_scope);
        // Attach pending attributes to the function family
        if (pending_attrs.items.len > 0) {
            for (func.clauses) |clause| {
                const arity: u32 = @intCast(clause.params.len);
                const key = scope.FamilyKey{ .name = func.name, .arity = arity };
                const parent = self.graph.getScopeMut(parent_scope);
                if (parent.function_families.get(key)) |fid| {
                    const family = self.graph.getFamilyMut(fid);
                    for (pending_attrs.items) |attr| {
                        try family.attributes.append(self.allocator, attr);
                    }
                }
                break; // Only attach to the first clause's family
            }
        }
    }

    fn collectMacroWithAttrs(
        self: *Collector,
        mac: *const ast.FunctionDecl,
        parent_scope: scope.ScopeId,
        pending_attrs: *std.ArrayListUnmanaged(scope.Attribute),
    ) !void {
        try self.collectMacro(mac, parent_scope);
        // Attach pending attributes to the macro family
        // Macro families are stored on the ScopeGraph, indexed via the Scope's macro_families map
        if (pending_attrs.items.len > 0) {
            if (mac.clauses.len > 0) {
                const arity: u32 = @intCast(mac.clauses[0].params.len);
                const key = scope.FamilyKey{ .name = mac.name, .arity = arity };
                const parent = self.graph.getScopeMut(parent_scope);
                if (parent.macros.get(key)) |mid| {
                    for (pending_attrs.items) |attr| {
                        try self.graph.macro_families.items[mid].attributes.append(self.allocator, attr);
                    }
                }
            }
        }
    }

    fn collectProtocol(self: *Collector, proto: *const ast.ProtocolDecl) !void {
        const proto_scope = try self.graph.createScope(self.graph.prelude_scope, .module);
        try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(proto.meta.span), proto_scope);
        try self.graph.protocols.append(self.allocator, .{
            .name = proto.name,
            .scope_id = proto_scope,
            .decl = proto,
        });
    }

    fn collectImpl(self: *Collector, impl_d: *const ast.ImplDecl) !void {
        const impl_scope = try self.graph.createScope(self.graph.prelude_scope, .module);
        try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(impl_d.meta.span), impl_scope);

        // Collect each function in the impl block as a regular function
        for (impl_d.functions) |func| {
            try self.collectFunction(func, impl_scope);
        }

        try self.graph.impls.append(self.allocator, .{
            .protocol_name = impl_d.protocol_name,
            .target_type = impl_d.target_type,
            .scope_id = impl_scope,
            .decl = impl_d,
            .is_private = impl_d.is_private,
        });
    }

    pub fn collectFunction(self: *Collector, func: *const ast.FunctionDecl, parent_scope: scope.ScopeId) !void {
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
            try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(clause.meta.span), fn_scope);
            // Write scope ID directly onto the clause metadata so macro-generated
            // functions (which may have colliding spans) have a reliable fallback.
            // Without this, the default meta.scope_id = 0 (prelude) makes module-level
            // functions invisible during type inference in macro-generated code.
            @constCast(&clause.meta).scope_id = fn_scope;

            // Collect parameter bindings
            for (clause.params) |param| {
                try self.collectPatternBindings(param.pattern, fn_scope);
            }

            // Collect body statements (hoisting local defs)
            // Bodyless declarations (@native) have no body to collect.
            if (clause.body) |body| {
                try self.collectBlock(body, fn_scope);
            }
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
            try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(clause.meta.span), fn_scope);

            for (clause.params) |param| {
                try self.collectPatternBindings(param.pattern, fn_scope);
            }

            if (clause.body) |body| {
                try self.collectBlock(body, fn_scope);
            }
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

    fn collectNestedStruct(self: *Collector, sd: *const ast.StructDecl, parent_scope: scope.ScopeId) !void {
        const name = if (sd.name.parts.len > 0) sd.name.parts[0] else 0; // Named structs use their own name; module-scoped use sentinel
        _ = try self.graph.registerType(
            name,
            parent_scope,
            .{ .struct_type = sd },
            &.{},
        );
    }

    fn collectUnion(self: *Collector, ed: *const ast.UnionDecl, parent_scope: scope.ScopeId) !void {
        // For dotted-name unions (e.g., IO.Mode defined in a separate file),
        // register under the short name so the parent struct can reference it
        // unqualified (e.g., Mode.Raw inside the IO struct).
        const registration_name = blk: {
            const full_name = self.interner.get(ed.name);
            if (std.mem.lastIndexOfScalar(u8, full_name, '.')) |dot_pos| {
                const short_name = full_name[dot_pos + 1 ..];
                const interner_mut = @constCast(self.interner);
                break :blk try interner_mut.intern(short_name);
            }
            break :blk ed.name;
        };
        _ = try self.graph.registerType(
            registration_name,
            parent_scope,
            .{ .union_type = ed },
            &.{},
        );
    }

    // ============================================================
    // Extends resolution
    // ============================================================

    fn resolveNestedStructExtends(self: *Collector) !void {
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
            if (sd.name.parts.len == 0) continue;
            const child_name = sd.name.parts[0];
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

    fn resolveStructExtends(self: *Collector, program: *const ast.Program) !void {
        // For each module with a parent, copy parent's public function families
        for (program.structs) |*mod| {
            const parent_name = mod.parent orelse continue;

            // Find parent module by name
            var parent_scope_id: ?scope.ScopeId = null;
            for (self.graph.structs.items) |mod_entry| {
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
            for (self.graph.structs.items) |mod_entry| {
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
                    try self.collectExprScopes(assign.value, parent_scope);
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
            .list_cons => |lc| {
                for (lc.heads) |head| {
                    try self.collectPatternBindings(head, scope_id);
                }
                try self.collectPatternBindings(lc.tail, scope_id);
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
            .binary => |bin| {
                for (bin.segments) |seg| {
                    switch (seg.value) {
                        .pattern => |pat| try self.collectPatternBindings(pat, scope_id),
                        .expr, .string_literal => {},
                    }
                }
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
            .cond_expr => |cond| {
                for (cond.clauses) |clause| {
                    const clause_scope = try self.graph.createScope(parent_scope, .block);
                    try self.collectBlock(clause.body, clause_scope);
                }
            },
            .block => |blk| {
                // Hoist function declarations from block expressions to the parent
                // scope so they're visible to the enclosing function. This enables
                // macros that produce {function_decl, call} blocks at expression level.
                for (blk.stmts) |stmt| {
                    switch (stmt) {
                        .function_decl => |func| try self.collectFunction(func, parent_scope),
                        .macro_decl => |mac| try self.collectMacro(mac, parent_scope),
                        else => {},
                    }
                }
                const blk_scope = try self.graph.createScope(parent_scope, .block);
                // Register block scope in node_scope_map so the TypeChecker's
                // body traversal can enter it for binding type propagation.
                try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(blk.meta.span), blk_scope);
                try self.collectBlock(blk.stmts, blk_scope);
            },
            .anonymous_function => |anon| {
                try self.collectFunction(anon.decl, parent_scope);
            },
            .call => |c| {
                // Recurse into call arguments to find anonymous functions
                for (c.args) |arg| {
                    try self.collectExprScopes(arg, parent_scope);
                }
                try self.collectExprScopes(c.callee, parent_scope);
            },
            .binary_op => |bo| {
                try self.collectExprScopes(bo.lhs, parent_scope);
                try self.collectExprScopes(bo.rhs, parent_scope);
            },
            .unary_op => |uo| {
                try self.collectExprScopes(uo.operand, parent_scope);
            },
            .tuple => |tup| {
                for (tup.elements) |elem| {
                    try self.collectExprScopes(elem, parent_scope);
                }
            },
            .list => |ll| {
                for (ll.elements) |elem| {
                    try self.collectExprScopes(elem, parent_scope);
                }
            },
            .field_access => |fa| {
                try self.collectExprScopes(fa.object, parent_scope);
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

    // Should have: prelude scope + module scope + function scope
    try std.testing.expectEqual(@as(usize, 3), collector.graph.scopes.items.len);
    // Should have 1 function family
    try std.testing.expectEqual(@as(usize, 1), collector.graph.families.items.len);
    // Family should have arity 2
    try std.testing.expectEqual(@as(u32, 2), collector.graph.families.items[0].arity);
    // Should have 2 parameter bindings (x, y)
    try std.testing.expectEqual(@as(usize, 2), collector.graph.bindings.items.len);
}

test "collect module with functions" {
    const source =
        \\pub struct Math {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\
        \\  pub fn sub(x :: i64, y :: i64) -> i64 {
        \\    x - y
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

    // prelude + module + 2 function scopes
    try std.testing.expectEqual(@as(usize, 4), collector.graph.scopes.items.len);
    // 2 function families
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items.len);
    // 1 module
    try std.testing.expectEqual(@as(usize, 1), collector.graph.structs.items.len);
}

test "collect type declaration" {
    const source =
        \\pub struct Types {
        \\  type Result(a, e) = {:ok, a} | {:error, e}
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

    // Should have 1 type registered
    try std.testing.expectEqual(@as(usize, 1), collector.graph.types.items.len);
    try std.testing.expect(collector.graph.types.items[0].kind == .type_alias);
}

test "collect function family grouping" {
    const source =
        \\pub struct Test {
        \\  pub fn factorial(0 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  pub fn factorial(n :: i64) -> i64 {
        \\    n * factorial(n - 1)
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

    // Both clauses should be in one family (same name, same arity)
    try std.testing.expectEqual(@as(usize, 1), collector.graph.families.items.len);
    // Family should have 2 clauses
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items[0].clauses.items.len);
}

test "collect case expression creates scopes" {
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

    // prelude + module + function + 2 case clause scopes
    try std.testing.expectEqual(@as(usize, 5), collector.graph.scopes.items.len);
    // Parameter x + pattern binds v and e
    try std.testing.expectEqual(@as(usize, 3), collector.graph.bindings.items.len);
}

test "collect local def hoisting" {
    const source =
        \\pub struct Test {
        \\  pub fn outer(x :: i64) -> String {
        \\    pub fn inner(s :: String) -> String {
        \\      s
        \\    }
        \\    inner("ok")
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

    // Should have 2 function families (outer and inner)
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items.len);
}

test "collect struct declaration" {
    const source =
        \\pub struct User {
        \\  struct {
        \\    name :: String
        \\    age :: i64
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

    // Should have 1 type registered (struct)
    try std.testing.expectEqual(@as(usize, 1), collector.graph.types.items.len);
    try std.testing.expect(collector.graph.types.items[0].kind == .struct_type);
}

test "collect protocol declaration" {
    const source =
        \\pub protocol Enumerable {
        \\  fn each(collection, callback :: (member -> member)) -> collection
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

    try std.testing.expectEqual(@as(usize, 1), collector.graph.protocols.items.len);
    const proto = collector.graph.protocols.items[0];
    try std.testing.expectEqual(@as(usize, 1), proto.decl.functions.len);
}

test "collect impl declaration" {
    const source =
        \\pub impl Enumerable for List {
        \\  pub fn each(list :: [member], callback :: (member -> member)) -> [member] {
        \\    list
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

    try std.testing.expectEqual(@as(usize, 1), collector.graph.impls.items.len);
    const impl_entry = collector.graph.impls.items[0];
    try std.testing.expectEqual(@as(usize, 1), impl_entry.decl.functions.len);
    try std.testing.expectEqual(false, impl_entry.is_private);
}

test "collect protocol and impl together" {
    const source =
        \\pub protocol Printable {
        \\  fn to_string(value) -> String
        \\}
        \\pub impl Printable for List {
        \\  pub fn to_string(list :: [member]) -> String {
        \\    "list"
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

    try std.testing.expectEqual(@as(usize, 1), collector.graph.protocols.items.len);
    try std.testing.expectEqual(@as(usize, 1), collector.graph.impls.items.len);

    // Verify protocol lookup works
    const proto_name = collector.graph.protocols.items[0].name;
    try std.testing.expect(collector.graph.findProtocol(proto_name) != null);

    // Verify impl lookup works
    const impl_target = collector.graph.impls.items[0].target_type;
    try std.testing.expect(collector.graph.findImpl(proto_name, impl_target) != null);
}

test "duplicate struct declaration produces error" {
    const source =
        \\pub struct Foo {
        \\  pub fn bar() -> String {
        \\    "hello"
        \\  }
        \\}
        \\pub struct Foo {
        \\  pub fn baz() -> String {
        \\    "world"
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
    collector.collectProgram(&program) catch {};

    try std.testing.expect(collector.errors.items.len > 0);
    const err_msg = collector.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "already defined") != null);
}
