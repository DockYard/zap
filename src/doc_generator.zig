//! Documentation Generator
//!
//! Extracts @doc and @structdoc attributes from the scope graph and generates
//! static HTML documentation and Markdown files. Used by `zap doc`.

const std = @import("std");
const zap = @import("root.zig");
const ast = zap.ast;
const scope = zap.scope;
const compiler = zap.compiler;
const builder = zap.builder;

// ============================================================
// String buffer helper (wraps ArrayListUnmanaged with allocator)
// ============================================================

const StringBuffer = struct {
    list: std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) StringBuffer {
        return .{ .list = .empty, .alloc = alloc };
    }

    fn str(self: *StringBuffer, s: []const u8) void {
        self.list.appendSlice(self.alloc, s) catch {};
    }

    fn char(self: *StringBuffer, c: u8) void {
        self.list.append(self.alloc, c) catch {};
    }

    fn fmt(self: *StringBuffer, comptime f: []const u8, args: anytype) void {
        const s = std.fmt.allocPrint(self.alloc, f, args) catch return;
        self.list.appendSlice(self.alloc, s) catch {};
    }

    fn toSlice(self: *StringBuffer) []const u8 {
        return self.list.items;
    }
};

// ============================================================
// Public API
// ============================================================

pub const DocOptions = struct {
    project_name: []const u8,
    project_version: []const u8,
    source_url: ?[]const u8 = null,
    landing_page: ?[]const u8 = null,
    doc_groups: []const builder.BuildConfig.DocGroup = &.{},
    output_dir: []const u8 = "docs",
    project_root: []const u8 = ".",
    source_units: []const compiler.SourceUnit = &.{},
    no_deps: bool = false,
};

