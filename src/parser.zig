const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Token = @import("token.zig").Token;
const ast = @import("ast.zig");
const similarity = @import("similarity.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    previous: Token,
    source: []const u8,
    interner: ast.StringInterner,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
        label: ?[]const u8 = null,
        help: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = first,
            .previous = first,
            .source = source,
            .interner = ast.StringInterner.init(allocator),
            .errors = .empty,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.interner.deinit();
        self.errors.deinit(self.allocator);
    }

    // ============================================================
    // Token consumption
    // ============================================================

    fn advance(self: *Parser) Token {
        self.previous = self.current;
        self.current = self.lexer.next();
        return self.previous;
    }

    fn peek(self: *const Parser) Token.Tag {
        return self.current.tag;
    }

    fn peekNext(self: *Parser) Token.Tag {
        // Peek at the token after current without consuming anything
        var lookahead = self.lexer;
        return lookahead.next().tag;
    }

    fn check(self: *const Parser, tag: Token.Tag) bool {
        return self.current.tag == tag;
    }

    fn match(self: *Parser, tag: Token.Tag) bool {
        if (self.check(tag)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: Token.Tag) !Token {
        if (self.check(tag)) {
            return self.advance();
        }
        try self.addError(
            std.fmt.allocPrint(self.allocator, "I was expecting {s} but found {s}", .{
                tokenHumanName(tag),
                tokenHumanName(self.current.tag),
            }) catch "parse error",
            ast.SourceSpan.from(self.current.loc),
        );
        return error.ParseError;
    }

    /// Like expect, but reports the error at `context_span` (where the construct began)
    /// instead of at the current token position.
    fn expectAt(self: *Parser, tag: Token.Tag, context_span: ast.SourceSpan) !Token {
        if (self.check(tag)) {
            return self.advance();
        }
        try self.addError(
            std.fmt.allocPrint(self.allocator, "I was expecting {s} but found {s}", .{
                tokenHumanName(tag),
                tokenHumanName(self.current.tag),
            }) catch "parse error",
            context_span,
        );
        return error.ParseError;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) {
            _ = self.advance();
        }
    }

    /// Skip newlines/indentation only if `target` token follows.
    /// Used for multiline continuations (e.g. `|>` on the next line).
    /// If the target isn't found, parser state is unchanged.
    fn skipNewlinesForContinuation(self: *Parser, target: Token.Tag) void {
        if (!self.check(.newline)) return;

        // Save parser + lexer state
        const saved_lexer = self.lexer;
        const saved_current = self.current;
        const saved_previous = self.previous;

        // Consume newlines and indentation tokens
        while (self.check(.newline) or self.check(.indent) or self.check(.dedent)) {
            _ = self.advance();
        }

        if (self.check(target)) {
            // Target found — keep the consumed state
            return;
        }

        // Target not found — restore state
        self.lexer = saved_lexer;
        self.current = saved_current;
        self.previous = saved_previous;
    }

    fn addError(self: *Parser, message: []const u8, span: ast.SourceSpan) !void {
        try self.errors.append(self.allocator, .{ .message = message, .span = span });
    }

    fn addRichError(self: *Parser, message: []const u8, span: ast.SourceSpan, label_text: ?[]const u8, help_text: ?[]const u8) !void {
        try self.errors.append(self.allocator, .{
            .message = message,
            .span = span,
            .label = label_text,
            .help = help_text,
        });
    }

    /// Skip tokens until a statement/definition boundary is found.
    /// Used for error recovery to find the next parseable construct.
    fn synchronize(self: *Parser) void {
        while (!self.check(.eof)) {
            switch (self.peek()) {
                .keyword_def, .keyword_defp, .keyword_defmodule, .keyword_defmacro, .keyword_defstruct, .keyword_defenum, .keyword_end => return,
                .newline => {
                    _ = self.advance();
                    // After newline, check if next token starts a new statement
                    self.skipNewlines();
                    switch (self.peek()) {
                        .keyword_def, .keyword_defp, .keyword_defmodule, .keyword_defmacro,
                        .keyword_defstruct, .keyword_defenum, .keyword_type, .keyword_opaque,
                        .keyword_alias, .keyword_import, .keyword_end, .eof,
                        => return,
                        else => {},
                    }
                },
                else => _ = self.advance(),
            }
        }
    }

    fn currentSpan(self: *const Parser) ast.SourceSpan {
        return ast.SourceSpan.from(self.current.loc);
    }

    fn previousSpan(self: *const Parser) ast.SourceSpan {
        return ast.SourceSpan.from(self.previous.loc);
    }

    fn internToken(self: *Parser, tok: Token) !ast.StringId {
        return self.interner.intern(tok.slice(self.source));
    }

    // ============================================================
    // Allocation helpers
    // ============================================================

    fn create(self: *Parser, comptime T: type, value: T) !*const T {
        const ptr = try self.allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    // ============================================================
    // Program parsing
    // ============================================================

    pub fn parseProgram(self: *Parser) !ast.Program {
        var modules: std.ArrayList(ast.ModuleDecl) = .empty;
        var top_items: std.ArrayList(ast.TopItem) = .empty;

        self.skipNewlines();

        while (!self.check(.eof)) {
            switch (self.peek()) {
                .keyword_defmodule => {
                    if (self.parseModuleDecl()) |mod| {
                        try modules.append(self.allocator, mod);
                        try top_items.append(self.allocator, .{ .module = try self.create(ast.ModuleDecl, mod) });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_def => {
                    if (self.parseFunctionDecl(.public)) |func| {
                        try top_items.append(self.allocator, .{ .function = func });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defp => {
                    if (self.parseFunctionDecl(.private)) |func| {
                        try top_items.append(self.allocator, .{ .priv_function = func });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_type => {
                    if (self.parseTypeDecl()) |td| {
                        try top_items.append(self.allocator, .{ .type_decl = td });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_opaque => {
                    if (self.parseOpaqueDecl()) |od| {
                        try top_items.append(self.allocator, .{ .opaque_decl = od });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defmacro => {
                    if (self.parseMacroDecl()) |mac| {
                        try top_items.append(self.allocator, .{ .macro = mac });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defstruct => {
                    if (self.parseTopLevelStructDecl()) |sd| {
                        try top_items.append(self.allocator, .{ .struct_decl = sd });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defenum => {
                    if (self.parseEnumDecl()) |ed| {
                        try top_items.append(self.allocator, .{ .enum_decl = ed });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .newline => {
                    _ = self.advance();
                },
                .dedent => {
                    _ = self.advance();
                },
                else => {
                    // Check for misspelled keywords
                    if (self.current.tag == .identifier) {
                        const text = self.current.slice(self.source);
                        const keywords = [_][]const u8{ "defmodule", "def", "defp", "defmacro", "defstruct", "defenum", "type", "opaque" };
                        if (similarity.findBestMatch(text, &keywords, 0.75)) |suggestion| {
                            try self.addRichError(
                                std.fmt.allocPrint(self.allocator, "I was not expecting `{s}` at the top level", .{text}) catch "unexpected identifier at top level",
                                self.currentSpan(),
                                null,
                                std.fmt.allocPrint(self.allocator, "did you mean `{s}`?", .{suggestion}) catch "check for typos",
                            );
                            _ = self.advance();
                            continue;
                        }
                    }
                    try self.addRichError(
                        std.fmt.allocPrint(self.allocator, "I was not expecting {s} at the top level", .{
                            tokenHumanName(self.current.tag),
                        }) catch "unexpected token at top level",
                        self.currentSpan(),
                        null,
                        "the top level can contain `defmodule`, `def`, `defp`, `defstruct`, `defenum`, `type`, and `opaque` declarations",
                    );
                    _ = self.advance();
                },
            }
        }

        // If we accumulated errors during recovery, report them
        if (self.errors.items.len > 0) {
            return error.ParseError;
        }

        return .{
            .modules = try modules.toOwnedSlice(self.allocator),
            .top_items = try top_items.toOwnedSlice(self.allocator),
        };
    }

    // ============================================================
    // Module declarations
    // ============================================================

    fn parseModuleDecl(self: *Parser) !ast.ModuleDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_defmodule);

        if (!self.check(.module_identifier)) {
            try self.addRichError(
                "I was expecting a module name (like `MyModule`) after `defmodule`",
                start,
                "module declaration starts here",
                "module names must start with an uppercase letter",
            );
            return error.ParseError;
        }
        const name = try self.parseModuleName();

        // Parse optional extends
        var parent: ?ast.StringId = null;
        if (self.match(.keyword_extends)) {
            const parent_tok = try self.expect(.module_identifier);
            parent = try self.internToken(parent_tok);
        }

        if (!self.check(.keyword_do)) {
            try self.addRichError(
                "I was expecting `do` to start the module body",
                start,
                "this module declaration needs a `do` ... `end` block",
                "add `do` after the module name",
            );
            return error.ParseError;
        }
        _ = self.advance();
        self.skipNewlines();

        _ = self.match(.indent);

        var items: std.ArrayList(ast.ModuleItem) = .empty;

        while (!self.check(.keyword_end) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.eof)) break;

            switch (self.peek()) {
                .keyword_def => {
                    if (self.parseFunctionDecl(.public)) |func| {
                        try items.append(self.allocator, .{ .function = func });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defp => {
                    if (self.parseFunctionDecl(.private)) |func| {
                        try items.append(self.allocator, .{ .priv_function = func });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defmacro => {
                    if (self.parseMacroDecl()) |mac| {
                        try items.append(self.allocator, .{ .macro = mac });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defstruct => {
                    if (self.parseStructDecl()) |sd| {
                        try items.append(self.allocator, .{ .struct_decl = sd });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_defenum => {
                    if (self.parseEnumDecl()) |ed| {
                        try items.append(self.allocator, .{ .enum_decl = ed });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_type => {
                    if (self.parseTypeDecl()) |td| {
                        try items.append(self.allocator, .{ .type_decl = td });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_opaque => {
                    if (self.parseOpaqueDecl()) |od| {
                        try items.append(self.allocator, .{ .opaque_decl = od });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_alias => {
                    if (self.parseAliasDecl()) |ad| {
                        try items.append(self.allocator, .{ .alias_decl = ad });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_import => {
                    if (self.parseImportDecl()) |id| {
                        try items.append(self.allocator, .{ .import_decl = id });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .dedent => {
                    _ = self.advance();
                },
                .newline => {
                    _ = self.advance();
                },
                else => {
                    try self.addRichError(
                        std.fmt.allocPrint(self.allocator, "I was not expecting {s} inside a module", .{
                            tokenHumanName(self.current.tag),
                        }) catch "unexpected token in module",
                        self.currentSpan(),
                        "not valid inside a module body",
                        "modules can contain `def`, `defp`, `defstruct`, `defenum`, `type`, `alias`, and `import` declarations",
                    );
                    _ = self.advance();
                },
            }
        }

        _ = self.match(.dedent);
        self.skipNewlines();
        if (!self.check(.keyword_end)) {
            try self.addRichError(
                "I was expecting `end` to close the module that starts here",
                start,
                "this module was opened here",
                "add `end` to close the module body",
            );
            return error.ParseError;
        }
        _ = self.advance();

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .parent = parent,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn parseModuleName(self: *Parser) !ast.ModuleName {
        const start = self.currentSpan();
        var parts: std.ArrayList(ast.StringId) = .empty;

        const first = try self.expect(.module_identifier);
        try parts.append(self.allocator, try self.internToken(first));

        while (self.check(.dot)) {
            // Peek past the dot — only consume if followed by another module_identifier
            const saved_lexer = self.lexer;
            const saved_current = self.current;
            const saved_previous = self.previous;
            _ = self.advance(); // consume dot
            if (self.check(.module_identifier)) {
                const part = self.advance();
                try parts.append(self.allocator, try self.internToken(part));
            } else {
                // Not a module name continuation — restore the dot
                self.lexer = saved_lexer;
                self.current = saved_current;
                self.previous = saved_previous;
                break;
            }
        }

        return .{
            .parts = try parts.toOwnedSlice(self.allocator),
            .span = ast.SourceSpan.merge(start, self.previousSpan()),
        };
    }

    // ============================================================
    // Type declarations
    // ============================================================

    fn parseTypeDecl(self: *Parser) !*const ast.TypeDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_type);

        const name_tok = try self.expectIdentifierOrModule();
        const name = try self.internToken(name_tok);

        const params = try self.parseOptionalTypeParams();

        _ = try self.expect(.equal);

        const body = try self.parseTypeExpr();

        return self.create(ast.TypeDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .params = params,
            .body = body,
        });
    }

    fn parseOpaqueDecl(self: *Parser) !*const ast.OpaqueDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_opaque);

        const name_tok = try self.expectIdentifierOrModule();
        const name = try self.internToken(name_tok);

        const params = try self.parseOptionalTypeParams();

        _ = try self.expect(.equal);

        const body = try self.parseTypeExpr();

        return self.create(ast.OpaqueDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .params = params,
            .body = body,
        });
    }

    fn parseOptionalTypeParams(self: *Parser) ![]const ast.TypeParam {
        if (!self.check(.left_paren)) return &[_]ast.TypeParam{};

        _ = self.advance();
        var params: std.ArrayList(ast.TypeParam) = .empty;

        while (!self.check(.right_paren) and !self.check(.eof)) {
            const param_tok = try self.expectIdentifierOrModule();
            try params.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.from(param_tok.loc) },
                .name = try self.internToken(param_tok),
            });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_paren);
        return params.toOwnedSlice(self.allocator);
    }

    // ============================================================
    // Struct declarations
    // ============================================================

    fn parseStructDecl(self: *Parser) !*const ast.StructDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_defstruct);
        _ = try self.expect(.keyword_do);
        self.skipNewlines();
        _ = self.match(.indent);

        var fields: std.ArrayList(ast.StructFieldDecl) = .empty;

        while (!self.check(.keyword_end) and !self.check(.dedent) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.dedent)) break;

            const field_tok = try self.expect(.identifier);
            const field_name = try self.internToken(field_tok);
            _ = try self.expect(.double_colon);
            const type_expr = try self.parseTypeExpr();

            var default: ?*const ast.Expr = null;
            if (self.match(.equal)) {
                default = try self.parseExpr();
            }

            try fields.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(field_tok.loc), self.previousSpan()) },
                .name = field_name,
                .type_expr = type_expr,
                .default = default,
            });

            self.skipNewlines();
        }

        _ = self.match(.dedent);
        self.skipNewlines();
        _ = try self.expect(.keyword_end);

        return self.create(ast.StructDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .fields = try fields.toOwnedSlice(self.allocator),
        });
    }

    fn parseTopLevelStructDecl(self: *Parser) !*const ast.StructDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_defstruct);

        // Parse name (required for top-level structs)
        const name_tok = try self.expect(.module_identifier);
        const name = try self.internToken(name_tok);

        // Parse optional extends
        var parent: ?ast.StringId = null;
        if (self.match(.keyword_extends)) {
            const parent_tok = try self.expect(.module_identifier);
            parent = try self.internToken(parent_tok);
        }

        _ = try self.expectAt(.keyword_do, start);
        self.skipNewlines();
        _ = self.match(.indent);

        var fields: std.ArrayList(ast.StructFieldDecl) = .empty;

        while (!self.check(.keyword_end) and !self.check(.dedent) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.dedent)) break;

            const field_tok = try self.expect(.identifier);
            const field_name = try self.internToken(field_tok);
            _ = try self.expect(.double_colon);
            const type_expr = try self.parseTypeExpr();

            var default: ?*const ast.Expr = null;
            if (self.match(.equal)) {
                default = try self.parseExpr();
            }

            try fields.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(field_tok.loc), self.previousSpan()) },
                .name = field_name,
                .type_expr = type_expr,
                .default = default,
            });

            self.skipNewlines();
        }

        _ = self.match(.dedent);
        self.skipNewlines();
        _ = try self.expectAt(.keyword_end, start);

        return self.create(ast.StructDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .parent = parent,
            .fields = try fields.toOwnedSlice(self.allocator),
        });
    }

    fn parseEnumDecl(self: *Parser) !*const ast.EnumDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_defenum);

        const name_tok = try self.expect(.module_identifier);
        const name = try self.internToken(name_tok);

        _ = try self.expectAt(.keyword_do, start);
        self.skipNewlines();
        _ = self.match(.indent);

        var variants: std.ArrayList(ast.EnumVariant) = .empty;

        while (!self.check(.keyword_end) and !self.check(.dedent) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.dedent)) break;

            const variant_tok = try self.expect(.module_identifier);
            const variant_name = try self.internToken(variant_tok);

            try variants.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.from(variant_tok.loc) },
                .name = variant_name,
            });

            self.skipNewlines();
        }

        _ = self.match(.dedent);
        self.skipNewlines();
        _ = try self.expectAt(.keyword_end, start);

        return self.create(ast.EnumDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .variants = try variants.toOwnedSlice(self.allocator),
        });
    }

    // ============================================================
    // Function declarations
    // ============================================================

    fn parseFunctionDecl(self: *Parser, visibility: ast.FunctionDecl.Visibility) !*const ast.FunctionDecl {
        const start = self.currentSpan();
        _ = self.advance(); // consume def/defp

        const name_tok = try self.expect(.identifier);
        const name = try self.internToken(name_tok);

        const clause = try self.parseFunctionClause(start);

        return self.create(ast.FunctionDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .clauses = try self.allocator.dupe(ast.FunctionClause, &[_]ast.FunctionClause{clause}),
            .visibility = visibility,
        });
    }

    fn parseMacroDecl(self: *Parser) !*const ast.FunctionDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_defmacro);

        // Allow keywords as macro names (like Elixir's Kernel macros: if, cond, with)
        const name_tok = if (self.check(.identifier))
            self.advance()
        else if (self.check(.keyword_if) or self.check(.keyword_cond) or self.check(.keyword_with))
            self.advance()
        else
            try self.expect(.identifier); // will error with expected message
        const name = try self.internToken(name_tok);

        const clause = try self.parseFunctionClause(start);

        return self.create(ast.FunctionDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .clauses = try self.allocator.dupe(ast.FunctionClause, &[_]ast.FunctionClause{clause}),
            .visibility = .public,
        });
    }

    fn parseFunctionClause(self: *Parser, def_span: ast.SourceSpan) !ast.FunctionClause {
        const start = self.currentSpan();

        if (!self.check(.left_paren)) {
            try self.addRichError(
                "I was expecting `(` to start the parameter list",
                def_span,
                "this function definition needs a parameter list",
                "add `()` after the function name, even if there are no parameters",
            );
            return error.ParseError;
        }
        _ = self.advance();
        const params = try self.parseParamList();
        if (!self.check(.right_paren)) {
            try self.addRichError(
                "this opening `(` was never closed",
                start,
                "opening `(` here",
                "add `)` to close the parameter list",
            );
            return error.ParseError;
        }
        _ = self.advance();

        var return_type: ?*const ast.TypeExpr = null;
        if (self.match(.double_colon)) {
            return_type = try self.parseTypeExpr();
        }

        var refinement: ?*const ast.Expr = null;
        if (self.match(.keyword_if)) {
            refinement = try self.parseExpr();
        }

        if (!self.check(.keyword_do)) {
            try self.addRichError(
                "I was expecting the `do` keyword to start the function body",
                def_span,
                "this function definition needs a `do` ... `end` block",
                "add `do` after the function signature",
            );
            return error.ParseError;
        }
        _ = self.advance();
        self.skipNewlines();
        _ = self.match(.indent);

        const body = try self.parseBlock();

        _ = self.match(.dedent);
        self.skipNewlines();
        if (!self.check(.keyword_end)) {
            try self.addRichError(
                "I was expecting `end` to close the function that starts here",
                def_span,
                "this function was opened here",
                "add `end` to close the function body",
            );
            return error.ParseError;
        }
        _ = self.advance();

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .params = params,
            .return_type = return_type,
            .refinement = refinement,
            .body = body,
        };
    }

    fn parseParamList(self: *Parser) ![]const ast.Param {
        if (self.check(.right_paren)) return &[_]ast.Param{};

        var params: std.ArrayList(ast.Param) = .empty;

        while (true) {
            const param = try self.parseParam();
            try params.append(self.allocator, param);
            if (!self.match(.comma)) break;
        }

        return params.toOwnedSlice(self.allocator);
    }

    fn parseParam(self: *Parser) !ast.Param {
        const start = self.currentSpan();
        const pattern = try self.parsePattern();

        var type_annotation: ?*const ast.TypeExpr = null;
        if (self.match(.double_colon)) {
            type_annotation = try self.parseTypeExpr();
        }

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .pattern = pattern,
            .type_annotation = type_annotation,
        };
    }

    // ============================================================
    // Alias and Import
    // ============================================================

    fn parseAliasDecl(self: *Parser) !*const ast.AliasDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_alias);

        const module_path = try self.parseModuleName();

        var as_name: ?ast.ModuleName = null;
        if (self.match(.comma)) {
            if (self.check(.keyword_as)) {
                _ = self.advance();
                _ = try self.expect(.colon);
                as_name = try self.parseModuleName();
            }
        }

        return self.create(ast.AliasDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .module_path = module_path,
            .as_name = as_name,
        });
    }

    fn parseImportDecl(self: *Parser) !*const ast.ImportDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_import);

        const module_path = try self.parseModuleName();

        var filter: ?ast.ImportFilter = null;
        if (self.match(.comma)) {
            filter = try self.parseImportFilter();
        }

        return self.create(ast.ImportDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .module_path = module_path,
            .filter = filter,
        });
    }

    fn parseImportFilter(self: *Parser) !ast.ImportFilter {
        if (self.match(.keyword_only)) {
            _ = try self.expect(.colon);
            const entries = try self.parseImportEntryList();
            return .{ .only = entries };
        }
        if (self.match(.keyword_except)) {
            _ = try self.expect(.colon);
            const entries = try self.parseImportEntryList();
            return .{ .except = entries };
        }
        try self.addRichError(
            "I was expecting `only:` or `except:` after the comma in this import",
            self.currentSpan(),
            null,
            "import filters look like: `import Foo, only: [bar: 1]`",
        );
        return error.ParseError;
    }

    fn parseImportEntryList(self: *Parser) ![]const ast.ImportEntry {
        _ = try self.expect(.left_bracket);
        var entries: std.ArrayList(ast.ImportEntry) = .empty;

        while (!self.check(.right_bracket) and !self.check(.eof)) {
            if (self.check(.keyword_type)) {
                _ = self.advance();
                _ = try self.expect(.colon);
                const type_tok = try self.expectIdentifierOrModule();
                try entries.append(self.allocator, .{ .type_import = try self.internToken(type_tok) });
            } else {
                const name_tok = try self.expect(.identifier);
                const name = try self.internToken(name_tok);
                _ = try self.expect(.colon);
                const arity_tok = try self.expect(.int_literal);
                const arity_str = arity_tok.slice(self.source);
                const arity = std.fmt.parseInt(u32, arity_str, 10) catch 0;
                try entries.append(self.allocator, .{ .function = .{ .name = name, .arity = arity } });
            }
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_bracket);
        return entries.toOwnedSlice(self.allocator);
    }

    // ============================================================
    // Blocks and statements
    // ============================================================

    fn parseBlock(self: *Parser) anyerror![]const ast.Stmt {
        var stmts: std.ArrayList(ast.Stmt) = .empty;

        while (!self.check(.keyword_end) and !self.check(.keyword_else) and
            !self.check(.dedent) and !self.check(.eof))
        {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.keyword_else) or
                self.check(.dedent) or self.check(.eof)) break;

            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);

            self.skipNewlines();
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseStmt(self: *Parser) !ast.Stmt {
        if (self.check(.keyword_def)) {
            const func = try self.parseFunctionDecl(.public);
            return .{ .function_decl = func };
        }
        if (self.check(.keyword_defp)) {
            const func = try self.parseFunctionDecl(.private);
            return .{ .function_decl = func };
        }
        if (self.check(.keyword_defmacro)) {
            const mac = try self.parseMacroDecl();
            return .{ .macro_decl = mac };
        }
        if (self.check(.keyword_import)) {
            const imp = try self.parseImportDecl();
            return .{ .import_decl = imp };
        }

        const expr = try self.parseExpr();

        if (self.check(.equal)) {
            _ = self.advance();
            const value = try self.parseExpr();
            const pattern = try self.exprToPattern(expr);
            return .{
                .assignment = try self.create(ast.Assignment, .{
                    .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, self.previousSpan()) },
                    .pattern = pattern,
                    .value = value,
                }),
            };
        }

        return .{ .expr = expr };
    }

    // ============================================================
    // Expression parsing (precedence climbing)
    // ============================================================

    pub fn parseExpr(self: *Parser) anyerror!*const ast.Expr {
        return self.parseOrExpr();
    }

    fn parseOrExpr(self: *Parser) !*const ast.Expr {
        var left = try self.parseAndExpr();

        if (self.check(.double_pipe)) {
            try self.addRichError(
                "Zap uses `or` for logical OR, not `||`",
                self.currentSpan(),
                "this operator is from C/JavaScript",
                "replace `||` with `or`",
            );
            return error.ParseError;
        }

        while (self.check(.keyword_or)) {
            _ = self.advance();
            const right = try self.parseAndExpr();
            left = try self.create(ast.Expr, .{
                .binary_op = .{
                    .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                    .op = .or_op,
                    .lhs = left,
                    .rhs = right,
                },
            });
        }

        return left;
    }

    fn parseAndExpr(self: *Parser) !*const ast.Expr {
        var left = try self.parseCompareExpr();

        if (self.check(.double_ampersand)) {
            try self.addRichError(
                "Zap uses `and` for logical AND, not `&&`",
                self.currentSpan(),
                "this operator is from C/JavaScript",
                "replace `&&` with `and`",
            );
            return error.ParseError;
        }

        while (self.check(.keyword_and)) {
            _ = self.advance();
            const right = try self.parseCompareExpr();
            left = try self.create(ast.Expr, .{
                .binary_op = .{
                    .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                    .op = .and_op,
                    .lhs = left,
                    .rhs = right,
                },
            });
        }

        return left;
    }

    fn parseCompareExpr(self: *Parser) !*const ast.Expr {
        var left = try self.parsePipeExpr();

        const op: ?ast.BinaryOp.Op = switch (self.peek()) {
            .equal_equal => .equal,
            .not_equal => .not_equal,
            .less => .less,
            .greater => .greater,
            .less_equal => .less_equal,
            .greater_equal => .greater_equal,
            else => null,
        };

        if (op) |o| {
            _ = self.advance();
            const right = try self.parsePipeExpr();
            return self.create(ast.Expr, .{
                .binary_op = .{
                    .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                    .op = o,
                    .lhs = left,
                    .rhs = right,
                },
            });
        }

        return left;
    }

    fn parsePipeExpr(self: *Parser) !*const ast.Expr {
        var left = try self.parseAddExpr();

        while (true) {
            // Skip newlines/indentation to support multiline pipes:
            //   value
            //   |> transform()
            //   |> another()
            self.skipNewlinesForContinuation(.pipe_operator);
            if (!self.check(.pipe_operator)) break;
            _ = self.advance();
            const right = try self.parseAddExpr();
            left = try self.create(ast.Expr, .{
                .pipe = .{
                    .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                    .lhs = left,
                    .rhs = right,
                },
            });
        }

        return left;
    }

    fn parseAddExpr(self: *Parser) !*const ast.Expr {
        var left = try self.parseMulExpr();

        while (true) {
            const op: ?ast.BinaryOp.Op = switch (self.peek()) {
                .plus => .add,
                .minus => .sub,
                .diamond => .concat,
                else => null,
            };

            if (op) |o| {
                _ = self.advance();
                const right = try self.parseMulExpr();
                left = try self.create(ast.Expr, .{
                    .binary_op = .{
                        .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                        .op = o,
                        .lhs = left,
                        .rhs = right,
                    },
                });
            } else break;
        }

        return left;
    }

    fn parseMulExpr(self: *Parser) !*const ast.Expr {
        var left = try self.parseUnaryExpr();

        while (true) {
            const op: ?ast.BinaryOp.Op = switch (self.peek()) {
                .star => .mul,
                .slash => .div,
                .keyword_rem => .rem_op,
                else => null,
            };

            if (op) |o| {
                _ = self.advance();
                const right = try self.parseUnaryExpr();
                left = try self.create(ast.Expr, .{
                    .binary_op = .{
                        .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                        .op = o,
                        .lhs = left,
                        .rhs = right,
                    },
                });
            } else break;
        }

        return left;
    }

    fn parseUnaryExpr(self: *Parser) !*const ast.Expr {
        if (self.check(.minus)) {
            const start = self.currentSpan();
            _ = self.advance();
            const operand = try self.parsePostfixExpr();
            return self.create(ast.Expr, .{
                .unary_op = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, operand.getMeta().span) },
                    .op = .negate,
                    .operand = operand,
                },
            });
        }
        if (self.check(.keyword_not)) {
            const start = self.currentSpan();
            _ = self.advance();
            const operand = try self.parsePostfixExpr();
            return self.create(ast.Expr, .{
                .unary_op = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, operand.getMeta().span) },
                    .op = .not_op,
                    .operand = operand,
                },
            });
        }
        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) !*const ast.Expr {
        var expr = try self.parseCallExpr();

        if (self.check(.bang)) {
            const end = self.currentSpan();
            _ = self.advance();
            expr = try self.create(ast.Expr, .{
                .unwrap = .{
                    .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, end) },
                    .expr = expr,
                },
            });
        }

        return expr;
    }

    fn parseCallExpr(self: *Parser) !*const ast.Expr {
        var expr = try self.parsePrimaryExpr();

        while (true) {
            if (self.check(.left_paren)) {
                _ = self.advance();
                var args: std.ArrayList(*const ast.Expr) = .empty;

                while (!self.check(.right_paren) and !self.check(.eof)) {
                    const arg = try self.parseExpr();
                    try args.append(self.allocator, arg);
                    if (!self.match(.comma)) break;
                }

                const end_tok = try self.expect(.right_paren);
                expr = try self.create(ast.Expr, .{
                    .call = .{
                        .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, ast.SourceSpan.from(end_tok.loc)) },
                        .callee = expr,
                        .args = try args.toOwnedSlice(self.allocator),
                    },
                });
            } else if (self.check(.dot)) {
                _ = self.advance();
                const field_tok = try self.expect(.identifier);
                const field_name = try self.internToken(field_tok);
                expr = try self.create(ast.Expr, .{
                    .field_access = .{
                        .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, ast.SourceSpan.from(field_tok.loc)) },
                        .object = expr,
                        .field = field_name,
                    },
                });
            } else break;
        }

        return expr;
    }

    fn parsePrimaryExpr(self: *Parser) !*const ast.Expr {
        switch (self.peek()) {
            .int_literal => return self.parseIntLiteral(),
            .float_literal => return self.parseFloatLiteral(),
            .string_literal => return self.parseStringLiteral(),
            .atom_literal => return self.parseAtomLiteral(),
            .keyword_true, .keyword_false => return self.parseBoolLiteral(),
            .keyword_nil => return self.parseNilLiteral(),
            .identifier => return self.parseVarRef(),
            .module_identifier => return self.parseModuleRefExpr(),
            .left_paren => return self.parseParenExpr(),
            .left_brace => return self.parseTupleExpr(),
            .left_bracket => return self.parseListExpr(),
            .percent_brace => return self.parseMapExpr(),
            .percent => return self.parseStructExpr(),
            .keyword_if => return self.parseIfExpr(),
            .keyword_case => return self.parseCaseExpr(),
            .keyword_with => return self.parseWithExpr(),
            .keyword_cond => return self.parseCondExpr(),
            .keyword_quote => return self.parseQuoteExpr(),
            .keyword_unquote => return self.parseUnquoteExpr(),
            .keyword_panic => return self.parsePanicExpr(),
            .at_sign => return self.parseIntrinsicExpr(),
            .double_ampersand => {
                try self.addRichError(
                    "Zap uses `and` for logical AND, not `&&`",
                    self.currentSpan(),
                    "this operator is from C/JavaScript",
                    "replace `&&` with `and`",
                );
                return error.ParseError;
            },
            .double_pipe => {
                try self.addRichError(
                    "Zap uses `or` for logical OR, not `||`",
                    self.currentSpan(),
                    "this operator is from C/JavaScript",
                    "replace `||` with `or`",
                );
                return error.ParseError;
            },
            .plus_plus => {
                try self.addRichError(
                    "Zap uses `<>` for concatenation, not `++`",
                    self.currentSpan(),
                    "this operator is from Elixir/Haskell",
                    "use `<>` for string concatenation",
                );
                return error.ParseError;
            },
            else => {
                try self.addRichError(
                    std.fmt.allocPrint(self.allocator, "I was not expecting {s} here", .{
                        tokenHumanName(self.current.tag),
                    }) catch "unexpected token in expression",
                    self.currentSpan(),
                    "not a valid expression",
                    "expressions start with a value (number, string, variable), an operator, or a keyword like `if`, `case`, or `with`",
                );
                return error.ParseError;
            },
        }
    }

    // ============================================================
    // Literal parsing
    // ============================================================

    fn parseIntLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const text = tok.slice(self.source);
        const value = std.fmt.parseInt(i64, text, 10) catch 0;
        return self.create(ast.Expr, .{
            .int_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = value },
        });
    }

    fn parseFloatLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const text = tok.slice(self.source);
        const value = std.fmt.parseFloat(f64, text) catch 0.0;
        return self.create(ast.Expr, .{
            .float_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = value },
        });
    }

    fn parseStringLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const raw = tok.slice(self.source);
        const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
        return self.create(ast.Expr, .{
            .string_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = try self.interner.intern(value) },
        });
    }

    fn parseAtomLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const raw = tok.slice(self.source);
        const value = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
        return self.create(ast.Expr, .{
            .atom_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = try self.interner.intern(value) },
        });
    }

    fn parseBoolLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        return self.create(ast.Expr, .{
            .bool_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = tok.tag == .keyword_true },
        });
    }

    fn parseNilLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        return self.create(ast.Expr, .{
            .nil_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) } },
        });
    }

    fn parseVarRef(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        return self.create(ast.Expr, .{
            .var_ref = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .name = try self.internToken(tok) },
        });
    }

    fn parseModuleRefExpr(self: *Parser) !*const ast.Expr {
        const name = try self.parseModuleName();
        return self.create(ast.Expr, .{
            .module_ref = .{ .meta = .{ .span = name.span }, .name = name },
        });
    }

    fn parseParenExpr(self: *Parser) !*const ast.Expr {
        _ = try self.expect(.left_paren);
        const expr = try self.parseExpr();
        _ = try self.expect(.right_paren);
        return expr;
    }

    fn parseTupleExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.left_brace);

        var elements: std.ArrayList(*const ast.Expr) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const elem = try self.parseExpr();
            try elements.append(self.allocator, elem);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.Expr, .{
            .tuple = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseListExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.left_bracket);

        var elements: std.ArrayList(*const ast.Expr) = .empty;

        while (!self.check(.right_bracket) and !self.check(.eof)) {
            const elem = try self.parseExpr();
            try elements.append(self.allocator, elem);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_bracket);

        return self.create(ast.Expr, .{
            .list = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseMapExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.percent_brace);

        // Support multiline: %{\n  field: val,\n  ...\n}
        self.skipNewlines();
        const indented = self.match(.indent);

        // Parse key:value fields — could be map (key -> value) or struct (name: value)
        // Detect struct fields (identifier followed by colon) vs map fields (expr followed by arrow)
        var struct_fields: std.ArrayList(ast.StructField) = .empty;
        var map_fields: std.ArrayList(ast.MapField) = .empty;
        var is_struct = false;
        var is_map = false;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.indent)) _ = self.advance();
            if (self.check(.dedent)) _ = self.advance();
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            // Detect if this is `identifier:` (struct field) or expr -> (map)
            if (!is_map and self.check(.identifier)) {
                // Speculatively check for identifier : value (struct field syntax)
                const saved_lexer = self.lexer;
                const saved_current = self.current;
                const saved_previous = self.previous;
                const field_tok = self.advance();
                if (self.check(.colon)) {
                    // This is struct field syntax: name: value
                    _ = self.advance(); // consume colon
                    is_struct = true;
                    const field_name = try self.internToken(field_tok);
                    const value = try self.parseExpr();
                    try struct_fields.append(self.allocator, .{ .name = field_name, .value = value });
                    if (!self.match(.comma)) break;
                    self.skipNewlines();
                    continue;
                } else {
                    // Not struct syntax, restore and parse as map
                    self.lexer = saved_lexer;
                    self.current = saved_current;
                    self.previous = saved_previous;
                }
            }

            if (!is_struct) {
                is_map = true;
                const key = try self.parseExpr();
                _ = try self.expect(.arrow);
                const value = try self.parseExpr();
                try map_fields.append(self.allocator, .{ .key = key, .value = value });
                if (!self.match(.comma)) break;
                self.skipNewlines();
            } else {
                // Continuing struct fields
                const field_tok = try self.expect(.identifier);
                const field_name = try self.internToken(field_tok);
                _ = try self.expect(.colon);
                const value = try self.parseExpr();
                try struct_fields.append(self.allocator, .{ .name = field_name, .value = value });
                if (!self.match(.comma)) break;
                self.skipNewlines();
            }
        }

        _ = indented;
        while (self.check(.dedent) or self.check(.newline)) {
            _ = self.advance();
        }
        _ = try self.expect(.right_brace);

        // Check for :: Type annotation (converts to struct expression)
        if (self.check(.double_colon)) {
            _ = self.advance(); // consume ::
            const type_name = try self.parseModuleName();
            return self.create(ast.Expr, .{
                .struct_expr = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .module_name = type_name,
                    .update_source = null,
                    .fields = try struct_fields.toOwnedSlice(self.allocator),
                },
            });
        }

        if (is_struct) {
            // Struct fields without :: Type — error or treat as map
            // For now, still create a struct expr with empty module name
            return self.create(ast.Expr, .{
                .map = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .fields = &.{},
                },
            });
        }

        return self.create(ast.Expr, .{
            .map = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .fields = try map_fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseStructExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.percent);

        const module_name = try self.parseModuleName();
        _ = try self.expect(.left_brace);

        var fields: std.ArrayList(ast.StructField) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const field_tok = try self.expect(.identifier);
            const field_name = try self.internToken(field_tok);
            _ = try self.expect(.colon);
            const value = try self.parseExpr();
            try fields.append(self.allocator, .{ .name = field_name, .value = value });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.Expr, .{
            .struct_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .module_name = module_name,
                .update_source = null,
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    // ============================================================
    // Control flow expressions
    // ============================================================

    fn parseIfExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_if);

        const condition = try self.parseExpr();

        _ = try self.expect(.keyword_do);
        self.skipNewlines();
        _ = self.match(.indent);

        const then_block = try self.parseBlock();

        _ = self.match(.dedent);
        self.skipNewlines();

        var else_block: ?[]const ast.Stmt = null;
        if (self.match(.keyword_else)) {
            self.skipNewlines();
            _ = self.match(.indent);
            else_block = try self.parseBlock();
            _ = self.match(.dedent);
            self.skipNewlines();
        }

        _ = try self.expect(.keyword_end);

        return self.create(ast.Expr, .{
            .if_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            },
        });
    }

    fn parseCaseExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_case);

        const scrutinee = try self.parseExpr();

        _ = try self.expect(.keyword_do);
        self.skipNewlines();
        _ = self.match(.indent);

        var clauses: std.ArrayList(ast.CaseClause) = .empty;

        while (!self.check(.keyword_end) and !self.check(.dedent) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.dedent)) break;

            const clause = try self.parseCaseClause();
            try clauses.append(self.allocator, clause);
            self.skipNewlines();
        }

        _ = self.match(.dedent);
        self.skipNewlines();
        _ = try self.expect(.keyword_end);

        return self.create(ast.Expr, .{
            .case_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .scrutinee = scrutinee,
                .clauses = try clauses.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseCaseClause(self: *Parser) !ast.CaseClause {
        const start = self.currentSpan();

        const pattern = try self.parsePattern();

        var type_annotation: ?*const ast.TypeExpr = null;
        if (self.check(.double_colon)) {
            _ = self.advance();
            type_annotation = try self.parseTypeExpr();
        }

        var guard: ?*const ast.Expr = null;
        if (self.check(.keyword_if)) {
            _ = self.advance();
            guard = try self.parseExpr();
        }

        _ = try self.expect(.arrow);

        // Support both single-line and multi-line case bodies:
        // Single-line: Color.Red -> "value"
        // Multi-line:  Color.Red ->\n    "value"
        if (!self.check(.newline) and !self.check(.indent)) {
            // Single-line: parse just one expression
            const expr = try self.parseExpr();
            const body = try self.allocator.alloc(ast.Stmt, 1);
            body[0] = .{ .expr = expr };
            return .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .pattern = pattern,
                .type_annotation = type_annotation,
                .guard = guard,
                .body = body,
            };
        }

        self.skipNewlines();
        const indented = self.match(.indent);

        const body = try self.parseBlock();

        if (indented) {
            _ = self.match(.dedent);
        }

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .pattern = pattern,
            .type_annotation = type_annotation,
            .guard = guard,
            .body = body,
        };
    }

    fn parseWithExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_with);

        var items: std.ArrayList(ast.WithItem) = .empty;

        while (true) {
            const item = try self.parseWithItem();
            try items.append(self.allocator, item);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.keyword_do);
        self.skipNewlines();
        _ = self.match(.indent);

        const body = try self.parseBlock();

        _ = self.match(.dedent);
        self.skipNewlines();

        var else_clauses: ?[]const ast.WithElseClause = null;
        if (self.match(.keyword_else)) {
            self.skipNewlines();
            _ = self.match(.indent);

            var clauses: std.ArrayList(ast.WithElseClause) = .empty;
            while (!self.check(.keyword_end) and !self.check(.dedent) and !self.check(.eof)) {
                self.skipNewlines();
                if (self.check(.keyword_end) or self.check(.dedent)) break;

                const clause = try self.parseWithElseClause();
                try clauses.append(self.allocator, clause);
                self.skipNewlines();
            }
            else_clauses = try clauses.toOwnedSlice(self.allocator);

            _ = self.match(.dedent);
            self.skipNewlines();
        }

        _ = try self.expect(.keyword_end);

        return self.create(ast.Expr, .{
            .with_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .items = try items.toOwnedSlice(self.allocator),
                .body = body,
                .else_clauses = else_clauses,
            },
        });
    }

    fn parseWithItem(self: *Parser) !ast.WithItem {
        // Save state for backtracking
        const saved_pos = self.lexer.pos;
        const saved_current = self.current;
        const saved_previous = self.previous;
        const saved_line = self.lexer.line;
        const saved_at_line_start = self.lexer.at_line_start;
        const saved_indent_depth = self.lexer.indent_depth;

        // Try parsing as pattern <- expr
        if (self.parsePattern()) |pattern| {
            if (self.check(.back_arrow)) {
                _ = self.advance();
                const source = try self.parseExpr();
                return .{
                    .bind = .{
                        .meta = .{ .span = ast.SourceSpan.merge(pattern.getMeta().span, source.getMeta().span) },
                        .pattern = pattern,
                        .source = source,
                    },
                };
            }
            // Not a bind — backtrack
            self.lexer.pos = saved_pos;
            self.current = saved_current;
            self.previous = saved_previous;
            self.lexer.line = saved_line;
            self.lexer.at_line_start = saved_at_line_start;
            self.lexer.indent_depth = saved_indent_depth;
        } else |_| {
            self.lexer.pos = saved_pos;
            self.current = saved_current;
            self.previous = saved_previous;
            self.lexer.line = saved_line;
            self.lexer.at_line_start = saved_at_line_start;
            self.lexer.indent_depth = saved_indent_depth;
        }

        const expr = try self.parseExpr();
        return .{ .expr = expr };
    }

    fn parseWithElseClause(self: *Parser) !ast.WithElseClause {
        const start = self.currentSpan();
        const pattern = try self.parsePattern();

        var type_annotation: ?*const ast.TypeExpr = null;
        if (self.check(.double_colon)) {
            _ = self.advance();
            type_annotation = try self.parseTypeExpr();
        }

        var guard: ?*const ast.Expr = null;
        if (self.check(.keyword_if)) {
            _ = self.advance();
            guard = try self.parseExpr();
        }

        _ = try self.expect(.arrow);
        self.skipNewlines();
        _ = self.match(.indent);

        const body = try self.parseBlock();

        _ = self.match(.dedent);

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .pattern = pattern,
            .type_annotation = type_annotation,
            .guard = guard,
            .body = body,
        };
    }

    fn parseCondExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_cond);
        _ = try self.expect(.keyword_do);
        self.skipNewlines();
        _ = self.match(.indent);

        var clauses: std.ArrayList(ast.CondClause) = .empty;

        while (!self.check(.keyword_end) and !self.check(.dedent) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.keyword_end) or self.check(.dedent)) break;

            const clause_start = self.currentSpan();
            const condition = try self.parseExpr();
            _ = try self.expect(.arrow);
            self.skipNewlines();
            _ = self.match(.indent);
            const body = try self.parseBlock();
            _ = self.match(.dedent);

            try clauses.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.merge(clause_start, self.previousSpan()) },
                .condition = condition,
                .body = body,
            });
            self.skipNewlines();
        }

        _ = self.match(.dedent);
        self.skipNewlines();
        _ = try self.expect(.keyword_end);

        return self.create(ast.Expr, .{
            .cond_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .clauses = try clauses.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseQuoteExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_quote);
        _ = try self.expect(.keyword_do);
        self.skipNewlines();
        _ = self.match(.indent);

        const body = try self.parseBlock();

        _ = self.match(.dedent);
        self.skipNewlines();
        _ = try self.expect(.keyword_end);

        return self.create(ast.Expr, .{
            .quote_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .body = body,
            },
        });
    }

    fn parseUnquoteExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_unquote);
        _ = try self.expect(.left_paren);
        const expr = try self.parseExpr();
        _ = try self.expect(.right_paren);

        return self.create(ast.Expr, .{
            .unquote_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .expr = expr,
            },
        });
    }

    fn parsePanicExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_panic);
        _ = try self.expect(.left_paren);
        const message = try self.parseExpr();
        _ = try self.expect(.right_paren);

        return self.create(ast.Expr, .{
            .panic_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .message = message,
            },
        });
    }

    fn parseIntrinsicExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.at_sign);
        const name_tok = try self.expect(.identifier);
        const name = try self.internToken(name_tok);

        _ = try self.expect(.left_paren);
        var args: std.ArrayList(*const ast.Expr) = .empty;

        while (!self.check(.right_paren) and !self.check(.eof)) {
            const arg = try self.parseExpr();
            try args.append(self.allocator, arg);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_paren);

        return self.create(ast.Expr, .{
            .intrinsic = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .name = name,
                .args = try args.toOwnedSlice(self.allocator),
            },
        });
    }

    // ============================================================
    // Pattern parsing
    // ============================================================

    pub fn parsePattern(self: *Parser) anyerror!*const ast.Pattern {
        switch (self.peek()) {
            .identifier => {
                const tok = self.advance();
                const text = tok.slice(self.source);
                if (std.mem.eql(u8, text, "_")) {
                    return self.create(ast.Pattern, .{
                        .wildcard = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) } },
                    });
                }
                // Check for module-qualified enum pattern: Color.Red
                if (self.check(.dot)) {
                    _ = self.advance(); // consume '.'
                    if (self.check(.identifier) or self.check(.module_identifier)) {
                        const variant_tok = self.advance();
                        const variant_text = variant_tok.slice(self.source);
                        return self.create(ast.Pattern, .{
                            .literal = .{ .atom = .{
                                .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(tok.loc), ast.SourceSpan.from(variant_tok.loc)) },
                                .value = try self.interner.intern(variant_text),
                            } },
                        });
                    }
                }
                return self.create(ast.Pattern, .{
                    .bind = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .name = try self.internToken(tok),
                    },
                });
            },
            .module_identifier => {
                const tok = self.advance();
                // Module-qualified enum pattern: Color.Red
                if (self.check(.dot)) {
                    _ = self.advance(); // consume '.'
                    if (self.check(.identifier) or self.check(.module_identifier)) {
                        const variant_tok = self.advance();
                        const variant_text = variant_tok.slice(self.source);
                        return self.create(ast.Pattern, .{
                            .literal = .{ .atom = .{
                                .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(tok.loc), ast.SourceSpan.from(variant_tok.loc)) },
                                .value = try self.interner.intern(variant_text),
                            } },
                        });
                    }
                }
                // Bare module identifier in pattern — treat as bind
                return self.create(ast.Pattern, .{
                    .bind = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .name = try self.internToken(tok),
                    },
                });
            },
            .int_literal => {
                const tok = self.advance();
                const text = tok.slice(self.source);
                const value = std.fmt.parseInt(i64, text, 10) catch 0;
                return self.create(ast.Pattern, .{
                    .literal = .{ .int = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = value,
                    } },
                });
            },
            .float_literal => {
                const tok = self.advance();
                const text = tok.slice(self.source);
                const value = std.fmt.parseFloat(f64, text) catch 0.0;
                return self.create(ast.Pattern, .{
                    .literal = .{ .float = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = value,
                    } },
                });
            },
            .string_literal => {
                const tok = self.advance();
                const raw = tok.slice(self.source);
                const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                return self.create(ast.Pattern, .{
                    .literal = .{ .string = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = try self.interner.intern(value),
                    } },
                });
            },
            .atom_literal => {
                const tok = self.advance();
                const raw = tok.slice(self.source);
                const value = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
                return self.create(ast.Pattern, .{
                    .literal = .{ .atom = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = try self.interner.intern(value),
                    } },
                });
            },
            .keyword_true => {
                const tok = self.advance();
                return self.create(ast.Pattern, .{
                    .literal = .{ .bool_lit = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = true,
                    } },
                });
            },
            .keyword_false => {
                const tok = self.advance();
                return self.create(ast.Pattern, .{
                    .literal = .{ .bool_lit = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = false,
                    } },
                });
            },
            .keyword_nil => {
                const tok = self.advance();
                return self.create(ast.Pattern, .{
                    .literal = .{ .nil = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) } } },
                });
            },
            .left_brace => return self.parseTuplePattern(),
            .left_bracket => return self.parseListPattern(),
            .percent_brace => return self.parseMapPattern(),
            .percent => return self.parseStructPattern(),
            .caret => return self.parsePinPattern(),
            .left_paren => return self.parseParenPattern(),
            .minus => {
                const start = self.currentSpan();
                _ = self.advance();
                if (self.check(.int_literal)) {
                    const tok = self.advance();
                    const text = tok.slice(self.source);
                    const value = std.fmt.parseInt(i64, text, 10) catch 0;
                    return self.create(ast.Pattern, .{
                        .literal = .{ .int = .{
                            .meta = .{ .span = ast.SourceSpan.merge(start, ast.SourceSpan.from(tok.loc)) },
                            .value = -value,
                        } },
                    });
                }
                try self.addRichError(
                    "I was expecting a number after `-` in this pattern",
                    self.currentSpan(),
                    null,
                    "negative patterns must be followed by an integer, like `-1`",
                );
                return error.ParseError;
            },
            else => {
                try self.addRichError(
                    std.fmt.allocPrint(self.allocator, "I was not expecting {s} in this pattern", .{
                        tokenHumanName(self.current.tag),
                    }) catch "unexpected token in pattern",
                    self.currentSpan(),
                    "not valid in a pattern",
                    "patterns can be literals, variables, tuples `{a, b}`, lists `[a, b]`, or the wildcard `_`",
                );
                return error.ParseError;
            },
        }
    }

    fn parseTuplePattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.left_brace);

        var elements: std.ArrayList(*const ast.Pattern) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const elem = try self.parsePattern();
            try elements.append(self.allocator, elem);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.Pattern, .{
            .tuple = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseListPattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.left_bracket);

        var elements: std.ArrayList(*const ast.Pattern) = .empty;

        while (!self.check(.right_bracket) and !self.check(.eof)) {
            const elem = try self.parsePattern();
            try elements.append(self.allocator, elem);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_bracket);

        return self.create(ast.Pattern, .{
            .list = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseMapPattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.percent_brace);

        // Detect struct-like pattern: %{name: pattern, ...}
        // vs map pattern: %{expr => pattern, ...}
        // If first element is identifier followed by colon, treat as struct pattern fields
        if (self.check(.identifier) and self.peekNext() == .colon) {
            // Struct-like destructuring pattern
            var struct_fields: std.ArrayList(ast.StructPatternField) = .empty;
            while (!self.check(.right_brace) and !self.check(.eof)) {
                const field_tok = try self.expect(.identifier);
                const field_name = try self.internToken(field_tok);
                _ = try self.expect(.colon);
                const pattern = try self.parsePattern();
                try struct_fields.append(self.allocator, .{ .name = field_name, .pattern = pattern });
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.right_brace);

            return self.create(ast.Pattern, .{
                .struct_pattern = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .module_name = .{ .parts = &.{}, .span = start },
                    .fields = try struct_fields.toOwnedSlice(self.allocator),
                },
            });
        }

        var fields: std.ArrayList(ast.MapPatternField) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const key = try self.parseExpr();
            _ = try self.expect(.arrow);
            const value = try self.parsePattern();
            try fields.append(self.allocator, .{ .key = key, .value = value });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.Pattern, .{
            .map = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseStructPattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.percent);

        const module_name = try self.parseModuleName();

        _ = try self.expect(.left_brace);

        var fields: std.ArrayList(ast.StructPatternField) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const field_tok = try self.expect(.identifier);
            const field_name = try self.internToken(field_tok);
            _ = try self.expect(.colon);
            const pattern = try self.parsePattern();
            try fields.append(self.allocator, .{ .name = field_name, .pattern = pattern });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.Pattern, .{
            .struct_pattern = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .module_name = module_name,
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parsePinPattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.caret);
        const name_tok = try self.expect(.identifier);
        return self.create(ast.Pattern, .{
            .pin = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, ast.SourceSpan.from(name_tok.loc)) },
                .name = try self.internToken(name_tok),
            },
        });
    }

    fn parseParenPattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.left_paren);
        const inner = try self.parsePattern();
        _ = try self.expect(.right_paren);
        return self.create(ast.Pattern, .{
            .paren = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .inner = inner,
            },
        });
    }

    // ============================================================
    // Type expression parsing
    // ============================================================

    pub fn parseTypeExpr(self: *Parser) anyerror!*const ast.TypeExpr {
        return self.parseTypeUnion();
    }

    fn parseTypeUnion(self: *Parser) !*const ast.TypeExpr {
        var first = try self.parseTypeTerm();

        if (!self.check(.pipe)) return first;

        var members: std.ArrayList(*const ast.TypeExpr) = .empty;
        try members.append(self.allocator, first);

        while (self.check(.pipe)) {
            _ = self.advance();
            self.skipNewlines();
            const member = try self.parseTypeTerm();
            try members.append(self.allocator, member);
        }

        const start = first.getMeta().span;
        first = try self.create(ast.TypeExpr, .{
            .union_type = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .members = try members.toOwnedSlice(self.allocator),
            },
        });

        return first;
    }

    fn parseTypeTerm(self: *Parser) !*const ast.TypeExpr {
        switch (self.peek()) {
            .left_paren => return self.parseFunctionTypeOrParenType(),
            .left_brace => return self.parseTupleType(),
            .left_bracket => return self.parseListType(),
            .percent_brace => return self.parseMapType(),
            .percent => return self.parseStructType(),
            .atom_literal => return self.parseAtomType(),
            .int_literal, .string_literal, .keyword_true, .keyword_false, .keyword_nil => return self.parseLiteralType(),
            .identifier, .module_identifier => return self.parseNamedType(),
            else => {
                try self.addRichError(
                    std.fmt.allocPrint(self.allocator, "I was not expecting {s} in this type annotation", .{
                        tokenHumanName(self.current.tag),
                    }) catch "unexpected token in type",
                    self.currentSpan(),
                    "not a valid type",
                    "types look like: `i64`, `String`, `{:ok, i64}`, or `List(i64)`",
                );
                return error.ParseError;
            },
        }
    }

    fn parseFunctionTypeOrParenType(self: *Parser) !*const ast.TypeExpr {
        const start = self.currentSpan();
        _ = try self.expect(.left_paren);

        if (self.check(.arrow)) {
            _ = self.advance();
            const return_type = try self.parseTypeExpr();
            _ = try self.expect(.right_paren);
            return self.create(ast.TypeExpr, .{
                .function = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .params = &[_]*const ast.TypeExpr{},
                    .return_type = return_type,
                },
            });
        }

        const first = try self.parseTypeExpr();

        if (self.check(.arrow)) {
            _ = self.advance();
            const return_type = try self.parseTypeExpr();
            _ = try self.expect(.right_paren);
            return self.create(ast.TypeExpr, .{
                .function = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .params = try self.allocator.dupe(*const ast.TypeExpr, &[_]*const ast.TypeExpr{first}),
                    .return_type = return_type,
                },
            });
        }

        if (self.check(.comma)) {
            var params: std.ArrayList(*const ast.TypeExpr) = .empty;
            try params.append(self.allocator, first);
            while (self.match(.comma)) {
                if (self.check(.arrow)) break;
                const param = try self.parseTypeExpr();
                try params.append(self.allocator, param);
            }
            if (self.check(.arrow)) {
                _ = self.advance();
                const return_type = try self.parseTypeExpr();
                _ = try self.expect(.right_paren);
                return self.create(ast.TypeExpr, .{
                    .function = .{
                        .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                        .params = try params.toOwnedSlice(self.allocator),
                        .return_type = return_type,
                    },
                });
            }
        }

        _ = try self.expect(.right_paren);
        return self.create(ast.TypeExpr, .{
            .paren = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .inner = first,
            },
        });
    }

    fn parseTupleType(self: *Parser) !*const ast.TypeExpr {
        const start = self.currentSpan();
        _ = try self.expect(.left_brace);

        var elements: std.ArrayList(*const ast.TypeExpr) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const elem = try self.parseTypeExpr();
            try elements.append(self.allocator, elem);
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.TypeExpr, .{
            .tuple = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .elements = try elements.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseListType(self: *Parser) !*const ast.TypeExpr {
        const start = self.currentSpan();
        _ = try self.expect(.left_bracket);
        const element = try self.parseTypeExpr();
        _ = try self.expect(.right_bracket);

        return self.create(ast.TypeExpr, .{
            .list = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .element = element,
            },
        });
    }

    fn parseMapType(self: *Parser) !*const ast.TypeExpr {
        const start = self.currentSpan();
        _ = try self.expect(.percent_brace);

        var fields: std.ArrayList(ast.TypeMapField) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const key = try self.parseTypeExpr();
            _ = try self.expect(.arrow);
            const value = try self.parseTypeExpr();
            try fields.append(self.allocator, .{ .key = key, .value = value });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.TypeExpr, .{
            .map = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseStructType(self: *Parser) !*const ast.TypeExpr {
        const start = self.currentSpan();
        _ = try self.expect(.percent);

        const module_name = try self.parseModuleName();

        _ = try self.expect(.left_brace);

        var fields: std.ArrayList(ast.TypeStructField) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            const field_tok = try self.expect(.identifier);
            const field_name = try self.internToken(field_tok);
            _ = try self.expect(.colon);
            const type_expr = try self.parseTypeExpr();
            try fields.append(self.allocator, .{ .name = field_name, .type_expr = type_expr });
            if (!self.match(.comma)) break;
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.TypeExpr, .{
            .struct_type = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .module_name = module_name,
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseAtomType(self: *Parser) !*const ast.TypeExpr {
        const tok = self.advance();
        const raw = tok.slice(self.source);
        const value = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
        return self.create(ast.TypeExpr, .{
            .literal = .{
                .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                .value = .{ .string = try self.interner.intern(value) },
            },
        });
    }

    fn parseLiteralType(self: *Parser) !*const ast.TypeExpr {
        switch (self.peek()) {
            .int_literal => {
                const tok = self.advance();
                const text = tok.slice(self.source);
                const value = std.fmt.parseInt(i64, text, 10) catch 0;
                return self.create(ast.TypeExpr, .{
                    .literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = .{ .int = value } },
                });
            },
            .string_literal => {
                const tok = self.advance();
                const raw = tok.slice(self.source);
                const value = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                return self.create(ast.TypeExpr, .{
                    .literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = .{ .string = try self.interner.intern(value) } },
                });
            },
            .keyword_true => {
                const tok = self.advance();
                return self.create(ast.TypeExpr, .{
                    .literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = .{ .bool_val = true } },
                });
            },
            .keyword_false => {
                const tok = self.advance();
                return self.create(ast.TypeExpr, .{
                    .literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = .{ .bool_val = false } },
                });
            },
            .keyword_nil => {
                const tok = self.advance();
                return self.create(ast.TypeExpr, .{
                    .literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = .nil },
                });
            },
            else => {
                try self.addError("unexpected token in type literal", self.currentSpan());
                return error.ParseError;
            },
        }
    }

    fn parseNamedType(self: *Parser) !*const ast.TypeExpr {
        const tok = self.advance();
        const text = tok.slice(self.source);

        if (std.mem.eql(u8, text, "Never")) {
            return self.create(ast.TypeExpr, .{
                .never = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) } },
            });
        }

        const name = try self.interner.intern(text);

        var args: std.ArrayList(*const ast.TypeExpr) = .empty;
        if (self.check(.left_paren)) {
            _ = self.advance();
            while (!self.check(.right_paren) and !self.check(.eof)) {
                const arg = try self.parseTypeExpr();
                try args.append(self.allocator, arg);
                if (!self.match(.comma)) break;
            }
            _ = try self.expect(.right_paren);
        }

        // If lowercase with no args, could be a type variable
        if (text[0] >= 'a' and text[0] <= 'z' and args.items.len == 0) {
            const known_types = [_][]const u8{
                "i8",    "i16",   "i32",    "i64",
                "u8",    "u16",   "u32",    "u64",
                "f16",   "f32",   "f64",
                "usize", "isize",
            };
            for (known_types) |kt| {
                if (std.mem.eql(u8, text, kt)) {
                    return self.create(ast.TypeExpr, .{
                        .name = .{
                            .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                            .name = name,
                            .args = &[_]*const ast.TypeExpr{},
                        },
                    });
                }
            }
            return self.create(ast.TypeExpr, .{
                .variable = .{
                    .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                    .name = name,
                },
            });
        }

        return self.create(ast.TypeExpr, .{
            .name = .{
                .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(tok.loc), self.previousSpan()) },
                .name = name,
                .args = try args.toOwnedSlice(self.allocator),
            },
        });
    }

    // ============================================================
    // Helper: convert expression to pattern (for assignment LHS)
    // ============================================================

    fn exprToPattern(self: *Parser, expr: *const ast.Expr) !*const ast.Pattern {
        switch (expr.*) {
            .var_ref => |v| {
                const name = self.interner.get(v.name);
                if (std.mem.eql(u8, name, "_")) {
                    return self.create(ast.Pattern, .{ .wildcard = .{ .meta = v.meta } });
                }
                return self.create(ast.Pattern, .{ .bind = .{ .meta = v.meta, .name = v.name } });
            },
            .int_literal => |v| {
                return self.create(ast.Pattern, .{ .literal = .{ .int = .{ .meta = v.meta, .value = v.value } } });
            },
            .tuple => |v| {
                var elements: std.ArrayList(*const ast.Pattern) = .empty;
                for (v.elements) |elem| {
                    try elements.append(self.allocator, try self.exprToPattern(elem));
                }
                return self.create(ast.Pattern, .{
                    .tuple = .{ .meta = v.meta, .elements = try elements.toOwnedSlice(self.allocator) },
                });
            },
            .list => |v| {
                var elements: std.ArrayList(*const ast.Pattern) = .empty;
                for (v.elements) |elem| {
                    try elements.append(self.allocator, try self.exprToPattern(elem));
                }
                return self.create(ast.Pattern, .{
                    .list = .{ .meta = v.meta, .elements = try elements.toOwnedSlice(self.allocator) },
                });
            },
            .atom_literal => |v| {
                return self.create(ast.Pattern, .{ .literal = .{ .atom = .{ .meta = v.meta, .value = v.value } } });
            },
            .string_literal => |v| {
                return self.create(ast.Pattern, .{ .literal = .{ .string = .{ .meta = v.meta, .value = v.value } } });
            },
            .bool_literal => |v| {
                return self.create(ast.Pattern, .{ .literal = .{ .bool_lit = .{ .meta = v.meta, .value = v.value } } });
            },
            .nil_literal => |v| {
                return self.create(ast.Pattern, .{ .literal = .{ .nil = .{ .meta = v.meta } } });
            },
            else => {
                try self.addError("invalid pattern", expr.getMeta().span);
                return error.ParseError;
            },
        }
    }

    fn expectIdentifierOrModule(self: *Parser) !Token {
        if (self.check(.identifier) or self.check(.module_identifier)) {
            return self.advance();
        }
        try self.addError("I was expecting an identifier", self.currentSpan());
        return error.ParseError;
    }
};

