const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");

const MAX_COLLECTOR_AST_WALK_NODES: usize = 1_000_000;
const MAX_COLLECTOR_AST_WALK_DEPTH: usize = 1024;

const CollectorAstWalkBudget = struct {
    nodes: usize = 0,
    depth: usize = 0,
    max_nodes: usize = MAX_COLLECTOR_AST_WALK_NODES,
    max_depth: usize = MAX_COLLECTOR_AST_WALK_DEPTH,

    fn enter(self: *CollectorAstWalkBudget) !void {
        if (self.nodes >= self.max_nodes or self.depth >= self.max_depth) {
            return error.CollectorAstWalkBudgetExceeded;
        }
        self.nodes += 1;
        self.depth += 1;
    }

    fn leave(self: *CollectorAstWalkBudget) void {
        std.debug.assert(self.depth != 0);
        self.depth -= 1;
    }
};

// ============================================================
// Declaration collector
//
// Walks the surface AST and:
//   1. Creates scopes for structs, functions, blocks
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
    /// Pre-interned StringId for the auto-import struct's name (see
    /// `discovery.kernel_struct_name`). Stored interned because each
    /// per-struct collect pass tests it against the struct's own name
    /// to avoid injecting a self-import. Optional so unit tests that
    /// don't care about auto-import can pass null.
    kernel_name_id: ?ast.StringId,
    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        interner: *const ast.StringInterner,
        kernel_name_id: ?ast.StringId,
    ) std.mem.Allocator.Error!Collector {
        return .{
            .allocator = allocator,
            .graph = try scope.ScopeGraph.init(allocator),
            .interner = interner,
            .errors = .empty,
            .kernel_name_id = kernel_name_id,
        };
    }

    pub fn deinit(self: *Collector) void {
        self.graph.deinit();
        self.errors.deinit(self.allocator);
    }

    /// Check if a struct has an explicit `import Kernel` or `import Kernel, except: [...]`.
    fn hasExplicitKernelImport(_: *const Collector, mod: *const ast.StructDecl, kernel_id: ast.StringId) bool {
        for (mod.items) |item| {
            switch (item) {
                .import_decl => |id_decl| {
                    if (id_decl.struct_path.parts.len == 1 and id_decl.struct_path.parts[0] == kernel_id)
                        return true;
                },
                .use_decl => |ud| {
                    if (ud.struct_path.parts.len == 1 and ud.struct_path.parts[0] == kernel_id)
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

    fn enterAstWalkBudget(self: *Collector, budget: *CollectorAstWalkBudget, span: ast.SourceSpan) !void {
        budget.enter() catch |err| switch (err) {
            error.CollectorAstWalkBudgetExceeded => {
                try self.addError(
                    "collector AST traversal budget exceeded while walking macro-expanded syntax",
                    span,
                );
                return err;
            },
        };
    }

    /// True for identifiers that begin with a single underscore (`_foo`)
    /// and are therefore reserved for "intentionally unused" bindings —
    /// not legal as function or macro names.  Double-underscore names
    /// (`__using__`, `__before_compile__`, etc.) are the language-hook
    /// namespace and stay legal.
    fn isReservedUnderscoreName(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text[0] != '_') return false;
        if (text.len >= 2 and text[1] == '_') return false;
        return true;
    }

    fn rejectUnderscoreFunctionName(self: *Collector, name: ast.StringId, span: ast.SourceSpan, kind: []const u8) !bool {
        const text = self.interner.get(name);
        if (!isReservedUnderscoreName(text)) return false;
        const message = try std.fmt.allocPrint(
            self.allocator,
            "{s} `{s}` cannot start with `_` — single-underscore names are reserved for intentionally-unused bindings; rename to `{s}` or, if this is a language hook, use `__{s}__`",
            .{ kind, text, text[1..], text[1..] },
        );
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
        return true;
    }

    // ============================================================
    // Top-level collection entry point
    // ============================================================

    pub fn collectProgram(self: *Collector, program: *const ast.Program) !void {
        try self.collectProgramSurface(program);

        // Second pass: resolve struct extends (copy parent fields into children)
        try self.resolveNestedStructExtends();

        // Third pass: resolve struct extends (copy parent function families into children)
        try self.resolveStructExtends(program);

        // Fourth pass: scan struct attributes for `@native_type = "..."`
        // declarations and populate the scope graph's native-type
        // registry. The compiler's runtime-cell dispatch (List, Map,
        // Range, String) reads this registry instead of comparing
        // struct names against hardcoded string literals.
        self.registerNativeTypes();
    }

    pub fn collectProgramSurface(self: *Collector, program: *const ast.Program) !void {
        // Process top-level structs
        for (program.structs) |*mod| {
            try self.collectStruct(mod, self.graph.prelude_scope);
        }

        // Process top-level items (functions, types outside structs)
        // Structs are already processed above via program.structs, skip them here.
        // Top-level attributes are attached to the next definition.
        var pending_top_attrs: std.ArrayList(scope.Attribute) = .empty;
        defer pending_top_attrs.deinit(self.allocator);
        for (program.top_items) |item| {
            switch (item) {
                .attribute => |attr| {
                    try pending_top_attrs.append(self.allocator, .{
                        .name = attr.name,
                        .type_expr = attr.type_expr,
                        .value = attr.value,
                    });
                },
                .struct_decl, .priv_struct_decl => |sd| {
                    // Struct already collected above. Attach pending attributes if any.
                    for (pending_top_attrs.items) |top_attr| {
                        try self.attachTopLevelAttributeToStruct(sd, top_attr);
                    }
                    pending_top_attrs.clearRetainingCapacity();
                },
                .union_decl => |ed| {
                    const type_id = try self.collectUnion(ed, self.graph.prelude_scope);
                    for (pending_top_attrs.items) |top_attr| {
                        try self.graph.types.items[type_id].attributes.append(self.allocator, top_attr);
                    }
                    pending_top_attrs.clearRetainingCapacity();
                },
                .protocol, .priv_protocol => |proto| {
                    try self.collectProtocol(proto);
                    for (pending_top_attrs.items) |top_attr| {
                        try self.attachTopLevelAttributeToProtocol(proto, top_attr);
                    }
                    pending_top_attrs.clearRetainingCapacity();
                },
                .function => |func| {
                    try self.collectFunction(func, self.graph.prelude_scope);
                    pending_top_attrs.clearRetainingCapacity();
                },
                .priv_function => |func| {
                    try self.collectFunction(func, self.graph.prelude_scope);
                    pending_top_attrs.clearRetainingCapacity();
                },
                .macro => |mac| {
                    try self.collectMacro(mac, self.graph.prelude_scope);
                    pending_top_attrs.clearRetainingCapacity();
                },
                .priv_macro => |mac| {
                    try self.collectMacro(mac, self.graph.prelude_scope);
                    pending_top_attrs.clearRetainingCapacity();
                },
                .type_decl => |td| {
                    const type_id = try self.collectType(td, self.graph.prelude_scope);
                    for (pending_top_attrs.items) |top_attr| {
                        try self.graph.types.items[type_id].attributes.append(self.allocator, top_attr);
                    }
                    pending_top_attrs.clearRetainingCapacity();
                },
                .opaque_decl => |od| {
                    const type_id = try self.collectOpaque(od, self.graph.prelude_scope);
                    for (pending_top_attrs.items) |top_attr| {
                        try self.graph.types.items[type_id].attributes.append(self.allocator, top_attr);
                    }
                    pending_top_attrs.clearRetainingCapacity();
                },
                .impl_decl, .priv_impl_decl => |impl_d| {
                    try self.collectImpl(impl_d);
                    pending_top_attrs.clearRetainingCapacity();
                },
                .error_decl, .priv_error_decl => {
                    // `pub error` / `error` declarations are rewritten to
                    // `pub struct + pub impl Error for X` by the
                    // front-end desugar pass (`src/desugar.zig`). The
                    // dedicated `applyErrorDeclDesugar` step in
                    // `src/compiler.zig` runs that rewrite before any
                    // collect pass, so by the time the collector sees a
                    // program every `ErrorDecl` has already been replaced
                    // with a `StructDecl + ImplDecl` pair plus any
                    // surviving `@doc`. Reaching this arm means a unit
                    // skipped the early-desugar — instead of panicking
                    // (which would surface as an unhelpful crash), we
                    // simply ignore the node and let the downstream
                    // desugar-then-final-collect cycle pick it up.
                    pending_top_attrs.clearRetainingCapacity();
                },
            }
        }
    }

    pub fn finalizeCollectedPrograms(self: *Collector, programs: []const ast.Program) !void {
        // Second pass: resolve struct extends (copy parent fields into children)
        try self.resolveNestedStructExtends();

        // Third pass: resolve struct extends (copy parent function families into children)
        for (programs) |program| {
            try self.resolveStructExtends(&program);
        }

        // Fourth pass: see `collectProgram` for rationale.
        self.registerNativeTypes();
    }

    /// Scan all collected struct entries and register any that opt in
    /// to a native type kind via `@native_type = "<kind>"`. The
    /// attribute value must be a string literal whose contents match a
    /// `NativeTypeKind` (`"list"`, `"map"`, `"range"`, `"string"`).
    /// Other values are silently ignored — the user-visible diagnostic
    /// for a misspelled native-type attribute would be that the
    /// corresponding compiler dispatch falls back to a no-op rather
    /// than special-casing the struct, which surfaces as a normal
    /// "no such function" error from the affected call site.
    fn registerNativeTypes(self: *Collector) void {
        const native_type_attr_id = self.interner.lookupExisting("native_type") orelse return;
        for (self.graph.structs.items) |entry| {
            for (entry.attributes.items) |attr| {
                if (attr.name != native_type_attr_id) continue;
                const value = attr.value orelse continue;
                if (value.* != .string_literal) continue;
                const kind_name = self.interner.get(value.string_literal.value);
                const kind = scope.NativeTypeKind.fromName(kind_name) orelse continue;
                if (entry.name.parts.len != 1) continue;
                self.graph.registerNativeType(kind, entry.name.parts[0]);
            }
        }
    }

    fn sameSourceSpan(left: ast.SourceSpan, right: ast.SourceSpan) bool {
        return left.start == right.start and
            left.end == right.end and
            left.source_id == right.source_id;
    }

    fn sameStructName(left: ast.StructName, right: ast.StructName) bool {
        if (left.parts.len != right.parts.len) return false;
        for (left.parts, right.parts) |left_part, right_part| {
            if (left_part != right_part) return false;
        }
        return true;
    }

    fn sameStructDeclIdentity(left: *const ast.StructDecl, right: *const ast.StructDecl) bool {
        return sameStructName(left.name, right.name) and
            sameSourceSpan(left.meta.span, right.meta.span);
    }

    fn sameProtocolDeclIdentity(left: *const ast.ProtocolDecl, right: *const ast.ProtocolDecl) bool {
        return sameStructName(left.name, right.name) and
            sameSourceSpan(left.meta.span, right.meta.span);
    }

    fn attachTopLevelAttributeToStruct(self: *Collector, decl: *const ast.StructDecl, top_attr: scope.Attribute) !void {
        for (self.graph.structs.items) |*mod_entry| {
            if (sameStructDeclIdentity(mod_entry.decl, decl)) {
                try mod_entry.attributes.append(self.allocator, top_attr);
                return;
            }
        }
    }

    fn attachTopLevelAttributeToProtocol(self: *Collector, decl: *const ast.ProtocolDecl, top_attr: scope.Attribute) !void {
        for (self.graph.protocols.items) |*proto_entry| {
            if (sameProtocolDeclIdentity(proto_entry.decl, decl)) {
                try proto_entry.attributes.append(self.allocator, top_attr);
                return;
            }
        }
    }

    // ============================================================
    // Struct collection
    // ============================================================

    fn collectStruct(self: *Collector, mod: *const ast.StructDecl, parent_scope: scope.ScopeId) !void {
        // Check for duplicate struct declarations (only for struct-like structs with items)
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
                        defer name_parts.deinit(self.allocator);
                        for (mod.name.parts, 0..) |part, i| {
                            if (i > 0) try name_parts.appendSlice(self.allocator, ".");
                            try name_parts.appendSlice(self.allocator, self.interner.get(part));
                        }
                        const full_name = name_parts.items;
                        const msg = try std.fmt.allocPrint(self.allocator, "struct '{s}' is already defined", .{full_name});
                        try self.addError(msg, mod.meta.span);
                        return;
                    }
                }
            }
        }

        const mod_scope = try self.graph.createScope(parent_scope, .struct_scope);
        try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(mod.meta.span), mod_scope);
        try self.graph.registerStruct(mod.name, mod_scope, mod);

        // Data structs and truly empty marker structs are nominal types.
        // Function-only structs remain module-like namespaces and are not
        // registered as value types.
        if ((mod.fields.len > 0 or mod.items.len == 0) and mod.name.parts.len > 0) {
            // Build the full qualified name (e.g., "Zap.Env") for type
            // registration. The scratch buffer is freed unconditionally —
            // `intern` copies its input — and any OOM during composition
            // propagates as a hard error so a truncated name never reaches
            // the type-name registry.
            const type_name_id = if (mod.name.parts.len == 1)
                mod.name.parts[0]
            else blk: {
                var name_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer name_buf.deinit(self.allocator);
                for (mod.name.parts, 0..) |part, i| {
                    if (i > 0) try name_buf.appendSlice(self.allocator, ".");
                    try name_buf.appendSlice(self.allocator, self.interner.get(part));
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

        // Auto-import Kernel into every struct (Elixir-style).
        // Skip if: (a) this IS Kernel, or (b) struct has an explicit Kernel import.
        if (self.kernel_name_id) |kid| {
            const is_kernel = mod.name.parts.len == 1 and mod.name.parts[0] == kid;
            if (!is_kernel and !self.hasExplicitKernelImport(mod, kid)) {
                const parts = try self.allocator.alloc(ast.StringId, 1);
                parts[0] = kid;

                var imported_scope = scope.ImportedScope{
                    .source_struct = .{ .parts = parts, .span = mod.meta.span },
                    .owns_source_struct_parts = true,
                    .filter = .all,
                    .imported_families = std.AutoHashMap(scope.FamilyKey, scope.FunctionFamilyId).init(self.allocator),
                    .imported_types = std.AutoHashMap(ast.StringId, scope.TypeId).init(self.allocator),
                    // Implicit Elixir-style auto-import: explicit `use`/`import`
                    // declarations in the struct body shadow it for same-named
                    // macros/symbols (see ImportedScope.is_implicit).
                    .is_implicit = true,
                };
                var imported_scope_transferred = false;
                errdefer if (!imported_scope_transferred) imported_scope.deinit(self.allocator);

                try self.graph.getScopeMut(mod_scope).imports.append(self.allocator, imported_scope);
                imported_scope_transferred = true;
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
                .type_decl => |td| _ = try self.collectType(td, mod_scope),
                .opaque_decl => |od| _ = try self.collectOpaque(od, mod_scope),
                .struct_decl => |sd| try self.collectNestedStruct(sd, mod_scope),
                .union_decl => |ed| _ = try self.collectUnion(ed, mod_scope),
                .alias_decl => |ad| try self.collectAlias(ad, mod_scope),
                .import_decl => |id_decl| try self.collectImport(id_decl, mod_scope),
                .use_decl => |ud| {
                    // `use Struct` expands to `import Struct` — collect the import directly
                    const import_decl = try self.allocator.create(ast.ImportDecl);
                    import_decl.* = .{
                        .meta = ud.meta,
                        .struct_path = ud.struct_path,
                        .filter = null, // import all
                    };
                    try self.collectImport(import_decl, mod_scope);
                },
                .struct_level_expr => |expr| {
                    try self.collectExprScopes(expr, mod_scope);
                },
            }
        }

        // Any remaining pending attributes are struct-level (not attached to a function)
        if (pending_attrs.items.len > 0) {
            // Find the struct entry and attach the attributes
            for (self.graph.structs.items) |*mod_entry| {
                if (mod_entry.scope_id == mod_scope) {
                    for (pending_attrs.items) |attr| {
                        try mod_entry.attributes.append(self.allocator, attr);
                    }
                    break;
                }
            }
        }

        // Broadcast each `@available_on` capability gate across every arity of
        // the gated name (now that the full name→arities family set for this
        // struct is collected), so the gate cannot be bypassed via a different
        // arity. A no-op when no member is gated.
        try self.broadcastAvailableOnAcrossArities(mod_scope);
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
        // Attach pending attributes to the family for each clause's arity as
        // written. A `pub fn` item carries exactly one clause (the parser emits
        // one `FunctionDecl` per `pub fn`), so this normally attaches to a
        // single arity; the cross-arity capability broadcast — gating EVERY
        // arity of a name when ANY clause is `@available_on`-gated, so the gate
        // cannot be bypassed by calling a different arity — is a separate
        // struct-scoped post-pass (`broadcastAvailableOnAcrossArities`) that
        // runs after all of the struct's items are collected and the whole
        // name→arities family set is known. Dedup so an attribute the same
        // arity already carries is not appended twice.
        if (pending_attrs.items.len > 0) {
            const parent = self.graph.getScopeMut(parent_scope);
            var visited_families: std.ArrayListUnmanaged(scope.FunctionFamilyId) = .empty;
            defer visited_families.deinit(self.allocator);

            for (func.clauses) |clause| {
                const arity: u32 = @intCast(clause.params.len);
                const key = scope.FamilyKey{ .name = func.name, .arity = arity };
                if (parent.function_families.get(key)) |fid| {
                    if (functionFamilyIdSeen(visited_families.items, fid)) continue;
                    try visited_families.append(self.allocator, fid);

                    const family = self.graph.getFamilyMut(fid);
                    for (pending_attrs.items) |attr| {
                        try self.appendFunctionFamilyAttribute(family, attr, clause.meta.span);
                    }
                }
            }
        }
    }

    fn functionFamilyIdSeen(ids: []const scope.FunctionFamilyId, target: scope.FunctionFamilyId) bool {
        for (ids) |id| {
            if (id == target) return true;
        }
        return false;
    }

    fn macroFamilyIdSeen(ids: []const scope.MacroFamilyId, target: scope.MacroFamilyId) bool {
        for (ids) |id| {
            if (id == target) return true;
        }
        return false;
    }

    /// True when `family` already carries an attribute named `name` — used to
    /// avoid attaching the same attribute twice (e.g. when a function's clauses
    /// repeat an arity, or when the cross-arity `@available_on` broadcast
    /// reaches a family that already declared the gate itself).
    fn familyHasAttribute(family: *const scope.FunctionFamily, name: ast.StringId, interner: *const ast.StringInterner) bool {
        return attributeListHasName(family.attributes.items, name, interner);
    }

    fn macroFamilyHasAttribute(family: *const scope.MacroFamily, name: ast.StringId, interner: *const ast.StringInterner) bool {
        return attributeListHasName(family.attributes.items, name, interner);
    }

    fn attributeListHasName(attributes: []const scope.Attribute, name: ast.StringId, interner: *const ast.StringInterner) bool {
        const target = interner.get(name);
        for (attributes) |existing| {
            if (std.mem.eql(u8, interner.get(existing.name), target)) return true;
        }
        return false;
    }

    fn isDocAttribute(self: *const Collector, name: ast.StringId) bool {
        return std.mem.eql(u8, self.interner.get(name), "doc");
    }

    fn attributeDiagnosticSpan(attr: scope.Attribute, fallback: ast.SourceSpan) ast.SourceSpan {
        return if (attr.value) |value| value.getMeta().span else fallback;
    }

    fn addDuplicateDocError(
        self: *Collector,
        kind: []const u8,
        name: ast.StringId,
        arity: u32,
        attr: scope.Attribute,
        fallback_span: ast.SourceSpan,
    ) !void {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "duplicate @doc for {s} `{s}/{d}` — document the {s} family once; pattern-matching clauses share that documentation",
            .{ kind, self.interner.get(name), arity, kind },
        );
        try self.addError(msg, attributeDiagnosticSpan(attr, fallback_span));
    }

    fn appendFunctionFamilyAttribute(
        self: *Collector,
        family: *scope.FunctionFamily,
        attr: scope.Attribute,
        fallback_span: ast.SourceSpan,
    ) !void {
        if (!familyHasAttribute(family, attr.name, self.interner)) {
            try family.attributes.append(self.allocator, attr);
            return;
        }
        if (self.isDocAttribute(attr.name)) {
            try self.addDuplicateDocError("function", family.name, family.arity, attr, fallback_span);
        }
    }

    fn appendMacroFamilyAttribute(
        self: *Collector,
        family: *scope.MacroFamily,
        attr: scope.Attribute,
        fallback_span: ast.SourceSpan,
    ) !void {
        if (!macroFamilyHasAttribute(family, attr.name, self.interner)) {
            try family.attributes.append(self.allocator, attr);
            return;
        }
        if (self.isDocAttribute(attr.name)) {
            try self.addDuplicateDocError("macro", family.name, family.arity, attr, fallback_span);
        }
    }

    /// Broadcast every `@available_on` capability gate across ALL arities of
    /// the gated name within `scope_id`. A Zap "multi-clause function" is a set
    /// of separately-declared `pub fn name(...)` items grouped into per-arity
    /// families by name+arity, and `@available_on` is written before just ONE
    /// clause. Gating only that one arity would be unsound: a caller could
    /// reach the feature through a DIFFERENT arity of the same name that the
    /// runtime equally cannot provide on this target. So a gate on any arity of
    /// a name gates every arity of that name in the same struct scope. Copies
    /// the ATTRIBUTE (not a computed marker) so the target-keyed gate pass
    /// (`ctfe.gateAvailableOn`) still recomputes `gated_out` per target.
    ///
    /// Runs once per struct after its item loop, when the full name→arities set
    /// is known. Idempotent: a family that already carries the gate is skipped
    /// (`familyHasAttribute`).
    fn broadcastAvailableOnAcrossArities(self: *Collector, scope_id: scope.ScopeId) !void {
        const parent = self.graph.getScopeMut(scope_id);
        // Collect (name → the `@available_on` attribute to broadcast). The
        // first gate seen for a name wins; a name is not expected to carry
        // conflicting gates on different arities (that would be an author
        // error), and the gate semantics are "all listed caps required" so the
        // first is representative.
        var gated_names: std.ArrayListUnmanaged(struct { name: ast.StringId, attr: scope.Attribute }) = .empty;
        defer gated_names.deinit(self.allocator);
        var it = parent.function_families.iterator();
        while (it.next()) |entry| {
            const fid = entry.value_ptr.*;
            const family = self.graph.getFamily(fid);
            for (family.attributes.items) |attr| {
                if (!std.mem.eql(u8, self.interner.get(attr.name), "available_on")) continue;
                var already = false;
                for (gated_names.items) |g| {
                    if (g.name == entry.key_ptr.name or std.mem.eql(u8, self.interner.get(g.name), self.interner.get(entry.key_ptr.name))) {
                        already = true;
                        break;
                    }
                }
                if (!already) try gated_names.append(self.allocator, .{ .name = entry.key_ptr.name, .attr = attr });
                break;
            }
        }
        // Second pass: copy each gate to every same-name family that lacks it.
        for (gated_names.items) |g| {
            var it2 = parent.function_families.iterator();
            while (it2.next()) |entry| {
                if (entry.key_ptr.name != g.name and !std.mem.eql(u8, self.interner.get(entry.key_ptr.name), self.interner.get(g.name))) continue;
                const family = self.graph.getFamilyMut(entry.value_ptr.*);
                if (familyHasAttribute(family, g.attr.name, self.interner)) continue;
                try family.attributes.append(self.allocator, g.attr);
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
                const parent = self.graph.getScopeMut(parent_scope);
                var visited_families: std.ArrayListUnmanaged(scope.MacroFamilyId) = .empty;
                defer visited_families.deinit(self.allocator);

                for (mac.clauses) |clause| {
                    const arity: u32 = @intCast(clause.params.len);
                    const key = scope.FamilyKey{ .name = mac.name, .arity = arity };
                    const mid = parent.macros.get(key) orelse continue;
                    if (macroFamilyIdSeen(visited_families.items, mid)) continue;
                    try visited_families.append(self.allocator, mid);

                    for (pending_attrs.items) |attr| {
                        try self.appendMacroFamilyAttribute(&self.graph.macro_families.items[mid], attr, clause.meta.span);
                        // `@requires` was historically a hand-written
                        // capability declaration. The compiler now infers
                        // each macro's capability set from its call graph
                        // (see `capability_inference.zig`), so the
                        // annotation is no longer meaningful — emit an
                        // error so authors don't write a no-op.
                        const attr_name = self.interner.get(attr.name);
                        if (std.mem.eql(u8, attr_name, "requires")) {
                            const span = if (attr.value) |v| v.getMeta().span else ast.SourceSpan{ .start = 0, .end = 0 };
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "`@requires` is no longer supported — compile-time capabilities are inferred from the macro body's call graph",
                                .{},
                            );
                            try self.errors.append(self.allocator, .{ .message = msg, .span = span });
                        }
                    }
                }
            }
        }
    }

    fn collectProtocol(self: *Collector, proto: *const ast.ProtocolDecl) !void {
        const proto_scope = try self.graph.createScope(self.graph.prelude_scope, .struct_scope);
        try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(proto.meta.span), proto_scope);
        try self.graph.protocols.append(self.allocator, .{
            .name = proto.name,
            .scope_id = proto_scope,
            .decl = proto,
        });
    }

    fn collectImpl(self: *Collector, impl_d: *const ast.ImplDecl) !void {
        const impl_scope = try self.graph.createScope(self.graph.prelude_scope, .struct_scope);
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

    /// Validate that all impl declarations conform to their protocol.
    /// Must be called after all structs have been collected so that
    /// protocols are available for lookup regardless of file order.
    pub fn validateImplConformance(self: *Collector) !void {
        for (self.graph.impls.items) |impl_entry| {
            const impl_d = impl_entry.decl;
            const proto_entry = self.graph.findProtocol(impl_d.protocol_name) orelse {
                const proto_name = try self.formatStructName(impl_d.protocol_name);
                defer self.allocator.free(proto_name);
                const msg = try std.fmt.allocPrint(self.allocator, "protocol '{s}' is not defined", .{proto_name});
                try self.addError(msg, impl_d.meta.span);
                continue;
            };

            // Check each required protocol function is provided by the impl
            for (proto_entry.decl.functions) |sig| {
                var found = false;
                for (impl_d.functions) |func| {
                    if (func.name != sig.name) continue;
                    found = true;
                    // Check arity matches
                    if (func.clauses.len > 0) {
                        const impl_arity = func.clauses[0].params.len;
                        if (impl_arity != sig.params.len) {
                            const fn_name = self.interner.get(sig.name);
                            const target_name = try self.formatStructName(impl_d.target_type);
                            defer self.allocator.free(target_name);
                            const proto_name = try self.formatStructName(impl_d.protocol_name);
                            defer self.allocator.free(proto_name);
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "impl {s} for {s}: function '{s}' has arity {d}, protocol requires {d}",
                                .{ proto_name, target_name, fn_name, impl_arity, sig.params.len },
                            );
                            try self.addError(msg, func.meta.span);
                        }
                    }
                    break;
                }
                if (!found) {
                    const fn_name = self.interner.get(sig.name);
                    const target_name = try self.formatStructName(impl_d.target_type);
                    defer self.allocator.free(target_name);
                    const proto_name = try self.formatStructName(impl_d.protocol_name);
                    defer self.allocator.free(proto_name);
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "impl {s} for {s} is missing required function '{s}/{d}'",
                        .{ proto_name, target_name, fn_name, sig.params.len },
                    );
                    try self.addError(msg, impl_d.meta.span);
                }
            }
        }
    }

    /// Rebind already-collected struct function families to the current AST
    /// nodes. Incremental staged expansion reuses the surface graph from the
    /// raw AST, then substitutes cached expanded/desugared AST per struct; the
    /// graph must therefore be refreshed before type checking or HIR reads it.
    pub fn refreshStructFunctionDeclarations(self: *Collector, program: *const ast.Program) !void {
        for (program.structs) |*mod| {
            const mod_scope = self.graph.findStructScope(mod.name) orelse continue;

            var refreshed_keys = std.AutoHashMap(scope.FamilyKey, void).init(self.allocator);
            defer refreshed_keys.deinit();

            for (mod.items) |item| {
                const func = switch (item) {
                    .function, .priv_function => |decl| decl,
                    else => continue,
                };
                const arity: u32 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
                const key = scope.FamilyKey{ .name = func.name, .arity = arity };
                const refreshed = try refreshed_keys.getOrPut(key);
                if (refreshed.found_existing) continue;
                if (self.graph.getScope(mod_scope).function_families.get(key)) |family_id| {
                    self.graph.getFamilyMut(family_id).clauses.clearRetainingCapacity();
                }
            }

            for (mod.items) |item| {
                const func = switch (item) {
                    .function, .priv_function => |decl| decl,
                    else => continue,
                };
                try self.collectFunction(func, mod_scope);
            }
        }
    }

    pub fn refreshImplDeclaration(self: *Collector, impl_entry: *scope.ImplEntry, impl_d: *const ast.ImplDecl) !void {
        var old_family_ids: std.ArrayListUnmanaged(scope.FunctionFamilyId) = .empty;
        defer old_family_ids.deinit(self.allocator);

        {
            const impl_scope = self.graph.getScope(impl_entry.scope_id);
            var family_iter = impl_scope.function_families.iterator();
            while (family_iter.next()) |entry| {
                try old_family_ids.append(self.allocator, entry.value_ptr.*);
            }
        }

        if (self.graph.findStructScope(impl_entry.target_type)) |target_scope_id| {
            var stale_target_keys: std.ArrayListUnmanaged(scope.FamilyKey) = .empty;
            defer stale_target_keys.deinit(self.allocator);

            const target_scope = self.graph.getScope(target_scope_id);
            var target_iter = target_scope.function_families.iterator();
            while (target_iter.next()) |entry| {
                if (functionFamilyIdInSlice(old_family_ids.items, entry.value_ptr.*)) {
                    try stale_target_keys.append(self.allocator, entry.key_ptr.*);
                }
            }

            const target_scope_mut = self.graph.getScopeMut(target_scope_id);
            for (stale_target_keys.items) |key| {
                _ = target_scope_mut.function_families.remove(key);
            }
        }

        for (old_family_ids.items) |family_id| {
            self.graph.getFamilyMut(family_id).clauses.clearRetainingCapacity();
        }
        self.graph.getScopeMut(impl_entry.scope_id).function_families.clearRetainingCapacity();

        impl_entry.protocol_name = impl_d.protocol_name;
        impl_entry.target_type = impl_d.target_type;
        impl_entry.decl = impl_d;
        impl_entry.is_private = impl_d.is_private;
        for (impl_d.functions) |func| {
            try self.collectFunction(func, impl_entry.scope_id);
        }
    }

    fn functionFamilyIdInSlice(ids: []const scope.FunctionFamilyId, needle: scope.FunctionFamilyId) bool {
        for (ids) |id| {
            if (id == needle) return true;
        }
        return false;
    }

    /// Register impl functions in their target struct's scope so that
    /// calls like Range.next(state) resolve to the impl function.
    /// Must be called after all structs and impls are collected.
    ///
    /// We re-use the FunctionFamilyId already created by `collectImpl` (which
    /// lives in the impl's own scope) and insert it into the target struct's
    /// `function_families` map. Calling `collectFunction` a second time would
    /// create a *parallel* family with new function scopes, clobbering each
    /// clause's `meta.scope_id` to point at the target-scope family — and
    /// silently breaking the impl-scope family in the process.
    pub fn registerImplFunctionsInTargetScopes(self: *Collector) !void {
        for (self.graph.impls.items) |impl_entry| {
            const target_scope = self.graph.findStructScope(impl_entry.target_type) orelse continue;
            const impl_scope_data = self.graph.getScope(impl_entry.scope_id);
            const target_scope_data = self.graph.getScopeMut(target_scope);
            for (impl_entry.decl.functions) |func| {
                const arity: u32 = if (func.clauses.len > 0) @intCast(func.clauses[0].params.len) else 0;
                const key = scope.FamilyKey{ .name = func.name, .arity = arity };
                const family_id = impl_scope_data.function_families.get(key) orelse continue;
                if (target_scope_data.function_families.contains(key)) continue;
                try target_scope_data.function_families.put(key, family_id);
            }
        }
    }

    fn formatStructName(self: *const Collector, name: ast.StructName) ![]const u8 {
        return try name.toDottedString(self.allocator, self.interner);
    }

    pub fn collectFunction(self: *Collector, func: *const ast.FunctionDecl, parent_scope: scope.ScopeId) !void {
        var budget = CollectorAstWalkBudget{};
        try self.collectFunctionBudgeted(func, parent_scope, &budget);
    }

    fn collectFunctionBudgeted(
        self: *Collector,
        func: *const ast.FunctionDecl,
        parent_scope: scope.ScopeId,
        budget: *CollectorAstWalkBudget,
    ) !void {
        const diagnostic_span = if (func.clauses.len > 0)
            func.clauses[0].meta.span
        else
            ast.SourceSpan{ .start = 0, .end = 0 };
        try self.enterAstWalkBudget(budget, diagnostic_span);
        defer budget.leave();

        // Reject `pub fn _name` / `fn _name` at definition time. Single
        // underscore names are reserved for intentionally-unused bindings
        // (parameters, locals); they aren't legal function names.
        if (func.clauses.len > 0) {
            if (try self.rejectUnderscoreFunctionName(func.name, func.clauses[0].meta.span, "function")) return;
        }
        // Iterate by pointer so the `clause.meta.scope_id` write below
        // mutates the actual slice element. With `|clause, idx|` the loop
        // variable is a stack copy, and the mutation is silently discarded
        // — leaving macro-generated test functions with `scope_id = 0`
        // when their synthetic spans collide in `node_scope_map`.
        for (func.clauses, 0..) |*clause, clause_idx| {
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
            // Without this, the default meta.scope_id = 0 (prelude) makes struct-level
            // functions invisible during type inference in macro-generated code.
            @constCast(&clause.meta).scope_id = fn_scope;

            // Collect parameter bindings
            for (clause.params) |param| {
                try self.collectPatternBindingsBudgeted(param.pattern, fn_scope, budget);
            }

            // Collect body statements (hoisting local defs).
            // Bodyless declarations (protocol sigs, forward decls) have no body to collect.
            if (clause.body) |body| {
                try self.collectBlockBudgeted(body, fn_scope, budget);
            }
        }
    }

    // ============================================================
    // Macro collection
    // ============================================================

    fn collectMacro(self: *Collector, mac: *const ast.FunctionDecl, parent_scope: scope.ScopeId) !void {
        var budget = CollectorAstWalkBudget{};
        try self.collectMacroBudgeted(mac, parent_scope, &budget);
    }

    fn collectMacroBudgeted(
        self: *Collector,
        mac: *const ast.FunctionDecl,
        parent_scope: scope.ScopeId,
        budget: *CollectorAstWalkBudget,
    ) !void {
        const diagnostic_span = if (mac.clauses.len > 0)
            mac.clauses[0].meta.span
        else
            ast.SourceSpan{ .start = 0, .end = 0 };
        try self.enterAstWalkBudget(budget, diagnostic_span);
        defer budget.leave();

        // Same definition-time rule as `collectFunction`: single-`_`
        // macro names are reserved. Double-underscore stays legal so
        // language-hook macros (`__using__`, `__before_compile__`) can
        // continue to be defined.
        if (mac.clauses.len > 0) {
            if (try self.rejectUnderscoreFunctionName(mac.name, mac.clauses[0].meta.span, "macro")) return;
        }
        for (mac.clauses, 0..) |*clause, clause_idx| {
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
            @constCast(&clause.meta).scope_id = fn_scope;

            for (clause.params) |param| {
                try self.collectPatternBindingsBudgeted(param.pattern, fn_scope, budget);
            }

            if (clause.body) |body| {
                try self.collectBlockBudgeted(body, fn_scope, budget);
            }
        }
    }

    // ============================================================
    // Type/opaque/struct collection
    // ============================================================

    fn collectType(self: *Collector, td: *const ast.TypeDecl, parent_scope: scope.ScopeId) !scope.TypeId {
        return try self.graph.registerType(td.name, parent_scope, .{ .type_alias = td.body }, td.params);
    }

    fn collectOpaque(self: *Collector, od: *const ast.OpaqueDecl, parent_scope: scope.ScopeId) !scope.TypeId {
        return try self.graph.registerType(od.name, parent_scope, .{ .opaque_type = od.body }, od.params);
    }

    fn collectNestedStruct(self: *Collector, sd: *const ast.StructDecl, parent_scope: scope.ScopeId) !void {
        const name = if (sd.name.parts.len > 0) sd.name.parts[0] else 0; // Named structs use their own name; struct-scoped use sentinel
        _ = try self.graph.registerType(
            name,
            parent_scope,
            .{ .struct_type = sd },
            &.{},
        );
    }

    fn collectUnion(self: *Collector, ed: *const ast.UnionDecl, parent_scope: scope.ScopeId) !scope.TypeId {
        return try self.graph.registerType(
            ed.name,
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
            var visited_parents = std.AutoHashMap(ast.StringId, void).init(self.allocator);
            defer visited_parents.deinit();
            var current_parent: ?ast.StringId = parent_name;
            while (current_parent) |cp| {
                if (cp == child_name or visited_parents.contains(cp)) {
                    try self.addError(
                        "circular struct inheritance detected",
                        sd.meta.span,
                    );
                    break;
                }
                try visited_parents.put(cp, {});
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
        // For each struct with a parent, copy parent's public function families
        for (program.structs) |*mod| {
            const parent_name = mod.parent orelse continue;

            // Find parent struct by name
            var parent_scope_id: ?scope.ScopeId = null;
            for (self.graph.structs.items) |mod_entry| {
                if (mod_entry.name.parts.len == 1 and mod_entry.name.parts[0] == parent_name) {
                    parent_scope_id = mod_entry.scope_id;
                    break;
                }
            }

            if (parent_scope_id == null) {
                try self.addError(
                    "unknown parent struct in extends",
                    mod.meta.span,
                );
                continue;
            }

            // Find child struct scope
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
            defer family_keys.deinit(self.allocator);
            var family_ids: std.ArrayList(scope.FunctionFamilyId) = .empty;
            defer family_ids.deinit(self.allocator);
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
                defer clause_refs.deinit(self.allocator);
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
            ad.struct_path.parts[ad.struct_path.parts.len - 1];

        const full_name = ad.struct_path.parts[ad.struct_path.parts.len - 1];

        try self.graph.getScopeMut(parent_scope).aliases.put(short_name, full_name);
    }

    fn collectImport(self: *Collector, id_decl: *const ast.ImportDecl, parent_scope: scope.ScopeId) !void {
        var imported_scope = scope.ImportedScope{
            .source_struct = id_decl.struct_path,
            .filter = try self.collectImportFilter(id_decl.filter),
            .imported_families = std.AutoHashMap(scope.FamilyKey, scope.FunctionFamilyId).init(self.allocator),
            .imported_types = std.AutoHashMap(ast.StringId, scope.TypeId).init(self.allocator),
        };
        var imported_scope_transferred = false;
        errdefer if (!imported_scope_transferred) imported_scope.deinit(self.allocator);

        try self.graph.getScopeMut(parent_scope).imports.append(self.allocator, imported_scope);
        imported_scope_transferred = true;
    }

    fn collectImportFilter(self: *Collector, filter: ?ast.ImportFilter) !scope.ImportFilter {
        const import_filter = filter orelse return .all;
        return switch (import_filter) {
            .only => |entries| .{ .only = try self.collectImportEntries(entries) },
            .except => |entries| .{ .except = try self.collectImportEntries(entries) },
        };
    }

    fn collectImportEntries(self: *Collector, entries: []const ast.ImportEntry) ![]const scope.ImportEntry {
        var import_entries: std.ArrayList(scope.ImportEntry) = .empty;
        errdefer import_entries.deinit(self.allocator);

        for (entries) |entry| {
            switch (entry) {
                .function => |function| try import_entries.append(self.allocator, .{
                    .name = function.name,
                    .arity = function.arity,
                }),
                .type_import => |name| try import_entries.append(self.allocator, .{
                    .name = name,
                    .arity = null,
                }),
            }
        }
        return try import_entries.toOwnedSlice(self.allocator);
    }

    // ============================================================
    // Block collection — handles local def hoisting
    // ============================================================

    fn stmtDiagnosticSpan(stmt: ast.Stmt) ast.SourceSpan {
        return switch (stmt) {
            .expr => |expr| expr.getMeta().span,
            .assignment => |assignment| assignment.meta.span,
            .function_decl, .macro_decl => |function| if (function.clauses.len > 0)
                function.clauses[0].meta.span
            else
                ast.SourceSpan{ .start = 0, .end = 0 },
            .import_decl => |import_decl| import_decl.meta.span,
            .attribute => |attribute| attribute.meta.span,
        };
    }

    fn blockDiagnosticSpan(stmts: []const ast.Stmt) ast.SourceSpan {
        if (stmts.len == 0) return .{ .start = 0, .end = 0 };
        return stmtDiagnosticSpan(stmts[0]);
    }

    fn collectBlock(self: *Collector, stmts: []const ast.Stmt, parent_scope: scope.ScopeId) anyerror!void {
        var budget = CollectorAstWalkBudget{};
        try self.collectBlockBudgeted(stmts, parent_scope, &budget);
    }

    fn collectBlockBudgeted(
        self: *Collector,
        stmts: []const ast.Stmt,
        parent_scope: scope.ScopeId,
        budget: *CollectorAstWalkBudget,
    ) anyerror!void {
        try self.enterAstWalkBudget(budget, blockDiagnosticSpan(stmts));
        defer budget.leave();

        // First pass: hoist local function declarations
        for (stmts) |stmt| {
            switch (stmt) {
                .function_decl => |func| try self.collectFunctionBudgeted(func, parent_scope, budget),
                .macro_decl => |mac| try self.collectMacroBudgeted(mac, parent_scope, budget),
                else => {},
            }
        }

        // Second pass: collect bindings from assignments and expressions
        for (stmts) |stmt| {
            switch (stmt) {
                .assignment => |assign| {
                    try self.collectPatternBindingsBudgeted(assign.pattern, parent_scope, budget);
                    try self.collectExprScopesBudgeted(assign.value, parent_scope, budget);
                },
                .expr => |expr| {
                    try self.collectExprScopesBudgeted(expr, parent_scope, budget);
                },
                .import_decl => |id_decl| {
                    try self.collectImport(id_decl, parent_scope);
                },
                .attribute => |attr| {
                    if (attr.value) |value| try self.collectExprScopesBudgeted(value, parent_scope, budget);
                },
                .function_decl, .macro_decl => {},
            }
        }
    }

    // ============================================================
    // Pattern binding collection
    // ============================================================

    fn collectPatternBindings(self: *Collector, pattern: *const ast.Pattern, scope_id: scope.ScopeId) !void {
        var budget = CollectorAstWalkBudget{};
        try self.collectPatternBindingsBudgeted(pattern, scope_id, &budget);
    }

    fn collectPatternBindingsBudgeted(
        self: *Collector,
        pattern: *const ast.Pattern,
        scope_id: scope.ScopeId,
        budget: *CollectorAstWalkBudget,
    ) !void {
        try self.enterAstWalkBudget(budget, pattern.getMeta().span);
        defer budget.leave();

        switch (pattern.*) {
            .bind => |bind| {
                // Copy the binder's hygiene scope set into the Binding row
                // so `resolveBindingByScopes` can pick this binding when a
                // reference's scope set is a superset (Flatt 2016 largest-
                // subset rule). For pre-hygiene code paths the set is
                // empty, which makes the binding visible to any reference
                // (the empty set is a subset of every set) — preserves the
                // lexical-chain fallback semantics.
                _ = try self.graph.createBindingWithScopes(
                    bind.name,
                    scope_id,
                    .pattern_bind,
                    bind.meta.span,
                    bind.meta.scopes,
                );
            },
            .tuple => |tup| {
                for (tup.elements) |elem| {
                    try self.collectPatternBindingsBudgeted(elem, scope_id, budget);
                }
            },
            .list => |lst| {
                for (lst.elements) |elem| {
                    try self.collectPatternBindingsBudgeted(elem, scope_id, budget);
                }
            },
            .list_cons => |lc| {
                for (lc.heads) |head| {
                    try self.collectPatternBindingsBudgeted(head, scope_id, budget);
                }
                try self.collectPatternBindingsBudgeted(lc.tail, scope_id, budget);
            },
            .map => |m| {
                for (m.fields) |field| {
                    try self.collectPatternBindingsBudgeted(field.value, scope_id, budget);
                }
            },
            .struct_pattern => |sp| {
                for (sp.fields) |field| {
                    try self.collectPatternBindingsBudgeted(field.pattern, scope_id, budget);
                }
            },
            .paren => |p| {
                try self.collectPatternBindingsBudgeted(p.inner, scope_id, budget);
            },
            .binary => |bin| {
                for (bin.segments) |seg| {
                    switch (seg.value) {
                        .pattern => |pat| try self.collectPatternBindingsBudgeted(pat, scope_id, budget),
                        .expr, .string_literal => {},
                    }
                }
            },
            .tagged_union_variant => |tuv| {
                // Variant payloads can carry arbitrary nested patterns —
                // a `bind` introduces the payload local, a `tuple` or
                // `struct_pattern` walks deeper. Nullary variants
                // (`Option.None`) carry no payload and introduce no
                // bindings. The qualifier and type-args carry no
                // pattern-bound names.
                if (tuv.payload) |payload| {
                    try self.collectPatternBindingsBudgeted(payload, scope_id, budget);
                }
            },
            .wildcard, .literal, .pin => {},
        }
    }

    // ============================================================
    // Expression scope collection
    // ============================================================

    fn collectExprScopes(self: *Collector, expr: *const ast.Expr, parent_scope: scope.ScopeId) anyerror!void {
        var budget = CollectorAstWalkBudget{};
        try self.collectExprScopesBudgeted(expr, parent_scope, &budget);
    }

    fn collectExprScopesBudgeted(
        self: *Collector,
        expr: *const ast.Expr,
        parent_scope: scope.ScopeId,
        budget: *CollectorAstWalkBudget,
    ) anyerror!void {
        try self.enterAstWalkBudget(budget, expr.getMeta().span);
        defer budget.leave();

        switch (expr.*) {
            .if_expr => |ie| {
                const then_scope = try self.graph.createScope(parent_scope, .block);
                try self.collectBlockBudgeted(ie.then_block, then_scope, budget);
                if (ie.else_block) |else_block| {
                    const else_scope = try self.graph.createScope(parent_scope, .block);
                    try self.collectBlockBudgeted(else_block, else_scope, budget);
                }
            },
            .case_expr => |ce| {
                try self.collectExprScopesBudgeted(ce.scrutinee, parent_scope, budget);
                // Iterate by pointer: `for |clause|` copies each element so
                // any mutation through `&clause.meta` would land on the
                // local copy and never reach the AST stored in the slice.
                // Desugar-generated case clauses share the synthetic span
                // 0:0, which collides in `node_scope_map`, so the only way
                // the type checker can later resolve each clause to its
                // unique scope is through this in-place `meta.scope_id`
                // write.
                for (ce.clauses) |*clause| {
                    const clause_scope = try self.graph.createScope(parent_scope, .case_clause);
                    try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(clause.meta.span), clause_scope);
                    @constCast(&clause.meta).scope_id = clause_scope;
                    try self.collectPatternBindingsBudgeted(clause.pattern, clause_scope, budget);
                    try self.collectBlockBudgeted(clause.body, clause_scope, budget);
                }
            },
            .cond_expr => |cond| {
                for (cond.clauses) |clause| {
                    const clause_scope = try self.graph.createScope(parent_scope, .block);
                    try self.collectBlockBudgeted(clause.body, clause_scope, budget);
                }
            },
            .try_rescue => |tr| {
                // The `try` body is its own block scope. Each `rescue` arm is a
                // case-clause scope carrying its pattern bindings (`e` in
                // `e :: IOError -> …`) — mirrors `.case_expr` so the binding +
                // scope discovery the type checker and HIR rely on is in place.
                // `after` is a block scope.
                const body_scope = try self.graph.createScope(parent_scope, .block);
                try self.collectBlockBudgeted(tr.body, body_scope, budget);
                for (tr.rescue_clauses) |*clause| {
                    const clause_scope = try self.graph.createScope(parent_scope, .case_clause);
                    try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(clause.meta.span), clause_scope);
                    @constCast(&clause.meta).scope_id = clause_scope;
                    try self.collectPatternBindingsBudgeted(clause.pattern, clause_scope, budget);
                    try self.collectBlockBudgeted(clause.body, clause_scope, budget);
                }
                if (tr.after_block) |cleanup| {
                    const after_scope = try self.graph.createScope(parent_scope, .block);
                    try self.collectBlockBudgeted(cleanup, after_scope, budget);
                }
            },
            .block => |blk| {
                // Hoist function declarations from block expressions to the parent
                // scope so they're visible to the enclosing function. This enables
                // macros that produce {function_decl, call} blocks at expression level.
                for (blk.stmts) |stmt| {
                    switch (stmt) {
                        .function_decl => |func| try self.collectFunctionBudgeted(func, parent_scope, budget),
                        .macro_decl => |mac| try self.collectMacroBudgeted(mac, parent_scope, budget),
                        else => {},
                    }
                }
                const blk_scope = try self.graph.createScope(parent_scope, .block);
                // Register block scope in node_scope_map so the TypeChecker's
                // body traversal can enter it for binding type propagation.
                try self.graph.node_scope_map.put(scope.ScopeGraph.spanKey(blk.meta.span), blk_scope);
                const expr_mut: *ast.Expr = @constCast(expr);
                expr_mut.block.meta.scope_id = blk_scope;
                try self.collectBlockBudgeted(blk.stmts, blk_scope, budget);
            },
            .anonymous_function => |anon| {
                try self.collectFunctionBudgeted(anon.decl, parent_scope, budget);
            },
            .call => |c| {
                // Recurse into call arguments to find anonymous functions
                for (c.args) |arg| {
                    try self.collectExprScopesBudgeted(arg, parent_scope, budget);
                }
                try self.collectExprScopesBudgeted(c.callee, parent_scope, budget);
            },
            .binary_op => |bo| {
                try self.collectExprScopesBudgeted(bo.lhs, parent_scope, budget);
                try self.collectExprScopesBudgeted(bo.rhs, parent_scope, budget);
            },
            .unary_op => |uo| {
                try self.collectExprScopesBudgeted(uo.operand, parent_scope, budget);
            },
            .tuple => |tup| {
                for (tup.elements) |elem| {
                    try self.collectExprScopesBudgeted(elem, parent_scope, budget);
                }
            },
            .list => |ll| {
                for (ll.elements) |elem| {
                    try self.collectExprScopesBudgeted(elem, parent_scope, budget);
                }
            },
            .field_access => |fa| {
                try self.collectExprScopesBudgeted(fa.object, parent_scope, budget);
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

fn makeCollectorTestMeta() ast.NodeMeta {
    return .{ .span = .{ .start = 0, .end = 1 } };
}

fn makeCollectorDeepParenPattern(
    allocator: std.mem.Allocator,
    interner: *ast.StringInterner,
    depth: usize,
) !*const ast.Pattern {
    const name = try interner.intern("value");
    const meta = makeCollectorTestMeta();
    var current = try allocator.create(ast.Pattern);
    current.* = .{ .bind = .{ .meta = meta, .name = name } };
    for (0..depth) |_| {
        const wrapper = try allocator.create(ast.Pattern);
        wrapper.* = .{ .paren = .{ .meta = meta, .inner = current } };
        current = wrapper;
    }
    return current;
}

fn makeCollectorDeepUnaryExpr(allocator: std.mem.Allocator, depth: usize) !*const ast.Expr {
    const meta = makeCollectorTestMeta();
    var current = try allocator.create(ast.Expr);
    current.* = .{ .int_literal = .{ .meta = meta, .value = 1 } };
    for (0..depth) |_| {
        const wrapper = try allocator.create(ast.Expr);
        wrapper.* = .{ .unary_op = .{ .meta = meta, .op = .not_op, .operand = current } };
        current = wrapper;
    }
    return current;
}

const CollectorImportFilterMode = enum {
    only,
    except,
};

fn collectFilteredImportAllocationFailureImpl(
    allocator: std.mem.Allocator,
    filter_mode: CollectorImportFilterMode,
) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    var collector = try Collector.init(allocator, &interner, null);
    defer collector.deinit();

    const source_parts = [_]ast.StringId{10};
    const filter_entries = [_]ast.ImportEntry{
        .{ .function = .{ .name = 20, .arity = 1 } },
        .{ .type_import = 30 },
    };
    const import_filter: ast.ImportFilter = switch (filter_mode) {
        .only => .{ .only = &filter_entries },
        .except => .{ .except = &filter_entries },
    };
    const import_decl = ast.ImportDecl{
        .meta = makeCollectorTestMeta(),
        .struct_path = .{
            .parts = &source_parts,
            .span = .{ .start = 0, .end = 6 },
        },
        .filter = import_filter,
    };

    try collector.collectImport(&import_decl, collector.graph.prelude_scope);

    const imports = collector.graph.getScope(collector.graph.prelude_scope).imports.items;
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expectEqualSlices(ast.StringId, &source_parts, imports[0].source_struct.parts);

    const entries = switch (filter_mode) {
        .only => switch (imports[0].filter) {
            .only => |entries| entries,
            else => return error.ExpectedOnlyImportFilter,
        },
        .except => switch (imports[0].filter) {
            .except => |entries| entries,
            else => return error.ExpectedExceptImportFilter,
        },
    };
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(ast.StringId, 20), entries[0].name);
    try std.testing.expectEqual(@as(?u32, 1), entries[0].arity);
    try std.testing.expectEqual(@as(ast.StringId, 30), entries[1].name);
    try std.testing.expectEqual(@as(?u32, null), entries[1].arity);
}

fn collectImplicitKernelImportAllocationFailureImpl(allocator: std.mem.Allocator) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const kernel_name = try interner.intern("Kernel");
    const user_name = try interner.intern("User");
    const kernel_parts = [_]ast.StringId{kernel_name};
    const user_parts = [_]ast.StringId{user_name};
    const test_meta = makeCollectorTestMeta();

    var structs = [_]ast.StructDecl{
        .{
            .meta = test_meta,
            .name = .{ .parts = &kernel_parts, .span = test_meta.span },
        },
        .{
            .meta = test_meta,
            .name = .{ .parts = &user_parts, .span = test_meta.span },
        },
    };
    const program = ast.Program{
        .structs = &structs,
        .top_items = &.{},
    };

    var collector = try Collector.init(allocator, &interner, kernel_name);
    defer collector.deinit();

    try collector.collectProgram(&program);

    const user_scope_id = collector.graph.findStructScope(structs[1].name) orelse return error.ExpectedUserStructScope;
    const imports = collector.graph.getScope(user_scope_id).imports.items;
    try std.testing.expectEqual(@as(usize, 1), imports.len);
    try std.testing.expect(imports[0].is_implicit);
    try std.testing.expect(imports[0].owns_source_struct_parts);
    try std.testing.expectEqual(@as(usize, 1), imports[0].source_struct.parts.len);
    try std.testing.expectEqual(kernel_name, imports[0].source_struct.parts[0]);
}

fn collectStructExtendsAllocationFailureImpl(allocator: std.mem.Allocator) !void {
    var interner = ast.StringInterner.init(allocator);
    defer interner.deinit();

    const parent_name = try interner.intern("Parent");
    const child_name = try interner.intern("Child");
    const inherited_name = try interner.intern("inherited");

    const parent_parts = [_]ast.StringId{parent_name};
    const child_parts = [_]ast.StringId{child_name};
    var inherited_clauses = [_]ast.FunctionClause{
        .{
            .meta = .{ .span = .{ .start = 10, .end = 20 } },
            .params = &.{},
            .return_type = null,
            .refinement = null,
            .body = null,
        },
    };
    var inherited_function = ast.FunctionDecl{
        .meta = .{ .span = .{ .start = 10, .end = 20 } },
        .name = inherited_name,
        .clauses = &inherited_clauses,
        .visibility = .public,
    };
    const parent_items = [_]ast.StructItem{
        .{ .function = &inherited_function },
    };
    var structs = [_]ast.StructDecl{
        .{
            .meta = .{ .span = .{ .start = 0, .end = 30 } },
            .name = .{ .parts = &parent_parts, .span = .{ .start = 0, .end = 6 } },
            .items = &parent_items,
        },
        .{
            .meta = .{ .span = .{ .start = 31, .end = 60 } },
            .name = .{ .parts = &child_parts, .span = .{ .start = 31, .end = 36 } },
            .parent = parent_name,
        },
    };
    const program = ast.Program{
        .structs = &structs,
        .top_items = &.{},
    };

    var collector = try Collector.init(allocator, &interner, null);
    defer collector.deinit();

    try collector.collectProgram(&program);

    const parent_scope_id = collector.graph.findStructScope(structs[0].name) orelse return error.ExpectedParentStructScope;
    const child_scope_id = collector.graph.findStructScope(structs[1].name) orelse return error.ExpectedChildStructScope;
    const family_key = scope.FamilyKey{ .name = inherited_name, .arity = 0 };
    const parent_family_id = collector.graph.getScope(parent_scope_id).function_families.get(family_key) orelse return error.ExpectedParentFamily;
    const child_family_id = collector.graph.getScope(child_scope_id).function_families.get(family_key) orelse return error.ExpectedInheritedFamily;

    try std.testing.expect(parent_family_id != child_family_id);
    const child_family = collector.graph.getFamily(child_family_id);
    try std.testing.expectEqual(ast.FunctionDecl.Visibility.public, child_family.visibility);
    try std.testing.expectEqual(@as(usize, 1), child_family.clauses.items.len);
    try std.testing.expectEqual(&inherited_function, child_family.clauses.items[0].decl);
    try std.testing.expectEqual(@as(u32, 0), child_family.clauses.items[0].clause_index);
}

test "Collector.init propagates ScopeGraph prelude allocation OutOfMemory" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        Collector.init(failing_allocator.allocator(), &interner, null),
    );
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "collectImport cleans owned filters when any allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectFilteredImportAllocationFailureImpl,
        .{CollectorImportFilterMode.only},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectFilteredImportAllocationFailureImpl,
        .{CollectorImportFilterMode.except},
    );
}