/// Generate documentation from a compiled scope graph.
pub fn generate(
    alloc: std.mem.Allocator,
    ctx: *compiler.CompilationContext,
    options: DocOptions,
) !void {
    const graph = &ctx.collector.graph;
    const interner = &ctx.interner;

    // Extract documentation data from the scope graph
    var structs: std.ArrayListUnmanaged(DocStruct) = .empty;
    var seen_structs = std.StringHashMap(void).init(alloc);

    for (graph.structs.items) |mod_entry| {
        const mod_name = resolveStructName(alloc, mod_entry.name, interner) catch continue;

        // Skip duplicate structs (same struct discovered from multiple source roots)
        if (seen_structs.contains(mod_name)) continue;
        seen_structs.put(mod_name, {}) catch {};

        // Skip internal/build structs
        if (std.mem.eql(u8, mod_name, "Zap.Builder")) continue;
        if (std.mem.eql(u8, mod_name, "Zap.Manifest")) continue;
        if (std.mem.eql(u8, mod_name, "Zap.Env")) continue;
        if (std.mem.eql(u8, mod_name, "Zap.Dep")) continue;

        // Find the source file for this struct
        const source_file = sourceFileForMeta(mod_entry.decl.meta, options.source_units) orelse "";

        // Extract @doc for the struct
        const structdoc = extractDocAttribute(alloc, mod_entry.attributes, "doc", interner) orelse "";

        // Collect public functions and macros
        var functions: std.ArrayListUnmanaged(DocFunction) = .empty;

        for (graph.families.items) |family| {
            if (family.scope_id != mod_entry.scope_id) continue;
            if (family.visibility != .public) continue;

            const func_name = interner.get(family.name);
            const doc_text = extractDocAttribute(alloc, family.attributes, "doc", interner) orelse "";
            const summary = extractFirstSentence(alloc, doc_text);
            const signatures = buildFunctionSignatures(alloc, family, interner, options.source_units);
            const source_line = getSourceLine(family, options.source_units);

            functions.append(alloc, .{
                .name = func_name,
                .arity = family.arity,
                .signature = firstSignature(signatures),
                .signatures = signatures,
                .doc = doc_text,
                .summary = summary,
                .source_line = source_line,
                .is_macro = false,
            }) catch {};
        }

        for (graph.macro_families.items) |family| {
            if (family.scope_id != mod_entry.scope_id) continue;

            const macro_name = interner.get(family.name);
            if (std.mem.startsWith(u8, macro_name, "__")) continue;

            const doc_text = extractDocAttribute(alloc, family.attributes, "doc", interner) orelse "";
            const summary = extractFirstSentence(alloc, doc_text);
            const signatures = buildMacroSignatures(alloc, family, interner, options.source_units);
            const source_line = getMacroSourceLine(family, options.source_units);

            functions.append(alloc, .{
                .name = macro_name,
                .arity = family.arity,
                .signature = firstSignature(signatures),
                .signatures = signatures,
                .doc = doc_text,
                .summary = summary,
                .source_line = source_line,
                .is_macro = true,
            }) catch {};
        }

        structs.append(alloc, .{
            .name = mod_name,
            .kind = .@"struct",
            .structdoc = structdoc,
            .source_file = source_file,
            .functions = functions.toOwnedSlice(alloc) catch &.{},
        }) catch {};
    }

    for (graph.protocols.items) |protocol_entry| {
        if (protocol_entry.decl.is_private) continue;

        const protocol_name = resolveStructName(alloc, protocol_entry.name, interner) catch continue;
        if (seen_structs.contains(protocol_name)) continue;
        seen_structs.put(protocol_name, {}) catch {};

        const source_file = sourceFileForMeta(protocol_entry.decl.meta, options.source_units) orelse "";
        const protocol_doc = extractDocAttribute(alloc, protocol_entry.attributes, "doc", interner) orelse "";
        const protocol_functions = buildProtocolFunctionDocs(
            alloc,
            protocol_entry.decl.functions,
            interner,
        );

        structs.append(alloc, .{
            .name = protocol_name,
            .kind = .protocol,
            .structdoc = protocol_doc,
            .source_file = source_file,
            .functions = &.{},
            .protocol_functions = protocol_functions,
        }) catch {};
    }

    for (graph.types.items) |type_entry| {
        switch (type_entry.kind) {
            .union_type => |union_decl| {
                const union_name = interner.get(type_entry.name);
                if (seen_structs.contains(union_name)) continue;
                seen_structs.put(union_name, {}) catch {};

                const source_file = sourceFileForMeta(union_decl.meta, options.source_units) orelse "";
                const union_doc = extractDocAttribute(alloc, type_entry.attributes, "doc", interner) orelse "";
                const variants = buildUnionVariantDocs(alloc, union_decl.variants, interner);

                structs.append(alloc, .{
                    .name = union_name,
                    .kind = .@"union",
                    .structdoc = union_doc,
                    .source_file = source_file,
                    .functions = &.{},
                    .union_variants = variants,
                }) catch {};
            },
            else => {},
        }
    }

    // Sort structs alphabetically
    const mod_slice = structs.toOwnedSlice(alloc) catch &.{};
    std.mem.sort(DocStruct, @constCast(mod_slice), {}, struct {
        fn lessThan(_: void, a: DocStruct, b: DocStruct) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    const project = DocProject{
        .name = options.project_name,
        .version = options.project_version,
        .source_url = options.source_url,
        .structs = mod_slice,
    };

    // Create output directories
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().createDirPath(io, options.output_dir) catch {};
    const structs_dir = try std.fmt.allocPrint(alloc, "{s}/structs", .{options.output_dir});
    std.Io.Dir.cwd().createDirPath(io, structs_dir) catch {};
    const api_dir = try std.fmt.allocPrint(alloc, "{s}/api", .{options.output_dir});
    std.Io.Dir.cwd().createDirPath(io, api_dir) catch {};

    // Generate landing page
    try generateLandingPage(alloc, project, options);

    // Generate struct pages (HTML + Markdown)
    for (project.structs) |mod| {
        try generateStructPage(alloc, mod, project, options);
        try generateStructMarkdown(alloc, mod, project, options);
    }

    // Generate search index
    try generateSearchIndex(alloc, project, options);

    // Generate CSS
    try generateAsset(alloc, options.output_dir, "style.css", css_content);

    // Generate JS with inlined search index
    try generateScriptWithIndex(alloc, project, options);

    // Generate doc group pages
    for (options.doc_groups) |group| {
        for (group.pages) |page_path| {
            try generateDocGroupPage(alloc, page_path, project, options);
        }
    }

    std.debug.print("  {d} declarations, {d} functions documented\n", .{
        project.structs.len,
        countFunctions(project),
    });
}

// ============================================================
// Data model
// ============================================================

const DocProject = struct {
    name: []const u8,
    version: []const u8,
    source_url: ?[]const u8,
    structs: []const DocStruct,
};

const DocStruct = struct {
    name: []const u8,
    kind: DocKind = .@"struct",
    structdoc: []const u8,
    source_file: []const u8,
    functions: []const DocFunction,
    protocol_functions: []const DocProtocolFunction = &.{},
    union_variants: []const DocUnionVariant = &.{},
};

const DocKind = enum {
    @"struct",
    protocol,
    @"union",
};

const DocFunction = struct {
    name: []const u8,
    arity: u32,
    signature: []const u8,
    signatures: []const []const u8,
    doc: []const u8,
    summary: []const u8,
    source_line: u32,
    is_macro: bool,
};

const DocProtocolFunction = struct {
    name: []const u8,
    signature: []const u8,
};

const DocUnionVariant = struct {
    name: []const u8,
    signature: []const u8,
};

// ============================================================
// Extraction helpers
// ============================================================

fn resolveStructName(alloc: std.mem.Allocator, name: ast.StructName, interner: *const ast.StringInterner) ![]const u8 {
    if (name.parts.len == 0) return "";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (name.parts, 0..) |part, i| {
        if (i > 0) buf.append(alloc, '.') catch {};
        buf.appendSlice(alloc, interner.get(part)) catch {};
    }
    return buf.toOwnedSlice(alloc);
}

fn extractDocAttribute(
    alloc: std.mem.Allocator,
    attributes: std.ArrayListUnmanaged(scope.Attribute),
    attr_name: []const u8,
    interner: *const ast.StringInterner,
) ?[]const u8 {
    for (attributes.items) |attr| {
        const name = interner.get(attr.name);
        if (std.mem.eql(u8, name, attr_name)) {
            if (attr.value) |val_expr| {
                return extractStringFromExpr(alloc, val_expr, interner);
            }
        }
    }
    return null;
}

fn extractStringFromExpr(alloc: std.mem.Allocator, expr: *const ast.Expr, interner: *const ast.StringInterner) ?[]const u8 {
    switch (expr.*) {
        .string_literal => |lit| {
            const raw = interner.get(lit.value);
            return stripHeredocIndent(alloc, raw);
        },
        else => return null,
    }
}

/// Strip common leading whitespace from heredoc content.
/// Finds the minimum indentation across all non-empty lines and removes it.
fn stripHeredocIndent(alloc: std.mem.Allocator, text: []const u8) []const u8 {
    // Find minimum indentation
    var min_indent: usize = std.math.maxInt(usize);
    var line_iter = std.mem.splitSequence(u8, text, "\n");
    while (line_iter.next()) |line| {
        if (std.mem.trimStart(u8, line, " \t").len == 0) continue; // skip blank lines
        var indent: usize = 0;
        for (line) |c| {
            if (c == ' ') {
                indent += 1;
            } else if (c == '\t') {
                indent += 4;
            } else {
                break;
            }
        }
        if (indent < min_indent) min_indent = indent;
    }

    if (min_indent == 0 or min_indent == std.math.maxInt(usize)) {
        return alloc.dupe(u8, text) catch text;
    }

    // Rebuild with indentation stripped
    var result: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitSequence(u8, text, "\n");
    var first = true;
    while (lines.next()) |line| {
        if (!first) result.append(alloc, '\n') catch {};
        first = false;
        if (std.mem.trimStart(u8, line, " \t").len == 0) {
            // Blank line — keep empty
            continue;
        }
        // Strip min_indent characters
        var to_strip = min_indent;
        var start: usize = 0;
        while (start < line.len and to_strip > 0) {
            if (line[start] == ' ') {
                to_strip -= 1;
                start += 1;
            } else if (line[start] == '\t') {
                if (to_strip >= 4) {
                    to_strip -= 4;
                } else {
                    to_strip = 0;
                }
                start += 1;
            } else {
                break;
            }
        }
        result.appendSlice(alloc, line[start..]) catch {};
    }
    return result.toOwnedSlice(alloc) catch text;
}

fn extractFirstSentence(alloc: std.mem.Allocator, doc: []const u8) []const u8 {
    if (doc.len == 0) return "";
    var start: usize = 0;
    while (start < doc.len and (doc[start] == ' ' or doc[start] == '\n' or doc[start] == '\r' or doc[start] == '\t')) {
        start += 1;
    }
    var i = start;
    while (i < doc.len) : (i += 1) {
        if (doc[i] == '.' and (i + 1 >= doc.len or doc[i + 1] == ' ' or doc[i + 1] == '\n')) {
            return alloc.dupe(u8, doc[start .. i + 1]) catch "";
        }
        if (doc[i] == '\n' and i + 1 < doc.len and doc[i + 1] == '\n') {
            return alloc.dupe(u8, doc[start..i]) catch "";
        }
    }
    const end = @min(doc.len, start + 200);
    return alloc.dupe(u8, doc[start..end]) catch "";
}

fn firstSignature(signatures: []const []const u8) []const u8 {
    if (signatures.len == 0) return "";
    return signatures[0];
}

fn buildFunctionSignatures(
    alloc: std.mem.Allocator,
    family: scope.FunctionFamily,
    interner: *const ast.StringInterner,
    source_units: []const compiler.SourceUnit,
) []const []const u8 {
    const func_name = interner.get(family.name);
    return buildClauseSignatures(alloc, func_name, family.clauses.items, interner, source_units);
}

fn buildMacroSignatures(
    alloc: std.mem.Allocator,
    family: scope.MacroFamily,
    interner: *const ast.StringInterner,
    source_units: []const compiler.SourceUnit,
) []const []const u8 {
    const macro_name = interner.get(family.name);
    return buildClauseSignatures(alloc, macro_name, family.clauses.items, interner, source_units);
}

fn buildClauseSignatures(
    alloc: std.mem.Allocator,
    function_name: []const u8,
    clauses: []const scope.FunctionClauseRef,
    interner: *const ast.StringInterner,
    source_units: []const compiler.SourceUnit,
) []const []const u8 {
    var signatures: std.ArrayListUnmanaged([]const u8) = .empty;
    for (clauses) |clause_ref| {
        if (clause_ref.clause_index >= clause_ref.decl.clauses.len) continue;
        const clause = clause_ref.decl.clauses[clause_ref.clause_index];
        signatures.append(alloc, buildClauseSignature(alloc, function_name, clause, interner, source_units)) catch {};
    }

    if (signatures.items.len == 0) {
        signatures.append(alloc, std.fmt.allocPrint(alloc, "{s}()", .{function_name}) catch function_name) catch {};
    }

    return signatures.toOwnedSlice(alloc) catch &.{};
}

fn buildClauseSignature(
    alloc: std.mem.Allocator,
    function_name: []const u8,
    clause: ast.FunctionClause,
    interner: *const ast.StringInterner,
    source_units: []const compiler.SourceUnit,
) []const u8 {
    var buf = StringBuffer.init(alloc);
    buf.str(function_name);
    buf.char('(');

    for (clause.params, 0..) |param, i| {
        if (i > 0) buf.str(", ");
        appendPattern(&buf, param.pattern, interner, source_units);
        if (param.type_annotation) |type_ann| {
            buf.str(" :: ");
            appendTypeExpr(&buf, type_ann, interner);
        }
        if (param.default) |default_expr| {
            buf.str(" = ");
            appendExpr(&buf, default_expr, interner, source_units);
        }
    }
    buf.char(')');

    if (clause.return_type) |ret| {
        buf.str(" -> ");
        appendTypeExpr(&buf, ret, interner);
    }

    if (clause.refinement) |refinement| {
        buf.str(" if ");
        appendExpr(&buf, refinement, interner, source_units);
    }

    return buf.toSlice();
}

fn buildProtocolFunctionDocs(
    alloc: std.mem.Allocator,
    function_sigs: []const ast.ProtocolFunctionSig,
    interner: *const ast.StringInterner,
) []const DocProtocolFunction {
    var docs: std.ArrayListUnmanaged(DocProtocolFunction) = .empty;
    for (function_sigs) |function_sig| {
        const function_name = interner.get(function_sig.name);
        docs.append(alloc, .{
            .name = function_name,
            .signature = buildProtocolFunctionSignature(alloc, function_sig, interner),
        }) catch {};
    }
    return docs.toOwnedSlice(alloc) catch &.{};
}

fn buildProtocolFunctionSignature(
    alloc: std.mem.Allocator,
    function_sig: ast.ProtocolFunctionSig,
    interner: *const ast.StringInterner,
) []const u8 {
    var buf = StringBuffer.init(alloc);
    buf.str(interner.get(function_sig.name));
    buf.char('(');
    for (function_sig.params, 0..) |param, index| {
        if (index > 0) buf.str(", ");
        buf.str(interner.get(param.name));
        if (param.type_annotation) |type_annotation| {
            buf.str(" :: ");
            appendTypeExpr(&buf, type_annotation, interner);
        }
    }
    buf.char(')');
    if (function_sig.return_type) |return_type| {
        buf.str(" -> ");
        appendTypeExpr(&buf, return_type, interner);
    }
    return buf.toSlice();
}

fn buildUnionVariantDocs(
    alloc: std.mem.Allocator,
    variants: []const ast.UnionVariant,
    interner: *const ast.StringInterner,
) []const DocUnionVariant {
    var docs: std.ArrayListUnmanaged(DocUnionVariant) = .empty;
    for (variants) |variant| {
        const variant_name = interner.get(variant.name);
        var signature = StringBuffer.init(alloc);
        signature.str(variant_name);
        if (variant.type_expr) |type_expr| {
            signature.str(" :: ");
            appendTypeExpr(&signature, type_expr, interner);
        }
        docs.append(alloc, .{
            .name = variant_name,
            .signature = signature.toSlice(),
        }) catch {};
    }
    return docs.toOwnedSlice(alloc) catch &.{};
}

fn sourceSlice(meta: ast.NodeMeta, source_units: []const compiler.SourceUnit) ?[]const u8 {
    const source_id = meta.span.source_id orelse return null;
    if (source_id >= source_units.len) return null;
    const source = source_units[source_id].source;
    if (meta.span.start >= meta.span.end) return null;
    if (meta.span.end > source.len) return null;
    return std.mem.trim(u8, source[meta.span.start..meta.span.end], " \t\r\n");
}

fn appendStructName(buf: *StringBuffer, name: ast.StructName, interner: *const ast.StringInterner) void {
    for (name.parts, 0..) |part, i| {
        if (i > 0) buf.char('.');
        buf.str(interner.get(part));
    }
}

fn appendZapStringLiteral(buf: *StringBuffer, value: []const u8) void {
    buf.char('"');
    for (value) |c| {
        switch (c) {
            '\\' => buf.str("\\\\"),
            '"' => buf.str("\\\""),
            '\n' => buf.str("\\n"),
            '\r' => buf.str("\\r"),
            '\t' => buf.str("\\t"),
            else => buf.char(c),
        }
    }
    buf.char('"');
}

fn appendLiteralPattern(buf: *StringBuffer, literal: ast.LiteralPattern, interner: *const ast.StringInterner) void {
    switch (literal) {
        .int => |v| buf.fmt("{d}", .{v.value}),
        .float => |v| buf.fmt("{d}", .{v.value}),
        .string => |v| appendZapStringLiteral(buf, interner.get(v.value)),
        .atom => |v| {
            buf.char(':');
            buf.str(interner.get(v.value));
        },
        .bool_lit => |v| buf.str(if (v.value) "true" else "false"),
        .nil => buf.str("nil"),
    }
}

fn appendPattern(
    buf: *StringBuffer,
    pattern: *const ast.Pattern,
    interner: *const ast.StringInterner,
    source_units: []const compiler.SourceUnit,
) void {
    if (sourceSlice(pattern.getMeta(), source_units)) |text| {
        buf.str(text);
        return;
    }

    switch (pattern.*) {
        .wildcard => buf.char('_'),
        .bind => |v| buf.str(interner.get(v.name)),
        .pin => |v| {
            buf.char('^');
            buf.str(interner.get(v.name));
        },
        .literal => |literal| appendLiteralPattern(buf, literal, interner),
        .paren => |v| {
            buf.char('(');
            appendPattern(buf, v.inner, interner, source_units);
            buf.char(')');
        },
        .tuple => |v| {
            buf.char('{');
            for (v.elements, 0..) |element, i| {
                if (i > 0) buf.str(", ");
                appendPattern(buf, element, interner, source_units);
            }
            buf.char('}');
        },
        .list => |v| {
            buf.char('[');
            for (v.elements, 0..) |element, i| {
                if (i > 0) buf.str(", ");
                appendPattern(buf, element, interner, source_units);
            }
            buf.char(']');
        },
        .list_cons => |v| {
            buf.char('[');
            for (v.heads, 0..) |head, i| {
                if (i > 0) buf.str(", ");
                appendPattern(buf, head, interner, source_units);
            }
            if (v.heads.len > 0) buf.str(" | ");
            appendPattern(buf, v.tail, interner, source_units);
            buf.char(']');
        },
        .map => |v| {
            buf.str("%{");
            for (v.fields, 0..) |field, i| {
                if (i > 0) buf.str(", ");
                appendExpr(buf, field.key, interner, source_units);
                buf.str(" => ");
                appendPattern(buf, field.value, interner, source_units);
            }
            buf.char('}');
        },
        .struct_pattern => |v| {
            buf.char('%');
            appendStructName(buf, v.struct_name, interner);
            buf.char('{');
            for (v.fields, 0..) |field, i| {
                if (i > 0) buf.str(", ");
                buf.str(interner.get(field.name));
                buf.str(": ");
                appendPattern(buf, field.pattern, interner, source_units);
            }
            buf.char('}');
        },
        .binary => |v| {
            buf.str("<<");
            for (v.segments, 0..) |segment, i| {
                if (i > 0) buf.str(", ");
                switch (segment.value) {
                    .pattern => |segment_pattern| appendPattern(buf, segment_pattern, interner, source_units),
                    .string_literal => |string_id| appendZapStringLiteral(buf, interner.get(string_id)),
                    .expr => |expr| appendExpr(buf, expr, interner, source_units),
                }
            }
            buf.str(">>");
        },
    }
}

fn binaryOpString(op: ast.BinaryOp.Op) []const u8 {
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

fn appendExpr(
    buf: *StringBuffer,
    expr: *const ast.Expr,
    interner: *const ast.StringInterner,
    source_units: []const compiler.SourceUnit,
) void {
    if (sourceSlice(expr.getMeta(), source_units)) |text| {
        buf.str(text);
        return;
    }

    switch (expr.*) {
        .int_literal => |v| buf.fmt("{d}", .{v.value}),
        .float_literal => |v| buf.fmt("{d}", .{v.value}),
        .string_literal => |v| appendZapStringLiteral(buf, interner.get(v.value)),
        .atom_literal => |v| {
            buf.char(':');
            buf.str(interner.get(v.value));
        },
        .bool_literal => |v| buf.str(if (v.value) "true" else "false"),
        .nil_literal => buf.str("nil"),
        .var_ref => |v| buf.str(interner.get(v.name)),
        .struct_ref => |v| appendStructName(buf, v.name, interner),
        .type_annotated => |v| {
            appendExpr(buf, v.expr, interner, source_units);
            buf.str(" :: ");
            appendTypeExpr(buf, v.type_expr, interner);
        },
        .unary_op => |v| {
            buf.str(switch (v.op) {
                .negate => "-",
                .not_op => "not ",
            });
            appendExpr(buf, v.operand, interner, source_units);
        },
        .binary_op => |v| {
            appendExpr(buf, v.lhs, interner, source_units);
            buf.char(' ');
            buf.str(binaryOpString(v.op));
            buf.char(' ');
            appendExpr(buf, v.rhs, interner, source_units);
        },
        else => buf.char('?'),
    }
}

fn appendTypeExpr(buf: *StringBuffer, type_expr: *const ast.TypeExpr, interner: *const ast.StringInterner) void {
    switch (type_expr.*) {
        .name => |n| {
            buf.str(interner.get(n.name));
        },
        .variable => |v| {
            buf.str(interner.get(v.name));
        },
        .list => |l| {
            buf.char('[');
            appendTypeExpr(buf, l.element, interner);
            buf.char(']');
        },
        .tuple => |t| {
            buf.char('{');
            for (t.elements, 0..) |elem, i| {
                if (i > 0) buf.str(", ");
                appendTypeExpr(buf, elem, interner);
            }
            buf.char('}');
        },
        .function => |f| {
            buf.char('(');
            for (f.params, 0..) |param, i| {
                if (i > 0) buf.str(", ");
                appendTypeExpr(buf, param, interner);
            }
            buf.str(") -> ");
            appendTypeExpr(buf, f.return_type, interner);
        },
        else => buf.char('?'),
    }
}

fn getSourceLine(family: scope.FunctionFamily, source_units: []const compiler.SourceUnit) u32 {
    if (family.clauses.items.len == 0) return 0;
    const first_clause = family.clauses.items[0];
    return computeLineNumber(first_clause.decl.meta, source_units);
}

fn getMacroSourceLine(family: scope.MacroFamily, source_units: []const compiler.SourceUnit) u32 {
    if (family.clauses.items.len == 0) return 0;
    const first_clause = family.clauses.items[0];
    return computeLineNumber(first_clause.decl.meta, source_units);
}

fn computeLineNumber(meta: ast.NodeMeta, source_units: []const compiler.SourceUnit) u32 {
    const source_id = meta.span.source_id orelse return 0;
    if (source_id >= source_units.len) return 0;
    const source = source_units[source_id].source;
    if (meta.span.start >= source.len) return 0;
    var line: u32 = 1;
    for (source[0..meta.span.start]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn sourceFileForMeta(meta: ast.NodeMeta, source_units: []const compiler.SourceUnit) ?[]const u8 {
    const source_id = meta.span.source_id orelse return null;
    if (source_id >= source_units.len) return null;
    return source_units[source_id].file_path;
}

fn docKindLabel(kind: DocKind) []const u8 {
    return switch (kind) {
        .@"struct" => "pub struct",
        .protocol => "pub protocol",
        .@"union" => "pub union",
    };
}

fn docKindSearchType(kind: DocKind) []const u8 {
    return switch (kind) {
        .@"struct" => "struct",
        .protocol => "protocol",
        .@"union" => "union",
    };
}

fn docKindDetailHeading(kind: DocKind) []const u8 {
    return switch (kind) {
        .@"struct" => "Function Details",
        .protocol => "Required Functions",
        .@"union" => "Variants",
    };
}

fn docKindMarkdownHeading(kind: DocKind) []const u8 {
    return switch (kind) {
        .@"struct" => "Functions",
        .protocol => "Required Functions",
        .@"union" => "Variants",
    };
}

fn shouldRenderDeclarationDetails(mod: DocStruct) bool {
    return mod.protocol_functions.len > 0 or mod.union_variants.len > 0;
}

fn countFunctions(project: DocProject) usize {
    var count: usize = 0;
    for (project.structs) |mod| {
        count += mod.functions.len;
    }
    return count;
}

// ============================================================
// HTML generation
// ============================================================

fn generateLandingPage(alloc: std.mem.Allocator, project: DocProject, options: DocOptions) !void {
    var h = StringBuffer.init(alloc);
    appendPageHeader(&h, project.name, project, "");
    h.str("<div class=\"layout\">\n");
    appendSidebar(&h, project, null, options, "");
    h.str("<main class=\"content\">\n");

    if (options.landing_page) |landing_page_path| {
        const full_path = try std.fs.path.join(alloc, &.{ options.project_root, landing_page_path });
        if (std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, full_path, alloc, .limited(1024 * 1024))) |content| {
            h.str("<div class=\"structdoc\">\n");
            appendMarkdownAsHtml(&h, content);
            h.str("</div>\n");
        } else |_| {
            appendDefaultLanding(&h, project);
        }
    } else {
        appendDefaultLanding(&h, project);
    }

    h.str("</main>\n</div>\n");
    appendPageFooter(&h, "");

    const path = try std.fmt.allocPrint(alloc, "{s}/index.html", .{options.output_dir});
    try writeFile(path, h.toSlice());
}

fn appendDefaultLanding(h: *StringBuffer, project: DocProject) void {
    h.str("<h1>");
    appendHtmlEscaped(h, project.name);
    h.str("</h1>\n");

    if (project.version.len > 0) {
        h.str("<p class=\"version\">v");
        h.str(project.version);
        h.str("</p>\n");
    }

    h.str("<h2>Declarations</h2>\n<div class=\"struct-list\">\n");
    for (project.structs) |mod| {
        h.str("<div class=\"struct-card\">\n<h3><a href=\"structs/");
        h.str(mod.name);
        h.str(".html\">");
        appendHtmlEscaped(h, mod.name);
        h.str("</a></h3>\n");

        if (mod.structdoc.len > 0) {
            const summary = extractFirstSentence(h.alloc, mod.structdoc);
            if (summary.len > 0) {
                h.str("<p>");
                appendHtmlEscaped(h, summary);
                h.str("</p>\n");
            }
        }
        h.str("</div>\n");
    }
    h.str("</div>\n");
}

fn generateStructPage(alloc: std.mem.Allocator, mod: DocStruct, project: DocProject, options: DocOptions) !void {
    var h = StringBuffer.init(alloc);
    appendPageHeader(&h, mod.name, project, "../");
    h.str("<div class=\"layout\">\n");
    appendSidebar(&h, project, mod.name, options, "../");
    h.str("<main class=\"content\">\n");

    // Declaration header — title row with name left, declaration kind + source right
    h.str("<div class=\"title-row\">\n");
    h.str("<h1>");
    appendHtmlEscaped(&h, mod.name);
    h.str("</h1>\n");
    h.str("<div class=\"title-meta\">\n");
    h.str("<span class=\"pub-struct-pill\">");
    h.str(docKindLabel(mod.kind));
    h.str("</span>\n");
    if (mod.source_file.len > 0) {
        if (options.source_url) |base_url| {
            h.str("<a href=\"");
            h.str(base_url);
            h.str("/blob/v");
            h.str(project.version);
            h.str("/");
            h.str(mod.source_file);
            h.str("\" class=\"source-file\">");
            h.str(mod.source_file);
            h.str("</a>\n");
        } else {
            h.str("<span class=\"source-file\">");
            h.str(mod.source_file);
            h.str("</span>\n");
        }
    }
    h.str("</div>\n");
    h.str("</div>\n");

    // Tagline — extract first sentence of structdoc
    if (mod.structdoc.len > 0) {
        const tagline = extractFirstSentence(alloc, mod.structdoc);
        if (tagline.len > 0) {
            h.str("<p class=\"tagline\">");
            appendHtmlEscaped(&h, tagline);
            h.str("</p>\n");
        }
    }

    if (mod.structdoc.len > 0) {
        h.str("<div class=\"structdoc\">\n");
        appendMarkdownAsHtml(&h, mod.structdoc);
        h.str("</div>\n");
    }

    if (shouldRenderDeclarationDetails(mod)) {
        h.str("<h2>");
        h.str(docKindDetailHeading(mod.kind));
        h.str("</h2>\n<table class=\"summary\">\n");
        for (mod.protocol_functions) |protocol_function| {
            h.str("<tr><td class=\"summary-name\"><code>");
            appendHtmlEscaped(&h, protocol_function.name);
            h.str("</code></td><td class=\"summary-doc\"><code>");
            appendHtmlEscaped(&h, protocol_function.signature);
            h.str("</code></td></tr>\n");
        }
        for (mod.union_variants) |variant| {
            h.str("<tr><td class=\"summary-name\"><code>");
            appendHtmlEscaped(&h, variant.name);
            h.str("</code></td><td class=\"summary-doc\"><code>");
            appendHtmlEscaped(&h, variant.signature);
            h.str("</code></td></tr>\n");
        }
        h.str("</table>\n");
    }

    // Separate functions and macros
    var functions: std.ArrayListUnmanaged(DocFunction) = .empty;
    var macros: std.ArrayListUnmanaged(DocFunction) = .empty;
    for (mod.functions) |func| {
        if (func.is_macro) {
            macros.append(alloc, func) catch {};
        } else {
            functions.append(alloc, func) catch {};
        }
    }

    // Summary tables
    if (functions.items.len > 0) {
        h.str("<h2 id=\"functions\">Functions</h2>\n<table class=\"summary\">\n");
        for (functions.items) |func| {
            h.str("<tr><td class=\"summary-name\"><a href=\"#");
            appendAnchorId(&h, func);
            h.str("\">");
            appendHtmlEscaped(&h, func.name);
            h.fmt("/{d}", .{func.arity});
            h.str("</a></td><td class=\"summary-doc\">");
            appendHtmlEscaped(&h, func.summary);
            h.str("</td></tr>\n");
        }
        h.str("</table>\n");
    }

    if (macros.items.len > 0) {
        h.str("<h2 id=\"macros\">Macros</h2>\n<table class=\"summary\">\n");
        for (macros.items) |func| {
            h.str("<tr><td class=\"summary-name\"><a href=\"#");
            appendAnchorId(&h, func);
            h.str("\">");
            appendHtmlEscaped(&h, func.name);
            h.fmt("/{d}", .{func.arity});
            h.str("</a></td><td class=\"summary-doc\">");
            appendHtmlEscaped(&h, func.summary);
            h.str("</td></tr>\n");
        }
        h.str("</table>\n");
    }

    // Function details
    if (functions.items.len > 0) {
        h.str("<h2>Function Details</h2>\n");
        for (functions.items) |func| {
            appendFunctionDetail(&h, func, mod, project, options);
        }
    }
    if (macros.items.len > 0) {
        h.str("<h2>Macro Details</h2>\n");
        for (macros.items) |func| {
            appendFunctionDetail(&h, func, mod, project, options);
        }
    }

    // Right-hand TOC
    h.str("</main>\n<aside class=\"toc\">\n<h3>On This Page</h3>\n<ul>\n");
    if (functions.items.len > 0) {
        h.str("<li class=\"toc-section\">Functions</li>\n");
        for (functions.items) |func| {
            h.str("<li><a href=\"#");
            appendAnchorId(&h, func);
            h.str("\">");
            appendHtmlEscaped(&h, func.name);
            h.fmt("/{d}", .{func.arity});
            h.str("</a></li>\n");
        }
    }
    if (macros.items.len > 0) {
        h.str("<li class=\"toc-section\">Macros</li>\n");
        for (macros.items) |func| {
            h.str("<li><a href=\"#");
            appendAnchorId(&h, func);
            h.str("\">");
            appendHtmlEscaped(&h, func.name);
            h.fmt("/{d}", .{func.arity});
            h.str("</a></li>\n");
        }
    }
    h.str("</ul>\n</aside>\n</div>\n");
    appendPageFooter(&h, "../");

    const path = try std.fmt.allocPrint(alloc, "{s}/structs/{s}.html", .{ options.output_dir, mod.name });
    try writeFile(path, h.toSlice());
}

fn appendFunctionDetail(h: *StringBuffer, func: DocFunction, _: DocStruct, _: DocProject, _: DocOptions) void {
    h.str("<div class=\"function-detail\" id=\"");
    appendAnchorId(h, func);
    h.str("\">\n<div class=\"function-header\">\n<h3>");
    appendHtmlEscaped(h, func.name);
    h.str("<span class=\"arity\">/");
    h.fmt("{d}", .{func.arity});
    h.str("</span></h3>\n");

    if (func.is_macro) {
        h.str("<span class=\"badge\">pub macro</span>\n");
    } else {
        h.str("<span class=\"badge\">pub fn</span>\n");
    }
    h.str("<div style=\"flex:1\"></div>\n");
    h.str("<a href=\"#");
    appendAnchorId(h, func);
    h.str("\" class=\"anchor-link\">#</a>\n");
    h.str("</div>\n");

    // Clause signatures. A function family has one shared doc body,
    // but every clause head is rendered so pattern/type matches are visible.
    for (func.signatures) |signature| {
        h.str("<div class=\"signature\"><code>");
        appendRichSignature(h, signature);
        h.str("</code></div>\n");
    }

    // Doc body
    if (func.doc.len > 0) {
        h.str("<div class=\"function-doc\">\n");
        appendMarkdownAsHtml(h, func.doc);
        h.str("</div>\n");
    }

    h.str("</div>\n");
}

/// Parse a signature string like "name(arg1 :: Type1, arg2 :: Type2) -> ReturnType"
/// and render it with structured HTML spans for type pills.
fn appendRichSignature(h: *StringBuffer, signature: []const u8) void {
    // Find the opening paren to extract the function name
    const paren_open = std.mem.indexOf(u8, signature, "(") orelse {
        // No parens — just emit the whole thing as the name
        h.str("<span class=\"sig-name\">");
        appendHtmlEscaped(h, signature);
        h.str("</span>");
        return;
    };

    // Function name
    h.str("<span class=\"sig-name\">");
    appendHtmlEscaped(h, signature[0..paren_open]);
    h.str("</span>");
    h.str("<span class=\"sig-paren\">(</span>");

    // Find the matching closing paren (handle nested parens for function types)
    var depth: usize = 1;
    var pos = paren_open + 1;
    while (pos < signature.len and depth > 0) {
        if (signature[pos] == '(') {
            depth += 1;
        } else if (signature[pos] == ')') {
            depth -= 1;
        }
        if (depth > 0) pos += 1;
    }
    const paren_close = pos;
    const params_str = signature[paren_open + 1 .. paren_close];

    // Parse and render each parameter
    if (params_str.len > 0) {
        var param_parts = splitParams(params_str);
        var first_param = true;
        while (param_parts.next()) |param| {
            const trimmed_param = std.mem.trim(u8, param, " \t");
            if (trimmed_param.len == 0) continue;

            if (!first_param) {
                h.str("<span class=\"sig-paren\">, </span>");
            }
            first_param = false;

            // Split on top-level " :: " to avoid confusing nested pattern syntax
            // with the parameter's own type annotation.
            if (indexOfTopLevelToken(trimmed_param, " :: ")) |sep_idx| {
                const param_name = trimmed_param[0..sep_idx];
                const param_type = trimmed_param[sep_idx + 4 ..];
                appendHtmlEscaped(h, param_name);
                h.str("<span class=\"sig-separator\">::</span>");
                h.str("<span class=\"sig-type-pill\">");
                appendHtmlEscaped(h, param_type);
                h.str("</span>");
            } else {
                // No type annotation — just emit the name
                appendHtmlEscaped(h, trimmed_param);
            }
        }
    }

    h.str("<span class=\"sig-paren\">)</span>");

    // Check for return type after the closing paren
    if (paren_close + 1 < signature.len) {
        const after_paren = std.mem.trimStart(u8, signature[paren_close + 1 ..], " ");
        if (std.mem.startsWith(u8, after_paren, "-> ")) {
            const return_and_guard = std.mem.trimStart(u8, after_paren[3..], " ");
            const guard_start = indexOfTopLevelToken(return_and_guard, " if ");
            const return_type = if (guard_start) |idx| std.mem.trim(u8, return_and_guard[0..idx], " \t") else return_and_guard;
            const guard_expr = if (guard_start) |idx| std.mem.trim(u8, return_and_guard[idx + 4 ..], " \t") else "";

            if (return_type.len > 0) {
                h.str("<span class=\"sig-arrow\">\u{2192}</span>");
                h.str("<span class=\"sig-ret-pill\">");
                appendHtmlEscaped(h, return_type);
                h.str("</span>");
            }
            appendSignatureGuard(h, guard_expr);
        } else if (std.mem.startsWith(u8, after_paren, "if ")) {
            appendSignatureGuard(h, std.mem.trim(u8, after_paren[3..], " \t"));
        }
    }
}

fn appendSignatureGuard(h: *StringBuffer, guard_expr: []const u8) void {
    if (guard_expr.len == 0) return;
    h.str("<span class=\"sig-guard-keyword\">if</span>");
    h.str("<span class=\"sig-guard\">");
    appendHtmlEscaped(h, guard_expr);
    h.str("</span>");
}

/// Split a parameter string by commas, respecting nested parentheses and brackets.
/// Returns an iterator over the individual parameter substrings.
const ParamSplitter = struct {
    source: []const u8,
    pos: usize,

    fn next(self: *ParamSplitter) ?[]const u8 {
        if (self.pos >= self.source.len) return null;

        const start = self.pos;
        var scanner: SignatureScanner = .{};

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ',' and scanner.isTopLevel()) {
                const result = self.source[start..self.pos];
                self.pos += 1; // skip the comma
                return result;
            }
            scanner.consume(self.source, &self.pos);
        }
        return self.source[start..self.pos];
    }
};

fn splitParams(params: []const u8) ParamSplitter {
    return .{ .source = params, .pos = 0 };
}

const SignatureScanner = struct {
    depth_paren: usize = 0,
    depth_bracket: usize = 0,
    depth_brace: usize = 0,
    depth_binary: usize = 0,
    in_string: bool = false,
    string_escape: bool = false,

    fn isTopLevel(self: SignatureScanner) bool {
        return !self.in_string and self.depth_paren == 0 and self.depth_bracket == 0 and self.depth_brace == 0 and self.depth_binary == 0;
    }

    fn consume(self: *SignatureScanner, source: []const u8, index: *usize) void {
        const c = source[index.*];

        if (self.in_string) {
            if (self.string_escape) {
                self.string_escape = false;
            } else if (c == '\\') {
                self.string_escape = true;
            } else if (c == '"') {
                self.in_string = false;
            }
            index.* += 1;
            return;
        }

        if (c == '"') {
            self.in_string = true;
            index.* += 1;
            return;
        }

        if (index.* + 1 < source.len and source[index.*] == '<' and source[index.* + 1] == '<') {
            self.depth_binary += 1;
            index.* += 2;
            return;
        }

        if (index.* + 1 < source.len and source[index.*] == '>' and source[index.* + 1] == '>' and self.depth_binary > 0) {
            self.depth_binary -= 1;
            index.* += 2;
            return;
        }

        switch (c) {
            '(' => self.depth_paren += 1,
            ')' => {
                if (self.depth_paren > 0) self.depth_paren -= 1;
            },
            '[' => self.depth_bracket += 1,
            ']' => {
                if (self.depth_bracket > 0) self.depth_bracket -= 1;
            },
            '{' => self.depth_brace += 1,
            '}' => {
                if (self.depth_brace > 0) self.depth_brace -= 1;
            },
            else => {},
        }

        index.* += 1;
    }
};

fn indexOfTopLevelToken(source: []const u8, token: []const u8) ?usize {
    var scanner: SignatureScanner = .{};
    var index: usize = 0;
    while (index < source.len) {
        if (scanner.isTopLevel() and std.mem.startsWith(u8, source[index..], token)) {
            return index;
        }
        scanner.consume(source, &index);
    }
    return null;
}

// ============================================================
// Markdown output
// ============================================================

fn generateStructMarkdown(alloc: std.mem.Allocator, mod: DocStruct, project: DocProject, options: DocOptions) !void {
    var h = StringBuffer.init(alloc);

    h.str("# ");
    h.str(mod.name);
    h.str("\n\n");

    if (mod.structdoc.len > 0) {
        h.str(mod.structdoc);
        h.str("\n\n");
    }

    if (shouldRenderDeclarationDetails(mod)) {
        h.str("## ");
        h.str(docKindMarkdownHeading(mod.kind));
        h.str("\n\n");

        for (mod.protocol_functions) |protocol_function| {
            h.str("```zap\n");
            h.str("fn ");
            h.str(protocol_function.signature);
            h.str("\n```\n\n");
        }

        for (mod.union_variants) |variant| {
            h.str("```zap\n");
            h.str(variant.signature);
            h.str("\n```\n\n");
        }
    }

    var functions: std.ArrayListUnmanaged(DocFunction) = .empty;
    var macros: std.ArrayListUnmanaged(DocFunction) = .empty;
    for (mod.functions) |func| {
        if (func.is_macro) {
            macros.append(alloc, func) catch {};
        } else {
            functions.append(alloc, func) catch {};
        }
    }

    if (functions.items.len > 0) {
        h.str("## Functions\n\n");
        for (functions.items) |func| {
            appendFunctionMarkdown(&h, func, mod, project, options);
        }
    }
    if (macros.items.len > 0) {
        h.str("## Macros\n\n");
        for (macros.items) |func| {
            appendFunctionMarkdown(&h, func, mod, project, options);
        }
    }

    const path = try std.fmt.allocPrint(alloc, "{s}/api/{s}.md", .{ options.output_dir, mod.name });
    try writeFile(path, h.toSlice());
}

fn appendFunctionMarkdown(h: *StringBuffer, func: DocFunction, mod: DocStruct, project: DocProject, options: DocOptions) void {
    h.str("### ");
    h.str(func.name);
    h.fmt("/{d}\n\n", .{func.arity});

    h.str("```zap\n");
    for (func.signatures) |signature| {
        if (func.is_macro) {
            h.str("pub macro ");
        } else {
            h.str("pub fn ");
        }
        h.str(signature);
        h.char('\n');
    }
    h.str("```\n\n");

    if (func.doc.len > 0) {
        h.str(func.doc);
        h.str("\n\n");
    }

    if (func.source_line > 0 and mod.source_file.len > 0) {
        if (options.source_url) |base_url| {
            h.str("[Source](");
            h.str(base_url);
            h.str("/blob/v");
            h.str(project.version);
            h.str("/");
            h.str(mod.source_file);
            h.fmt("#L{d})\n\n", .{func.source_line});
        }
    }

    h.str("---\n\n");
}

// ============================================================
// Sidebar
// ============================================================

fn appendSidebar(h: *StringBuffer, project: DocProject, current_struct: ?[]const u8, options: DocOptions, base: []const u8) void {
    h.str("<nav class=\"sidebar\">\n");
    h.str("<div class=\"sidebar-header\"><a href=\"");
    h.str(base);
    h.str("index.html\" class=\"sidebar-title\">");
    h.str(project.name);
    h.str("</a> <span class=\"sidebar-version\">v");
    h.str(project.version);
    h.str("</span></div>\n");
    h.str("<div class=\"sidebar-search\"><input type=\"text\" id=\"search-input\" placeholder=\"Search (Cmd+K)\" aria-label=\"Search documentation\"></div>\n");

    appendSidebarDeclarationGroups(h, project, current_struct, base);

    // Doc groups (guides)
    for (options.doc_groups) |group| {
        h.str("<div class=\"sidebar-group\">\n<h4>");
        appendHtmlEscaped(h, group.name);
        h.str("</h4>\n<ul>\n");
        for (group.pages) |page| {
            const basename = std.fs.path.basename(page);
            const stem = if (std.mem.endsWith(u8, basename, ".md")) basename[0 .. basename.len - 3] else basename;
            h.str("<li><a href=\"");
            h.str(base);
            h.str("guides/");
            h.str(stem);
            h.str(".html\">");
            appendTitleCase(h, stem);
            h.str("</a></li>\n");
        }
        h.str("</ul>\n</div>\n");
    }

    h.str("</nav>\n");
}

fn appendSidebarDeclarationGroups(h: *StringBuffer, project: DocProject, current_struct: ?[]const u8, base: []const u8) void {
    appendSidebarDeclarationGroup(h, project, current_struct, base, .@"struct", "Structs");
    appendSidebarDeclarationGroup(h, project, current_struct, base, .protocol, "Protocols");
    appendSidebarDeclarationGroup(h, project, current_struct, base, .@"union", "Unions");
}

fn appendSidebarDeclarationGroup(
    h: *StringBuffer,
    project: DocProject,
    current_struct: ?[]const u8,
    base: []const u8,
    kind: DocKind,
    title: []const u8,
) void {
    var has_declarations = false;
    for (project.structs) |mod| {
        if (mod.kind == kind) {
            has_declarations = true;
            break;
        }
    }
    if (!has_declarations) return;

    h.str("<div class=\"sidebar-group\">\n<h4>");
    h.str(title);
    h.str("</h4>\n<ul>\n");
    for (project.structs) |mod| {
        if (mod.kind == kind) appendSidebarDeclaration(h, mod, current_struct, base);
    }
    h.str("</ul>\n</div>\n");
}

fn appendSidebarDeclaration(h: *StringBuffer, mod: DocStruct, current_struct: ?[]const u8, base: []const u8) void {
    const is_current = if (current_struct) |cm| std.mem.eql(u8, cm, mod.name) else false;
    if (is_current) {
        h.str("<li class=\"active\">");
    } else {
        h.str("<li>");
    }
    h.str("<a href=\"");
    h.str(base);
    h.str("structs/");
    h.str(mod.name);
    h.str(".html\">");
    appendHtmlEscaped(h, mod.name);
    h.str("</a></li>\n");
}

// ============================================================
// Search index
// ============================================================

fn generateSearchIndex(alloc: std.mem.Allocator, project: DocProject, options: DocOptions) !void {
    var h = StringBuffer.init(alloc);
    h.str("[\n");

    var first = true;
    for (project.structs) |mod| {
        if (!first) h.str(",\n");
        first = false;

        h.str("  {\"struct\":\"");
        appendJsonEscaped(&h, mod.name);
        h.str("\",\"type\":\"");
        h.str(docKindSearchType(mod.kind));
        h.str("\",\"name\":\"");
        appendJsonEscaped(&h, mod.name);
        h.str("\",\"summary\":\"");
        const mod_summary = extractFirstSentence(alloc, mod.structdoc);
        appendJsonEscaped(&h, mod_summary);
        h.str("\",\"url\":\"structs/");
        appendJsonEscaped(&h, mod.name);
        h.str(".html\"}");

        for (mod.functions) |func| {
            h.str(",\n  {\"struct\":\"");
            appendJsonEscaped(&h, mod.name);
            h.str("\",\"type\":\"");
            if (func.is_macro) h.str("macro") else h.str("function");
            h.str("\",\"name\":\"");
            appendJsonEscaped(&h, func.name);
            h.fmt("/{d}", .{func.arity});
            h.str("\",\"summary\":\"");
            appendJsonEscaped(&h, func.summary);
            h.str("\",\"url\":\"structs/");
            appendJsonEscaped(&h, mod.name);
            h.str(".html#");
            appendJsonEscaped(&h, func.name);
            h.fmt("-{d}", .{func.arity});
            h.str("\"}");
        }
    }

    h.str("\n]\n");

    const path = try std.fmt.allocPrint(alloc, "{s}/search-index.json", .{options.output_dir});
    try writeFile(path, h.toSlice());
}

// ============================================================
// Doc group pages
// ============================================================

fn generateDocGroupPage(alloc: std.mem.Allocator, page_path: []const u8, project: DocProject, options: DocOptions) !void {
    const full_path = try std.fs.path.join(alloc, &.{ options.project_root, page_path });
    const content = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, full_path, alloc, .limited(1024 * 1024)) catch return;

    const basename = std.fs.path.basename(page_path);
    const stem = if (std.mem.endsWith(u8, basename, ".md")) basename[0 .. basename.len - 3] else basename;

    var h = StringBuffer.init(alloc);
    appendPageHeader(&h, stem, project, "../");
    h.str("<div class=\"layout\">\n");
    appendSidebar(&h, project, null, options, "../");
    h.str("<main class=\"content\"><div class=\"structdoc\">\n");
    appendMarkdownAsHtml(&h, content);
    h.str("</div></main>\n</div>\n");
    appendPageFooter(&h, "../");

    const guides_dir = try std.fmt.allocPrint(alloc, "{s}/guides", .{options.output_dir});
    std.Io.Dir.cwd().createDirPath(std.Options.debug_io, guides_dir) catch {};

    const path = try std.fmt.allocPrint(alloc, "{s}/guides/{s}.html", .{ options.output_dir, stem });
    try writeFile(path, h.toSlice());
}

// ============================================================
// Page wrapper
// ============================================================

fn appendPageHeader(h: *StringBuffer, title: []const u8, project: DocProject, base: []const u8) void {
    h.str("<!DOCTYPE html>\n<html lang=\"en\" data-theme=\"light\">\n<head>\n");
    h.str("<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    h.str("<title>");
    appendHtmlEscaped(h, title);
    h.str(" \u{2014} ");
    appendHtmlEscaped(h, project.name);
    h.str("</title>\n<link rel=\"stylesheet\" href=\"");
    h.str(base);
    h.str("style.css\">\n<meta name=\"zap-docs-base\" content=\"");
    h.str(base);
    h.str("\">\n</head>\n<body>\n");
    h.str("<header class=\"topbar\">\n<div class=\"topbar-left\">\n");
    h.str("<svg class=\"zap-mark\" width=\"22\" height=\"22\" viewBox=\"0 0 22 22\" fill=\"none\">\n");
    h.str("<rect x=\"0.5\" y=\"0.5\" width=\"21\" height=\"21\" rx=\"3\" stroke=\"var(--border-strong)\"/>\n");
    h.str("<path d=\"M6 6 L15 6 L8 13 L16 13 L16 16 L6 16 L13 9 L6 9 Z\" fill=\"var(--accent)\"/>\n");
    h.str("</svg>\n");
    h.str("<a href=\"");
    h.str(base);
    h.str("index.html\" class=\"topbar-title\">");
    appendHtmlEscaped(h, project.name);
    h.str("</a>\n<span class=\"topbar-version\">v");
    h.str(project.version);
    h.str("</span>\n<span class=\"docs-label\">docs</span>\n");
    h.str("</div>\n");
    h.str("<div class=\"topbar-center\">\n");
    h.str("<button class=\"topbar-search-trigger\" id=\"search-trigger\">\n");
    h.str("<svg width=\"14\" height=\"14\" viewBox=\"0 0 16 16\" fill=\"none\">\n");
    h.str("<circle cx=\"7\" cy=\"7\" r=\"5\" stroke=\"var(--fg-muted)\" stroke-width=\"1.3\"/>\n");
    h.str("<line x1=\"10.6\" y1=\"10.6\" x2=\"14\" y2=\"14\" stroke=\"var(--fg-muted)\" stroke-width=\"1.3\" stroke-linecap=\"round\"/>\n");
    h.str("</svg>\n");
    h.str("<span>Search structs, functions, guides...</span>\n");
    h.str("<kbd>\u{2318}</kbd><kbd>K</kbd>\n");
    h.str("</button>\n");
    h.str("</div>\n");
    h.str("<div class=\"topbar-right\">\n");
    h.str("<button id=\"theme-toggle\" aria-label=\"Toggle dark mode\" title=\"Toggle dark mode\">\n");
    h.str("<span class=\"theme-icon-light\">\u{2600}</span>\n");
    h.str("<span class=\"theme-icon-dark\">\u{263e}</span>\n");
    h.str("</button>\n");
    h.str("<div class=\"topbar-divider\"></div>\n");
    if (project.source_url) |source_url| {
        h.str("<a href=\"");
        h.str(source_url);
        h.str("\" class=\"topbar-github\" aria-label=\"GitHub repository\" title=\"GitHub\">\n");
        h.str("<svg width=\"18\" height=\"18\" viewBox=\"0 0 16 16\" fill=\"currentColor\">\n");
        h.str("<path d=\"M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z\"/>\n");
        h.str("</svg>\n");
        h.str("</a>\n");
    }
    h.str("</div>\n</header>\n");
}

fn appendPageFooter(h: *StringBuffer, base: []const u8) void {
    h.str("<div id=\"search-modal\" class=\"search-modal\" hidden>\n");
    h.str("<div class=\"search-backdrop\"></div>\n");
    h.str("<div class=\"search-dialog\">\n");
    h.str("<input type=\"text\" id=\"search-modal-input\" placeholder=\"Search documentation...\" aria-label=\"Search\">\n");
    h.str("<ul id=\"search-results\" class=\"search-results\"></ul>\n");
    h.str("</div>\n</div>\n");
    h.str("<script src=\"");
    h.str(base);
    h.str("app.js\"></script>\n</body>\n</html>\n");
}

// ============================================================
// Simple Markdown to HTML renderer
// ============================================================

fn appendMarkdownAsHtml(h: *StringBuffer, markdown: []const u8) void {
    var lines = std.mem.splitSequence(u8, markdown, "\n");
    var in_code_block = false;
    var in_list = false;
    var in_paragraph = false;
    var code_block_buf = StringBuffer.init(h.alloc);
    var code_block_lang: []const u8 = "";
    var pending_line: ?[]const u8 = null;

    while (true) {
        const line = if (pending_line) |queued_line| blk: {
            pending_line = null;
            break :blk queued_line;
        } else lines.next() orelse break;
        const trimmed = std.mem.trimStart(u8, line, " \t");

        // Fenced code blocks — collect content, then highlight
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (in_code_block) {
                // End of fenced block — render collected content
                if (isZapLang(code_block_lang)) {
                    h.str("<pre><code class=\"language-zap\">");
                    appendHighlightedZap(h, code_block_buf.toSlice());
                } else if (code_block_lang.len > 0) {
                    h.str("<pre><code class=\"language-");
                    h.str(code_block_lang);
                    h.str("\">");
                    appendHtmlEscaped(h, code_block_buf.toSlice());
                } else {
                    h.str("<pre><code>");
                    appendHtmlEscaped(h, code_block_buf.toSlice());
                }
                h.str("</code></pre>\n");
                in_code_block = false;
                code_block_buf.list.clearRetainingCapacity();
            } else {
                if (in_paragraph) {
                    h.str("</p>\n");
                    in_paragraph = false;
                }
                if (in_list) {
                    h.str("</ul>\n");
                    in_list = false;
                }
                code_block_lang = std.mem.trimStart(u8, trimmed[3..], " ");
                in_code_block = true;
                code_block_buf.list.clearRetainingCapacity();
            }
            continue;
        }

        if (in_code_block) {
            if (code_block_buf.list.items.len > 0) code_block_buf.char('\n');
            code_block_buf.str(line);
            continue;
        }

        if (trimmed.len == 0) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            if (in_list) {
                h.str("</ul>\n");
                in_list = false;
            }
            continue;
        }

        // Headings
        if (std.mem.startsWith(u8, trimmed, "#### ")) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            h.str("<h4>");
            appendInlineMarkdown(h, trimmed[5..]);
            h.str("</h4>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "### ")) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            h.str("<h3>");
            appendInlineMarkdown(h, trimmed[4..]);
            h.str("</h3>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "## ")) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            h.str("<h2>");
            appendInlineMarkdown(h, trimmed[3..]);
            h.str("</h2>\n");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "# ")) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            h.str("<h1>");
            appendInlineMarkdown(h, trimmed[2..]);
            h.str("</h1>\n");
            continue;
        }

        // Horizontal rule
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            h.str("<hr>\n");
            continue;
        }

        // Unordered list
        if (trimmed.len > 2 and (trimmed[0] == '-' or trimmed[0] == '*') and trimmed[1] == ' ') {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            if (!in_list) {
                h.str("<ul>\n");
                in_list = true;
            }
            h.str("<li>");
            appendInlineMarkdown(h, trimmed[2..]);
            h.str("</li>\n");
            continue;
        }

        // Blockquote
        if (std.mem.startsWith(u8, trimmed, "> ")) {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            h.str("<blockquote><p>");
            appendInlineMarkdown(h, trimmed[2..]);
            h.str("</p></blockquote>\n");
            continue;
        }

        // Pipe tables
        if (isMarkdownTableRow(trimmed)) {
            if (lines.next()) |separator_line| {
                const trimmed_separator = std.mem.trimStart(u8, separator_line, " \t");
                const header_cell_count = markdownTableCellCount(trimmed);
                if (header_cell_count > 0 and isMarkdownTableSeparator(trimmed_separator, header_cell_count)) {
                    if (in_paragraph) {
                        h.str("</p>\n");
                        in_paragraph = false;
                    }
                    if (in_list) {
                        h.str("</ul>\n");
                        in_list = false;
                    }

                    h.str("<table class=\"markdown-table\">\n<thead>\n<tr>");
                    appendMarkdownTableRow(h, trimmed, "th");
                    h.str("</tr>\n</thead>\n<tbody>\n");

                    while (lines.next()) |table_line| {
                        const trimmed_table_line = std.mem.trimStart(u8, table_line, " \t");
                        if (trimmed_table_line.len == 0) break;
                        if (!isMarkdownTableRow(trimmed_table_line)) {
                            pending_line = table_line;
                            break;
                        }
                        if (isMarkdownTableSeparator(trimmed_table_line, header_cell_count)) break;

                        h.str("<tr>");
                        appendMarkdownTableRow(h, trimmed_table_line, "td");
                        h.str("</tr>\n");
                    }

                    h.str("</tbody>\n</table>\n");
                    continue;
                }
                pending_line = separator_line;
            }
        }

        // Raw HTML passthrough — lines starting with < are passed through verbatim
        if (trimmed.len > 0 and trimmed[0] == '<') {
            if (in_paragraph) {
                h.str("</p>\n");
                in_paragraph = false;
            }
            if (in_list) {
                h.str("</ul>\n");
                in_list = false;
            }
            h.str(line);
            h.char('\n');
            continue;
        }

        // Indented code block (4 spaces)
        if (line.len >= 4 and std.mem.eql(u8, line[0..4], "    ") and !in_paragraph) {
            // Collect all indented lines into a buffer
            code_block_buf.list.clearRetainingCapacity();
            code_block_buf.str(line[4..]);
            while (lines.next()) |next_line| {
                if (next_line.len >= 4 and std.mem.eql(u8, next_line[0..4], "    ")) {
                    code_block_buf.char('\n');
                    code_block_buf.str(next_line[4..]);
                } else if (std.mem.trimStart(u8, next_line, " \t").len == 0) {
                    code_block_buf.char('\n');
                } else {
                    pending_line = next_line;
                    break;
                }
            }
            h.str("<pre><code class=\"language-zap\">");
            appendHighlightedZap(h, code_block_buf.toSlice());
            h.str("</code></pre>\n");
            continue;
        }

        // Paragraph text
        if (!in_paragraph) {
            h.str("<p>");
            in_paragraph = true;
        } else {
            h.char('\n');
        }
        appendInlineMarkdown(h, trimmed);
    }

    if (in_paragraph) h.str("</p>\n");
    if (in_list) h.str("</ul>\n");
    if (in_code_block) h.str("</code></pre>\n");
}