/// Human-readable names for token tags, used in error messages.
fn tokenHumanName(tag: Token.Tag) []const u8 {
    return switch (tag) {
        .keyword_def => "`def`",
        .keyword_defp => "`defp`",
        .keyword_defmodule => "`defmodule`",
        .keyword_defmacro => "`defmacro`",
        .keyword_defstruct => "`defstruct`",
        .keyword_do => "`do`",
        .keyword_end => "`end`",
        .keyword_if => "`if`",
        .keyword_else => "`else`",
        .keyword_case => "`case`",
        .keyword_with => "`with`",
        .keyword_cond => "`cond`",
        .keyword_type => "`type`",
        .keyword_opaque => "`opaque`",
        .keyword_alias => "`alias`",
        .keyword_import => "`import`",
        .keyword_quote => "`quote`",
        .keyword_unquote => "`unquote`",
        .keyword_true => "`true`",
        .keyword_false => "`false`",
        .keyword_nil => "`nil`",
        .keyword_and => "`and`",
        .keyword_or => "`or`",
        .keyword_not => "`not`",
        .keyword_rem => "`rem`",
        .keyword_panic => "`panic`",
        .keyword_only => "`only`",
        .keyword_except => "`except`",
        .keyword_as => "`as`",
        .left_paren => "`(`",
        .right_paren => "`)`",
        .left_bracket => "`[`",
        .right_bracket => "`]`",
        .left_brace => "`{`",
        .right_brace => "`}`",
        .comma => "`,`",
        .colon => "`:`",
        .dot => "`.`",
        .arrow => "`->`",
        .back_arrow => "`<-`",
        .double_colon => "`::`",
        .pipe => "`|`",
        .pipe_operator => "`|>`",
        .equal => "`=`",
        .equal_equal => "`==`",
        .not_equal => "`!=`",
        .less => "`<`",
        .greater => "`>`",
        .less_equal => "`<=`",
        .greater_equal => "`>=`",
        .plus => "`+`",
        .minus => "`-`",
        .star => "`*`",
        .slash => "`/`",
        .diamond => "`<>`",
        .bang => "`!`",
        .caret => "`^`",
        .at_sign => "`@`",
        .identifier => "an identifier",
        .module_identifier => "a module name",
        .int_literal => "a number",
        .float_literal => "a number",
        .string_literal => "a string",
        .atom_literal => "an atom",
        .newline => "a newline",
        .indent => "indentation",
        .dedent => "dedentation",
        .eof => "end of file",
        .invalid => "an invalid token",
        .double_ampersand => "`&&`",
        .double_pipe => "`||`",
        .plus_plus => "`++`",
        else => Token.tagName(tag),
    };
}