test "collectProgram cleans synthesized Kernel import when any allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectImplicitKernelImportAllocationFailureImpl,
        .{},
    );
}

test "resolveStructExtends cleans temporary lists when any allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectStructExtendsAllocationFailureImpl,
        .{},
    );
}

fn expectImplConformanceValidationOutOfMemory(source: []const u8, fail_index: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);
    try collector.errors.ensureTotalCapacity(alloc, collector.errors.items.len + 1);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    const original_allocator = collector.allocator;
    collector.allocator = failing_allocator.allocator();
    defer collector.allocator = original_allocator;

    try std.testing.expectError(error.OutOfMemory, collector.validateImplConformance());
}

fn expectDuplicateStructDiagnosticNameAssemblyOutOfMemory(source: []const u8, fail_index: usize) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    try std.testing.expectEqual(@as(usize, 2), program.structs.len);

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectStruct(&program.structs[0], collector.graph.prelude_scope);
    try collector.errors.ensureTotalCapacity(alloc, collector.errors.items.len + 1);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
    const original_allocator = collector.allocator;
    collector.allocator = failing_allocator.allocator();
    defer collector.allocator = original_allocator;

    try std.testing.expectError(
        error.OutOfMemory,
        collector.collectStruct(&program.structs[1], collector.graph.prelude_scope),
    );
    try std.testing.expectEqual(@as(usize, 0), collector.errors.items.len);
}

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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Should have: prelude scope + struct scope + function scope
    try std.testing.expectEqual(@as(usize, 3), collector.graph.scopes.items.len);
    // Should have 1 function family
    try std.testing.expectEqual(@as(usize, 1), collector.graph.families.items.len);
    // Family should have arity 2
    try std.testing.expectEqual(@as(u32, 2), collector.graph.families.items[0].arity);
    // Should have 2 parameter bindings (x, y)
    try std.testing.expectEqual(@as(usize, 2), collector.graph.bindings.items.len);
}