fn markdownTableCellCount(row: []const u8) usize {
    const trimmed = normalizeMarkdownTableRow(row);
    if (trimmed.len == 0) return 0;

    var count: usize = 0;
    var raw_cells = std.mem.splitScalar(u8, trimmed, '|');
    while (raw_cells.next()) |_| {
        count += 1;
    }
    return count;
}

fn isMarkdownTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;
    return std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn isMarkdownTableSeparator(line: []const u8, expected_cell_count: usize) bool {
    const trimmed = normalizeMarkdownTableRow(line);
    if (trimmed.len == 0) return false;
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) return false;

    var valid_cells: usize = 0;
    var raw_cells = std.mem.splitScalar(u8, trimmed, '|');
    while (raw_cells.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        if (cell.len == 0) return false;
        if (!isMarkdownTableSeparatorCell(cell)) return false;
        valid_cells += 1;
    }

    return valid_cells == expected_cell_count;
}

fn isMarkdownTableSeparatorCell(cell: []const u8) bool {
    var start: usize = 0;
    var end = cell.len;
    if (start < end and cell[start] == ':') start += 1;
    if (start < end and cell[end - 1] == ':') end -= 1;
    if (end <= start) return false;

    var dash_count: usize = 0;
    for (cell[start..end]) |char| {
        if (char != '-') return false;
        dash_count += 1;
    }
    return dash_count >= 3;
}