// ============================================================
// Tests
// ============================================================

test "parse simple function" {
    const source =
        \\def add(x :: i64, y :: i64) :: i64 do
        \\  x + y
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    try std.testing.expect(program.top_items[0] == .function);
}

test "parse module" {
    const source =
        \\defmodule Foo do
        \\  def bar() :: i64 do
        \\    42
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.modules.len);
    try std.testing.expectEqual(@as(usize, 1), program.modules[0].items.len);
}

test "parse type declaration" {
    const source = "type Result(a, e) = {:ok, a} | {:error, e}\n";

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    try std.testing.expect(program.top_items[0] == .type_decl);
}

test "parse if expression" {
    const source =
        \\def foo(x :: i64) :: i64 do
        \\  if x > 0 do
        \\    x
        \\  else
        \\    0
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
}

test "parse case expression" {
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
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
}

test "parse binary operators" {
    const source =
        \\def calc(x :: i64, y :: i64) :: i64 do
        \\  x + y * 2
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);

    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expectEqual(@as(usize, 1), body.len);

    const expr = body[0].expr;
    try std.testing.expect(expr.* == .binary_op);
    try std.testing.expectEqual(ast.BinaryOp.Op.add, expr.binary_op.op);
}

test "parse tuple and list" {
    const source =
        \\def foo() do
        \\  {1, 2, 3}
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
}