test "collect struct with functions" {
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // prelude + struct + 2 function scopes
    try std.testing.expectEqual(@as(usize, 4), collector.graph.scopes.items.len);
    // 2 function families
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items.len);
    // 1 struct
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Both clauses should be in one family (same name, same arity)
    try std.testing.expectEqual(@as(usize, 1), collector.graph.families.items.len);
    // Family should have 2 clauses
    try std.testing.expectEqual(@as(usize, 2), collector.graph.families.items[0].clauses.items.len);
}

test "duplicate @doc on same function family produces error" {
    const source =
        \\pub struct Test {
        \\  @doc = """
        \\    Computes factorial.
        \\    """
        \\
        \\  pub fn factorial(0 :: i64) -> i64 {
        \\    1
        \\  }
        \\
        \\  @doc = """
        \\    Computes factorial differently.
        \\    """
        \\
        \\  pub fn factorial(n :: i64) -> i64 {
        \\    n * factorial(n - 1)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    try std.testing.expect(collector.errors.items.len > 0);
    const err_msg = collector.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "duplicate @doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "factorial/1") != null);
}

test "duplicate @doc on same macro family produces error" {
    const source =
        \\pub struct Test {
        \\  @doc = """
        \\    Picks an expression.
        \\    """
        \\
        \\  pub macro pick(:ok :: Atom) -> Expr {
        \\    quote { "ok" }
        \\  }
        \\
        \\  @doc = """
        \\    Picks a fallback expression.
        \\    """
        \\
        \\  pub macro pick(_value :: Expr) -> Expr {
        \\    quote { "other" }
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    try std.testing.expect(collector.errors.items.len > 0);
    const err_msg = collector.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "duplicate @doc") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "pick/1") != null);
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // prelude + struct + function + 2 case clause scopes
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    // Should have 1 type registered (struct)
    try std.testing.expectEqual(@as(usize, 1), collector.graph.types.items.len);
    try std.testing.expect(collector.graph.types.items[0].kind == .struct_type);
}

test "collect empty struct declaration registers nominal type" {
    const source =
        \\pub struct Memory.ARC {
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), collector.graph.types.items.len);
    try std.testing.expect(collector.graph.types.items[0].kind == .struct_type);
}