fn appendMarkdownTableRow(h: *StringBuffer, row: []const u8, tag: []const u8) void {
    const trimmed = normalizeMarkdownTableRow(row);
    var raw_cells = std.mem.splitScalar(u8, trimmed, '|');

    while (raw_cells.next()) |raw_cell| {
        const cell = std.mem.trim(u8, raw_cell, " \t");
        h.char('<');
        h.str(tag);
        h.char('>');
        appendInlineMarkdown(h, cell);
        h.str("</");
        h.str(tag);
        h.char('>');
    }
}

fn normalizeMarkdownTableRow(row: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, row, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];
    return trimmed;
}

fn appendInlineMarkdown(h: *StringBuffer, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (c == '`') {
            const end = std.mem.indexOfPos(u8, text, i + 1, "`") orelse {
                h.char('`');
                i += 1;
                continue;
            };
            h.str("<code>");
            appendHtmlEscaped(h, text[i + 1 .. end]);
            h.str("</code>");
            i = end + 1;
            continue;
        }
        if (c == '*' and i + 1 < text.len and text[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 2, "**") orelse {
                h.str("**");
                i += 2;
                continue;
            };
            h.str("<strong>");
            appendHtmlEscaped(h, text[i + 2 .. end]);
            h.str("</strong>");
            i = end + 2;
            continue;
        }
        if (c == '*') {
            const end = std.mem.indexOfPos(u8, text, i + 1, "*") orelse {
                h.char('*');
                i += 1;
                continue;
            };
            h.str("<em>");
            appendHtmlEscaped(h, text[i + 1 .. end]);
            h.str("</em>");
            i = end + 1;
            continue;
        }
        if (c == '[') {
            const cb = std.mem.indexOfPos(u8, text, i + 1, "]") orelse {
                appendHtmlEscapedByte(h, c);
                i += 1;
                continue;
            };
            if (cb + 1 < text.len and text[cb + 1] == '(') {
                const cp = std.mem.indexOfPos(u8, text, cb + 2, ")") orelse {
                    appendHtmlEscapedByte(h, c);
                    i += 1;
                    continue;
                };
                h.str("<a href=\"");
                appendHtmlEscaped(h, text[cb + 2 .. cp]);
                h.str("\">");
                appendHtmlEscaped(h, text[i + 1 .. cb]);
                h.str("</a>");
                i = cp + 1;
                continue;
            }
        }
        if (c == '\\' and i + 1 < text.len) {
            appendHtmlEscapedByte(h, text[i + 1]);
            i += 2;
            continue;
        }

        // HTML entities — pass through &...; verbatim
        if (c == '&') {
            if (std.mem.indexOfPos(u8, text, i + 1, ";")) |semi| {
                if (semi - i <= 10) {
                    // Looks like an entity — pass through as-is
                    h.str(text[i .. semi + 1]);
                    i = semi + 1;
                    continue;
                }
            }
            h.str("&amp;");
            i += 1;
            continue;
        }

        appendHtmlEscapedByte(h, c);
        i += 1;
    }
}