test "parse refinement predicate" {
    const source =
        \\def abs(x :: i64) :: i64 if x < 0 do
        \\  -x
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    try std.testing.expect(func.clauses[0].refinement != null);
}

test "parse assignment" {
    const source =
        \\def foo() do
        \\  x = 42
        \\  x
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    try std.testing.expect(body[0] == .assignment);
}

test "parse function call" {
    const source =
        \\def foo() do
        \\  bar(1, 2)
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expect(body[0].expr.* == .call);
}

test "parse pipe operator" {
    const source =
        \\def foo(x) do
        \\  x |> bar(1)
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expect(body[0].expr.* == .pipe);
}

test "parse struct declaration" {
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
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.modules.len);

    var found_struct = false;
    for (program.modules[0].items) |item| {
        if (item == .struct_decl) {
            found_struct = true;
            try std.testing.expectEqual(@as(usize, 2), item.struct_decl.fields.len);
        }
    }
    try std.testing.expect(found_struct);
}

test "parse panic expression" {
    const source =
        \\def foo() do
        \\  panic("oops")
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expect(body[0].expr.* == .panic_expr);
}

test "parse unwrap operator" {
    const source =
        \\def foo(x) do
        \\  bar(x)!
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expect(body[0].expr.* == .unwrap);
}