test "collect protocol declaration" {
    const source =
        \\pub protocol Enumerable {
        \\  fn each(collection, callback :: fn(member) -> member) -> collection
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    try std.testing.expectEqual(@as(usize, 1), collector.graph.protocols.items.len);
    const proto = collector.graph.protocols.items[0];
    try std.testing.expectEqual(@as(usize, 1), proto.decl.functions.len);
}

test "collect impl declaration" {
    const source =
        \\pub impl Enumerable for List {
        \\  pub fn each(list :: [member], callback :: fn(member) -> member) -> [member] {
        \\    list
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
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

test "validateImplConformance propagates OutOfMemory while formatting undefined protocol diagnostic" {
    const source =
        \\pub impl MissingProtocol for List {
        \\  pub fn each(list :: [member]) -> [member] {
        \\    list
        \\  }
        \\}
    ;

    try expectImplConformanceValidationOutOfMemory(source, 1);
}

test "validateImplConformance propagates OutOfMemory while formatting arity mismatch diagnostic" {
    const source =
        \\pub protocol Printable {
        \\  fn to_string(value, options) -> String
        \\}
        \\pub impl Printable for List {
        \\  pub fn to_string(list :: [member]) -> String {
        \\    "list"
        \\  }
        \\}
    ;

    try expectImplConformanceValidationOutOfMemory(source, 2);
}

test "validateImplConformance propagates OutOfMemory while formatting missing function diagnostic" {
    const source =
        \\pub protocol Printable {
        \\  fn to_string(value) -> String
        \\}
        \\pub impl Printable for List {
        \\  pub fn other(list :: [member]) -> String {
        \\    "list"
        \\  }
        \\}
    ;

    try expectImplConformanceValidationOutOfMemory(source, 2);
}

test "formatStructName propagates OutOfMemory for dotted names" {
    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    const outer = try interner.intern("Outer");
    const inner = try interner.intern("Inner");
    const parts = [_]ast.StringId{ outer, inner };
    const name = ast.StructName{
        .parts = &parts,
        .span = .{ .start = 0, .end = 11 },
    };

    var collector = try Collector.init(std.testing.allocator, &interner, null);
    defer collector.deinit();

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const original_allocator = collector.allocator;
    collector.allocator = failing_allocator.allocator();
    defer collector.allocator = original_allocator;

    try std.testing.expectError(error.OutOfMemory, collector.formatStructName(name));
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

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    collector.collectProgram(&program) catch {};

    try std.testing.expect(collector.errors.items.len > 0);
    const err_msg = collector.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "already defined") != null);
}

test "duplicate dotted struct declaration reports full diagnostic name" {
    const source =
        \\pub struct Foo.Bar {
        \\  pub fn bar() -> String {
        \\    "hello"
        \\  }
        \\}
        \\pub struct Foo.Bar {
        \\  pub fn baz() -> String {
        \\    "world"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    collector.collectProgram(&program) catch {};

    try std.testing.expect(collector.errors.items.len > 0);
    const err_msg = collector.errors.items[0].message;
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "struct 'Foo.Bar' is already defined") != null);
}

test "duplicate dotted struct diagnostic name assembly propagates OutOfMemory" {
    const source =
        \\pub struct Foo.Bar {
        \\  pub fn bar() -> String {
        \\    "hello"
        \\  }
        \\}
        \\pub struct Foo.Bar {
        \\  pub fn baz() -> String {
        \\    "world"
        \\  }
        \\}
    ;

    try expectDuplicateStructDiagnosticNameAssemblyOutOfMemory(source, 0);
}

test "extends cycle through parent chain produces circular inheritance diagnostic" {
    const source =
        \\pub struct A extends B {
        \\}
        \\pub struct B extends C {
        \\}
        \\pub struct C extends B {
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parser = try Parser.init(alloc, source);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = try Collector.init(alloc, parser.interner, null);
    defer collector.deinit();
    collector.collectProgram(&program) catch {};

    var saw_cycle = false;
    for (collector.errors.items) |collect_error| {
        if (std.mem.indexOf(u8, collect_error.message, "circular struct inheritance detected") != null) {
            saw_cycle = true;
        }
    }
    try std.testing.expect(saw_cycle);
}

test "collectPatternBindings rejects macro-produced patterns beyond traversal budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var collector = try Collector.init(std.testing.allocator, &interner, null);
    defer collector.deinit();

    const pattern = try makeCollectorDeepParenPattern(allocator, &interner, MAX_COLLECTOR_AST_WALK_DEPTH + 1);

    try std.testing.expectError(
        error.CollectorAstWalkBudgetExceeded,
        collector.collectPatternBindings(pattern, collector.graph.prelude_scope),
    );
    try std.testing.expectEqual(@as(usize, 1), collector.errors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, collector.errors.items[0].message, "collector AST traversal budget") != null);
}

test "collectExprScopes rejects macro-produced expressions beyond traversal budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var interner = ast.StringInterner.init(std.testing.allocator);
    defer interner.deinit();

    var collector = try Collector.init(std.testing.allocator, &interner, null);
    defer collector.deinit();

    const expr = try makeCollectorDeepUnaryExpr(allocator, MAX_COLLECTOR_AST_WALK_DEPTH + 1);

    try std.testing.expectError(
        error.CollectorAstWalkBudgetExceeded,
        collector.collectExprScopes(expr, collector.graph.prelude_scope),
    );
    try std.testing.expectEqual(@as(usize, 1), collector.errors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, collector.errors.items[0].message, "collector AST traversal budget") != null);
}