// ============================================================
// Zap Syntax Highlighting
// ============================================================

fn appendHighlightedZap(h: *StringBuffer, code: []const u8) void {
    var i: usize = 0;
    while (i < code.len) {
        const c = code[i];

        // Comments: # to end of line
        if (c == '#') {
            h.str("<span class=\"hl-comment\">");
            while (i < code.len and code[i] != '\n') {
                appendHtmlEscapedByte(h, code[i]);
                i += 1;
            }
            h.str("</span>");
            continue;
        }

        // Strings: "..."
        if (c == '"') {
            h.str("<span class=\"hl-string\">");
            h.char('"');
            i += 1;
            // Check for heredoc """
            if (i + 1 < code.len and code[i] == '"' and code[i + 1] == '"') {
                h.str("\"\"");
                i += 2;
                // Read until closing """
                while (i + 2 < code.len) {
                    if (code[i] == '"' and code[i + 1] == '"' and code[i + 2] == '"') {
                        h.str("\"\"\"");
                        i += 3;
                        break;
                    }
                    appendHtmlEscapedByte(h, code[i]);
                    i += 1;
                }
            } else {
                while (i < code.len and code[i] != '"' and code[i] != '\n') {
                    if (code[i] == '\\' and i + 1 < code.len) {
                        appendHtmlEscapedByte(h, code[i]);
                        appendHtmlEscapedByte(h, code[i + 1]);
                        i += 2;
                    } else {
                        appendHtmlEscapedByte(h, code[i]);
                        i += 1;
                    }
                }
                if (i < code.len and code[i] == '"') {
                    h.char('"');
                    i += 1;
                }
            }
            h.str("</span>");
            continue;
        }

        // Atoms: :name (lowercase or underscore start only)
        if (c == ':' and i + 1 < code.len and ((code[i + 1] >= 'a' and code[i + 1] <= 'z') or code[i + 1] == '_')) {
            h.str("<span class=\"hl-atom\">");
            h.char(':');
            i += 1;
            while (i < code.len and (isAlphaNum(code[i]) or code[i] == '_' or code[i] == '?' or code[i] == '!')) {
                h.char(code[i]);
                i += 1;
            }
            h.str("</span>");
            continue;
        }

        // Numbers
        if (isDigit(c) or (c == '-' and i + 1 < code.len and isDigit(code[i + 1]))) {
            // Only treat '-' as number start if preceded by space/operator/start
            if (c == '-') {
                if (i > 0 and (isAlphaNum(code[i - 1]) or code[i - 1] == ')' or code[i - 1] == '_')) {
                    // This is a minus operator, not a negative number
                    h.str("<span class=\"hl-op\">-</span>");
                    i += 1;
                    continue;
                }
            }
            h.str("<span class=\"hl-number\">");
            while (i < code.len and (isDigit(code[i]) or code[i] == '.' or code[i] == '_' or code[i] == '-')) {
                h.char(code[i]);
                i += 1;
            }
            h.str("</span>");
            continue;
        }

        // Identifiers and keywords
        if (isAlpha(c) or c == '_') {
            const start = i;
            while (i < code.len and (isAlphaNum(code[i]) or code[i] == '_' or code[i] == '?' or code[i] == '!')) {
                i += 1;
            }
            const word = code[start..i];

            if (isKeyword(word)) {
                h.str("<span class=\"hl-keyword\">");
                h.str(word);
                h.str("</span>");
            } else if (isBuiltin(word)) {
                h.str("<span class=\"hl-builtin\">");
                h.str(word);
                h.str("</span>");
            } else if (isPrimitiveType(word)) {
                h.str("<span class=\"hl-type\">");
                h.str(word);
                h.str("</span>");
            } else {
                h.str(word);
            }
            continue;
        }

        // Operators
        if (i + 1 < code.len) {
            const two = code[i .. i + 2];
            if (std.mem.eql(u8, two, "->") or std.mem.eql(u8, two, "::") or
                std.mem.eql(u8, two, "|>") or std.mem.eql(u8, two, "~>") or
                std.mem.eql(u8, two, "<>") or std.mem.eql(u8, two, "<-") or
                std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "!=") or
                std.mem.eql(u8, two, ">=") or std.mem.eql(u8, two, "<="))
            {
                h.str("<span class=\"hl-op\">");
                appendHtmlEscapedByte(h, code[i]);
                appendHtmlEscapedByte(h, code[i + 1]);
                h.str("</span>");
                i += 2;
                continue;
            }
        }
        if (c == '=' or c == '+' or c == '*' or c == '/' or c == '>' or c == '<' or c == '|') {
            h.str("<span class=\"hl-op\">");
            appendHtmlEscapedByte(h, c);
            h.str("</span>");
            i += 1;
            continue;
        }

        // Everything else (whitespace, braces, parens, etc.)
        appendHtmlEscapedByte(h, c);
        i += 1;
    }
}