test "parse local function" {
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
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.top_items[0].function;
    const body = func.clauses[0].body;
    try std.testing.expect(body.len >= 2);
    try std.testing.expect(body[0] == .function_decl);
}

test "parse module with types and functions" {
    const source =
        \\defmodule Foo do
        \\  type Result(a, e) = {:ok, a} | {:error, e}
        \\
        \\  def b(s :: String) :: String do
        \\    s <> "foo"
        \\  end
        \\
        \\  def a(x :: i64) :: String do
        \\    def b(n :: i64) :: String do
        \\      int_to_string(n)
        \\    end
        \\    b("other")
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.modules.len);
    try std.testing.expectEqual(@as(usize, 3), program.modules[0].items.len);
}

test "parse top-level defstruct" {
    const source =
        \\defstruct User do
        \\  name :: String
        \\  age :: i64
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    const sd = program.top_items[0].struct_decl;
    try std.testing.expect(sd.name != null);
    try std.testing.expectEqual(@as(usize, 2), sd.fields.len);
}

test "parse defstruct extends" {
    const source =
        \\defstruct Shape do
        \\  color :: String
        \\end
        \\
        \\defstruct Circle extends Shape do
        \\  radius :: f64
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), program.top_items.len);
    const circle = program.top_items[1].struct_decl;
    try std.testing.expect(circle.parent != null);
    try std.testing.expectEqual(@as(usize, 1), circle.fields.len);
}

test "parse defenum" {
    const source =
        \\defenum Color do
        \\  Red
        \\  Green
        \\  Blue
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    const ed = program.top_items[0].enum_decl;
    try std.testing.expectEqual(@as(usize, 3), ed.variants.len);
}

test "parse defmodule extends" {
    const source =
        \\defmodule Animal do
        \\  def breathe() :: String do
        \\    "inhale"
        \\  end
        \\end
        \\
        \\defmodule Dog extends Animal do
        \\  def speak() :: String do
        \\    "woof"
        \\  end
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), program.modules.len);
    try std.testing.expect(program.modules[1].parent != null);
}

test "parse struct init with type annotation" {
    const source =
        \\defstruct Point do
        \\  x :: f64
        \\  y :: f64
        \\end
        \\
        \\def main() do
        \\  %{x: 1.0, y: 2.0} :: Point
        \\end
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    // Should have defstruct + def
    try std.testing.expectEqual(@as(usize, 2), program.top_items.len);
    const func = program.top_items[1].function;
    const body = func.clauses[0].body;
    try std.testing.expect(body[0].expr.* == .struct_expr);
}