fn isZapLang(lang: []const u8) bool {
    return lang.len == 0 or std.mem.eql(u8, lang, "zap") or std.mem.eql(u8, lang, "elixir");
}

fn isKeyword(word: []const u8) bool {
    const keywords = [_][]const u8{
        "pub",    "fn",      "macro",    "struct",  "case",
        "if",     "else",    "use",      "struct",  "union",
        "when",   "for",     "in",       "cond",    "do",
        "end",    "unless",  "and",      "or",      "not",
        "import", "alias",   "quote",    "unquote", "panic",
        "struct", "extends", "describe", "test",    "assert",
        "reject",
    };
    for (&keywords) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

fn isBuiltin(word: []const u8) bool {
    const builtins = [_][]const u8{
        "true",  "false",    "nil",
        "setup", "teardown",
    };
    for (&builtins) |b| {
        if (std.mem.eql(u8, word, b)) return true;
    }
    return false;
}

fn isPrimitiveType(word: []const u8) bool {
    const types = [_][]const u8{
        "i8",    "i16",   "i32",  "i64",    "i128",
        "u8",    "u16",   "u32",  "u64",    "u128",
        "f16",   "f32",   "f64",  "f80",    "f128",
        "usize", "isize", "Bool", "String", "Atom",
        "Nil",   "Never", "Expr",
    };
    for (&types) |t| {
        if (std.mem.eql(u8, word, t)) return true;
    }
    return false;
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlphaNum(c: u8) bool {
    return isAlpha(c) or isDigit(c);
}

// ============================================================
// Utility functions
// ============================================================

fn appendHtmlEscaped(h: *StringBuffer, text: []const u8) void {
    for (text) |c| appendHtmlEscapedByte(h, c);
}

fn appendHtmlEscapedByte(h: *StringBuffer, c: u8) void {
    switch (c) {
        '<' => h.str("&lt;"),
        '>' => h.str("&gt;"),
        '&' => h.str("&amp;"),
        '"' => h.str("&quot;"),
        else => h.char(c),
    }
}

fn appendJsonEscaped(h: *StringBuffer, text: []const u8) void {
    for (text) |c| {
        switch (c) {
            '"' => h.str("\\\""),
            '\\' => h.str("\\\\"),
            '\n' => h.str("\\n"),
            '\r' => h.str("\\r"),
            '\t' => h.str("\\t"),
            else => h.char(c),
        }
    }
}

fn appendAnchorId(h: *StringBuffer, func: DocFunction) void {
    h.str(func.name);
    h.fmt("-{d}", .{func.arity});
}

fn appendTitleCase(h: *StringBuffer, text: []const u8) void {
    var capitalize_next = true;
    for (text) |c| {
        if (c == '_' or c == '-') {
            h.char(' ');
            capitalize_next = true;
        } else if (capitalize_next and c >= 'a' and c <= 'z') {
            h.char(c - 32);
            capitalize_next = false;
        } else {
            h.char(c);
            capitalize_next = false;
        }
    }
}

fn generateScriptWithIndex(alloc: std.mem.Allocator, project: DocProject, options: DocOptions) !void {
    var h = StringBuffer.init(alloc);

    // Inline the search data as a JS variable
    h.str("var ZAP_SEARCH_DATA = ");
    appendSearchIndexJson(&h, project, alloc);
    h.str(";\n");

    // Append the rest of the JS
    h.str(js_content);

    const path = try std.fmt.allocPrint(alloc, "{s}/app.js", .{options.output_dir});
    try writeFile(path, h.toSlice());
}

fn appendSearchIndexJson(h: *StringBuffer, project: DocProject, alloc: std.mem.Allocator) void {
    h.str("[\n");
    var first = true;
    for (project.structs) |mod| {
        if (!first) h.str(",\n");
        first = false;

        h.str("{\"struct\":\"");
        appendJsonEscaped(h, mod.name);
        h.str("\",\"type\":\"");
        h.str(docKindSearchType(mod.kind));
        h.str("\",\"name\":\"");
        appendJsonEscaped(h, mod.name);
        h.str("\",\"summary\":\"");
        const mod_summary = extractFirstSentence(alloc, mod.structdoc);
        appendJsonEscaped(h, mod_summary);
        h.str("\",\"url\":\"structs/");
        appendJsonEscaped(h, mod.name);
        h.str(".html\"}");

        for (mod.functions) |func| {
            h.str(",\n{\"struct\":\"");
            appendJsonEscaped(h, mod.name);
            h.str("\",\"type\":\"");
            if (func.is_macro) h.str("macro") else h.str("function");
            h.str("\",\"name\":\"");
            appendJsonEscaped(h, func.name);
            h.fmt("/{d}", .{func.arity});
            h.str("\",\"summary\":\"");
            appendJsonEscaped(h, func.summary);
            h.str("\",\"url\":\"structs/");
            appendJsonEscaped(h, mod.name);
            h.str(".html#");
            appendJsonEscaped(h, func.name);
            h.fmt("-{d}", .{func.arity});
            h.str("\"}");
        }
    }
    h.str("\n]");
}

fn generateAsset(alloc: std.mem.Allocator, output_dir: []const u8, filename: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ output_dir, filename });
    try writeFile(path, content);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const io = std.Options.debug_io;
    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return error.WriteError;
    defer file.close(io);
    file.writeStreamingAll(io, content) catch return error.WriteError;
}

const WriteError = error{WriteError};

test "documentation signatures include every function clause pattern" {
    const source =
        \\pub struct Example {
        \\  pub fn classify(0 :: i64) -> String {
        \\    "zero"
        \\  }
        \\
        \\  pub fn classify(value :: i32) -> String {
        \\    "i32"
        \\  }
        \\
        \\  pub fn classify(value :: i64) -> String if value > 0 {
        \\    "positive"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();

    var parser = zap.Parser.initWithSharedInterner(alloc, source, &interner, 0);
    defer parser.deinit();
    const program = try parser.parseProgram();

    var collector = zap.Collector.init(alloc, &interner, null);
    defer collector.deinit();
    try collector.collectProgram(&program);

    const source_units = [_]compiler.SourceUnit{.{
        .file_path = "example.zap",
        .source = source,
    }};

    var classify_family: ?scope.FunctionFamily = null;
    for (collector.graph.families.items) |family| {
        if (std.mem.eql(u8, interner.get(family.name), "classify")) {
            classify_family = family;
            break;
        }
    }

    const family = classify_family orelse return error.TestExpectedEqual;
    const signatures = buildFunctionSignatures(alloc, family, &interner, &source_units);

    try std.testing.expectEqual(@as(usize, 3), signatures.len);
    try std.testing.expectEqualStrings("classify(0 :: i64) -> String", signatures[0]);
    try std.testing.expectEqualStrings("classify(value :: i32) -> String", signatures[1]);
    try std.testing.expectEqualStrings("classify(value :: i64) -> String if value > 0", signatures[2]);
}

test "function markdown renders many signatures with one doc body" {
    const signatures = [_][]const u8{
        "abs(value :: i8) -> i8",
        "abs(value :: i16) -> i16",
        "abs(value :: i64) -> i64",
    };
    const func = DocFunction{
        .name = "abs",
        .arity = 1,
        .signature = signatures[0],
        .signatures = &signatures,
        .doc = "Shared absolute-value documentation.",
        .summary = "Shared absolute-value documentation.",
        .source_line = 0,
        .is_macro = false,
    };
    const mod = DocStruct{
        .name = "Integer",
        .structdoc = "",
        .source_file = "",
        .functions = &.{func},
    };
    const project = DocProject{
        .name = "Zap",
        .version = "0.0.0",
        .source_url = null,
        .structs = &.{mod},
    };
    const options = DocOptions{
        .project_name = "Zap",
        .project_version = "0.0.0",
    };

    var buffer = StringBuffer.init(std.testing.allocator);
    appendFunctionMarkdown(&buffer, func, mod, project, options);

    const markdown = buffer.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, markdown, "pub fn abs(value :: i8) -> i8") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "pub fn abs(value :: i16) -> i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "pub fn abs(value :: i64) -> i64") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, markdown, "Shared absolute-value documentation."));
}

test "markdown renderer renders pipe tables" {
    var buffer = StringBuffer.init(std.testing.allocator);

    appendMarkdownAsHtml(&buffer,
        \\| Signed | Unsigned | Bits |
        \\|--------|----------|------|
        \\| `i8`   | `u8`     | 8    |
        \\| `i16`  | `u16`    | 16   |
    );

    const html = buffer.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, html, "<table class=\"markdown-table\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th>Signed</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<th>Unsigned</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<td><code>i8</code></td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<td><code>u16</code></td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>| Signed") == null);
}

test "markdown renderer preserves non-table pipe paragraphs" {
    var buffer = StringBuffer.init(std.testing.allocator);

    appendMarkdownAsHtml(&buffer,
        \\A paragraph with a | pipe.
        \\The next line should remain in the same paragraph.
    );

    const html = buffer.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, html, "A paragraph with a | pipe.") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "The next line should remain in the same paragraph.") != null);
}

test "markdown renderer keeps paragraph after table" {
    var buffer = StringBuffer.init(std.testing.allocator);

    appendMarkdownAsHtml(&buffer,
        \\| Name | Type |
        \\|------|------|
        \\| min  | i64  |
        \\Next paragraph.
    );

    const html = buffer.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, html, "<td>min</td><td>i64</td>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>Next paragraph.</p>") != null);
}

test "sidebar groups declarations by kind with structs first" {
    const declarations = [_]DocStruct{
        .{
            .name = "Arithmetic",
            .kind = .protocol,
            .structdoc = "",
            .source_file = "",
            .functions = &.{},
        },
        .{
            .name = "IO.Mode",
            .kind = .@"union",
            .structdoc = "",
            .source_file = "",
            .functions = &.{},
        },
        .{
            .name = "IO",
            .kind = .@"struct",
            .structdoc = "",
            .source_file = "",
            .functions = &.{},
        },
        .{
            .name = "Zest.Case",
            .kind = .@"struct",
            .structdoc = "",
            .source_file = "",
            .functions = &.{},
        },
        .{
            .name = "Zest",
            .kind = .@"struct",
            .structdoc = "",
            .source_file = "",
            .functions = &.{},
        },
    };
    const project = DocProject{
        .name = "Zap",
        .version = "0.0.0",
        .source_url = null,
        .structs = &declarations,
    };
    const options = DocOptions{
        .project_name = "Zap",
        .project_version = "0.0.0",
    };

    var buffer = StringBuffer.init(std.testing.allocator);
    appendSidebar(&buffer, project, "IO.Mode", options, "");

    const html = buffer.toSlice();
    try std.testing.expect(std.mem.indexOf(u8, html, "<h4>Declarations</h4>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h4>IO</h4>") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h4>Arithmetic</h4>") == null);

    const structs_group = std.mem.indexOf(u8, html, "<h4>Structs</h4>") orelse return error.TestExpectedEqual;
    const protocols_group = std.mem.indexOf(u8, html, "<h4>Protocols</h4>") orelse return error.TestExpectedEqual;
    const unions_group = std.mem.indexOf(u8, html, "<h4>Unions</h4>") orelse return error.TestExpectedEqual;
    try std.testing.expect(structs_group < protocols_group);
    try std.testing.expect(protocols_group < unions_group);

    const io_struct = std.mem.indexOf(u8, html[structs_group..protocols_group], "structs/IO.html\">IO</a>") orelse return error.TestExpectedEqual;
    const zest_case_struct = std.mem.indexOf(u8, html[structs_group..protocols_group], "structs/Zest.Case.html\">Zest.Case</a>") orelse return error.TestExpectedEqual;
    _ = std.mem.indexOf(u8, html[protocols_group..unions_group], "structs/Arithmetic.html\">Arithmetic</a>") orelse return error.TestExpectedEqual;
    _ = std.mem.indexOf(u8, html[unions_group..], "structs/IO.Mode.html\">IO.Mode</a>") orelse return error.TestExpectedEqual;
    try std.testing.expect(io_struct < zest_case_struct);

    try std.testing.expect(std.mem.indexOf(u8, html, "<li class=\"active\"><a href=\"structs/IO.Mode.html\">IO.Mode</a></li>") != null);
}

test "signature renderer preserves nested patterns and separates guards" {
    const params = "%{status => :ok, value => value} :: Map, <<part :: i8, rest>> :: Binary";
    var param_parts = splitParams(params);

    const first = param_parts.next() orelse return error.TestExpectedEqual;
    const second = param_parts.next() orelse return error.TestExpectedEqual;
    try std.testing.expect(param_parts.next() == null);
    try std.testing.expectEqualStrings("%{status => :ok, value => value} :: Map", std.mem.trim(u8, first, " \t"));
    try std.testing.expectEqualStrings("<<part :: i8, rest>> :: Binary", std.mem.trim(u8, second, " \t"));

    try std.testing.expectEqual(
        std.mem.lastIndexOf(u8, second, " :: ").?,
        indexOfTopLevelToken(second, " :: ").?,
    );

    var buffer = StringBuffer.init(std.testing.allocator);
    appendRichSignature(&buffer, "classify(value :: i64) -> String if value > 0");
    const html = buffer.toSlice();

    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"sig-ret-pill\">String</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"sig-guard-keyword\">if</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<span class=\"sig-guard\">value &gt; 0</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "String if value") == null);
}

// ============================================================
// Embedded CSS
// ============================================================

const css_content = @embedFile("doc_assets/style.css");

// ============================================================
// Embedded JS
// ============================================================

const js_content = @embedFile("doc_assets/app.js");
