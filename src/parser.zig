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
    owned_interner: ?*ast.StringInterner,
    interner: *ast.StringInterner,
    errors: std.ArrayList(Error),
    anon_function_counter: u32,
    /// When true, `{` after a call is NOT parsed as a trailing block argument.
    /// Set during guard expression parsing where `{` starts the function body.
    in_guard_expr: bool = false,

    pub const Error = struct {
        message: []const u8,
        span: ast.SourceSpan,
        label: ?[]const u8 = null,
        help: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var lexer = Lexer.init(source);
        const first = lexer.next();
        const interner = allocator.create(ast.StringInterner) catch unreachable;
        interner.* = ast.StringInterner.init(allocator);
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = first,
            .previous = first,
            .source = source,
            .owned_interner = interner,
            .interner = interner,
            .errors = .empty,
            .anon_function_counter = 0,
        };
    }

    pub fn initWithSharedInterner(allocator: std.mem.Allocator, source: []const u8, interner: *ast.StringInterner, source_id: u32) Parser {
        var lexer = Lexer.initWithSourceId(source, source_id);
        const first = lexer.next();
        return .{
            .allocator = allocator,
            .lexer = lexer,
            .current = first,
            .previous = first,
            .source = source,
            .owned_interner = null,
            .interner = interner,
            .errors = .empty,
            .anon_function_counter = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        if (self.owned_interner) |interner| {
            interner.deinit();
            self.allocator.destroy(interner);
        }
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

    const LexerState = struct {
        lexer: Lexer,
        current: Token,
        previous: Token,
    };

    fn saveLexerState(self: *const Parser) LexerState {
        return .{
            .lexer = self.lexer,
            .current = self.current,
            .previous = self.previous,
        };
    }

    fn restoreLexerState(self: *Parser, state: LexerState) void {
        self.lexer = state.lexer;
        self.current = state.current;
        self.previous = state.previous;
    }

    fn check(self: *const Parser, tag: Token.Tag) bool {
        return self.current.tag == tag;
    }

    /// Check if current token is an identifier with a specific name.
    /// Used for contextual keywords like `use`.
    fn checkIdentifier(self: *const Parser, name: []const u8) bool {
        if (self.current.tag != .identifier) return false;
        const text = self.source[self.current.loc.start..self.current.loc.end];
        return std.mem.eql(u8, text, name);
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

    /// Strip underscores from a numeric literal string (e.g., "1_000_000" → "1000000")
    fn stripNumericUnderscores(self: *Parser, text: []const u8) []const u8 {
        if (std.mem.findScalar(u8, text, '_') == null) return text;
        var buf: std.ArrayList(u8) = .empty;
        for (text) |c| {
            if (c != '_') buf.append(self.allocator, c) catch return text;
        }
        return buf.toOwnedSlice(self.allocator) catch text;
    }

    /// Process escape sequences in a string: \n, \t, \r, \\, \", \0
    fn unescapeString(self: *Parser, text: []const u8) []const u8 {
        if (std.mem.findScalar(u8, text, '\\') == null) return text;
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len) {
                switch (text[i + 1]) {
                    'n' => buf.append(self.allocator, '\n') catch return text,
                    't' => buf.append(self.allocator, '\t') catch return text,
                    'r' => buf.append(self.allocator, '\r') catch return text,
                    '\\' => buf.append(self.allocator, '\\') catch return text,
                    '"' => buf.append(self.allocator, '"') catch return text,
                    '0' => buf.append(self.allocator, 0) catch return text,
                    'x' => {
                        // Hex escape: \xNN
                        if (i + 3 < text.len) {
                            const hi = std.fmt.charToDigit(text[i + 2], 16) catch {
                                buf.append(self.allocator, '\\') catch return text;
                                buf.append(self.allocator, 'x') catch return text;
                                i += 2;
                                continue;
                            };
                            const lo = std.fmt.charToDigit(text[i + 3], 16) catch {
                                buf.append(self.allocator, '\\') catch return text;
                                buf.append(self.allocator, 'x') catch return text;
                                i += 2;
                                continue;
                            };
                            buf.append(self.allocator, hi * 16 + lo) catch return text;
                            i += 4;
                            continue;
                        } else {
                            buf.append(self.allocator, '\\') catch return text;
                            buf.append(self.allocator, 'x') catch return text;
                        }
                    },
                    else => {
                        // Unknown escape — keep as-is
                        buf.append(self.allocator, '\\') catch return text;
                        buf.append(self.allocator, text[i + 1]) catch return text;
                    },
                }
                i += 2;
            } else {
                buf.append(self.allocator, text[i]) catch return text;
                i += 1;
            }
        }
        return buf.toOwnedSlice(self.allocator) catch text;
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
        while (self.check(.newline)) {
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
                .keyword_pub, .keyword_fn, .keyword_macro, .keyword_struct, .keyword_union, .keyword_protocol, .keyword_impl, .right_brace => return,
                .newline => {
                    _ = self.advance();
                    // After newline, check if next token starts a new statement
                    self.skipNewlines();
                    switch (self.peek()) {
                        .keyword_pub,
                        .keyword_fn,
                        .keyword_macro,
                        .keyword_struct,
                        .keyword_union,
                        .keyword_protocol,
                        .keyword_impl,
                        .keyword_type,
                        .keyword_opaque,
                        .keyword_alias,
                        .keyword_import,
                        .right_brace,
                        .eof,
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
        var structs: std.ArrayList(ast.StructDecl) = .empty;
        var top_items: std.ArrayList(ast.TopItem) = .empty;

        self.skipNewlines();

        while (!self.check(.eof)) {
            switch (self.peek()) {
                .keyword_pub => {
                    // pub struct / pub fn / pub macro / pub union
                    const saved = self.saveLexerState();
                    _ = self.advance(); // consume pub
                    switch (self.peek()) {
                        .keyword_struct => {
                            self.restoreLexerState(saved); // restore so parser sees pub
                            if (self.parseStructDecl(false)) |mod| {
                                try structs.append(self.allocator, mod);
                                try top_items.append(self.allocator, .{ .struct_decl = try self.create(ast.StructDecl, mod) });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_fn => {
                            self.restoreLexerState(saved);
                            try self.addRichError(
                                "functions cannot be defined at the top level",
                                self.currentSpan(),
                                null,
                                "move this function inside a `pub struct` block",
                            );
                            _ = self.advance(); // skip pub
                            _ = self.advance(); // skip fn
                            self.synchronize();
                        },
                        .keyword_macro => {
                            self.restoreLexerState(saved);
                            if (self.parseMacroDecl(.public)) |mac| {
                                try top_items.append(self.allocator, .{ .macro = mac });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_union => {
                            self.restoreLexerState(saved);
                            if (self.parseUnionDecl()) |ed| {
                                try top_items.append(self.allocator, .{ .union_decl = ed });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_protocol => {
                            self.restoreLexerState(saved);
                            if (self.parseProtocolDecl(false)) |proto| {
                                try top_items.append(self.allocator, .{ .protocol = try self.create(ast.ProtocolDecl, proto) });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_impl => {
                            self.restoreLexerState(saved);
                            if (self.parseImplDecl(false)) |impl_d| {
                                try top_items.append(self.allocator, .{ .impl_decl = try self.create(ast.ImplDecl, impl_d) });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        else => {
                            self.restoreLexerState(saved);
                            try self.addRichError(
                                "I was expecting `struct`, `fn`, `macro`, `union`, `protocol`, or `impl` after `pub`",
                                self.currentSpan(),
                                null,
                                null,
                            );
                            _ = self.advance();
                            self.synchronize();
                        },
                    }
                },
                .keyword_fn => {
                    try self.addRichError(
                        "functions cannot be defined at the top level",
                        self.currentSpan(),
                        null,
                        "move this function inside a `pub struct` block",
                    );
                    _ = self.advance();
                    self.synchronize();
                },
                // (legacy keywords removed — use `pub struct` / `struct` / `pub fn` / `fn` syntax)
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
                .keyword_macro => {
                    // bare macro at top level = private
                    if (self.parseMacroDecl(.private)) |mac| {
                        try top_items.append(self.allocator, .{ .priv_macro = mac });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_struct => {
                    // bare struct = private
                    if (self.parseStructDecl(true)) |mod| {
                        try structs.append(self.allocator, mod);
                        try top_items.append(self.allocator, .{ .priv_struct_decl = try self.create(ast.StructDecl, mod) });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_union => {
                    if (self.parseUnionDecl()) |ed| {
                        try top_items.append(self.allocator, .{ .union_decl = ed });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_protocol => {
                    if (self.parseProtocolDecl(true)) |proto| {
                        try top_items.append(self.allocator, .{ .priv_protocol = try self.create(ast.ProtocolDecl, proto) });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_impl => {
                    if (self.parseImplDecl(true)) |impl_d| {
                        try top_items.append(self.allocator, .{ .priv_impl_decl = try self.create(ast.ImplDecl, impl_d) });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .at_sign => {
                    // Top-level @doc attribute — applies to the next definition
                    if (self.parseAttributeDecl()) |attr| {
                        try top_items.append(self.allocator, .{ .attribute = attr });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .newline => {
                    _ = self.advance();
                },
                else => {
                    // Check for misspelled keywords
                    if (self.current.tag == .identifier) {
                        const text = self.current.slice(self.source);
                        const keywords = [_][]const u8{ "pub", "fn", "macro", "struct", "enum", "type", "opaque", "protocol", "impl" };
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
                        "the top level can contain `pub struct`, `struct`, `pub enum`, `type`, and `opaque` declarations",
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
            .structs = try structs.toOwnedSlice(self.allocator),
            .top_items = try top_items.toOwnedSlice(self.allocator),
        };
    }

    // ============================================================
    // Module declarations
    // ============================================================

    fn parseStructDecl(self: *Parser, is_private: bool) !ast.StructDecl {
        const start = self.currentSpan();
        // Determine syntax: pub struct / struct
        var use_brace_syntax = false;
        if (self.check(.keyword_pub)) {
            _ = self.advance(); // consume pub
            _ = try self.expect(.keyword_struct);
            use_brace_syntax = true;
        } else if (self.check(.keyword_struct)) {
            _ = self.advance(); // consume struct
            use_brace_syntax = true;
        } else {
            return error.ParseError;
        }

        if (!self.check(.module_identifier)) {
            try self.addRichError(
                "I was expecting a struct name (like `MyStruct`) after the struct keyword",
                start,
                "struct declaration starts here",
                "struct names must start with an uppercase letter",
            );
            return error.ParseError;
        }
        const name = try self.parseStructName();

        // Parse optional extends
        var parent: ?ast.StringId = null;
        if (self.match(.keyword_extends)) {
            const parent_tok = try self.expect(.module_identifier);
            parent = try self.internToken(parent_tok);
        }

        // Accept { to open the struct body
        const close_brace = use_brace_syntax or self.check(.left_brace);
        if (close_brace) {
            if (!self.check(.left_brace)) {
                try self.addRichError(
                    "I was expecting `{` to start the struct body",
                    start,
                    "this struct declaration needs a `{ ... }` block",
                    "add `{` after the struct name",
                );
                return error.ParseError;
            }
            _ = self.advance();
        } else {
            if (!self.check(.left_brace)) {
                try self.addRichError(
                    "I was expecting `{` to start the struct body",
                    start,
                    "this struct declaration needs a `{ ... }` block",
                    "add `{` after the struct name",
                );
                return error.ParseError;
            }
            _ = self.advance();
        }
        self.skipNewlines();

        var items: std.ArrayList(ast.StructItem) = .empty;
        var fields: std.ArrayList(ast.StructFieldDecl) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace) or self.check(.eof)) break;

            switch (self.peek()) {
                .keyword_pub => {
                    // pub fn / pub macro / pub struct / pub enum
                    const saved = self.saveLexerState();
                    _ = self.advance(); // consume pub
                    switch (self.peek()) {
                        .keyword_fn => {
                            self.restoreLexerState(saved);
                            if (self.parseFunctionDecl(.public)) |func| {
                                try items.append(self.allocator, .{ .function = func });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_macro => {
                            self.restoreLexerState(saved);
                            if (self.parseMacroDecl(.public)) |mac| {
                                try items.append(self.allocator, .{ .macro = mac });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_struct => {
                            self.restoreLexerState(saved);
                            if (self.parseNestedStructDecl()) |sd| {
                                try items.append(self.allocator, .{ .struct_decl = sd });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        .keyword_union => {
                            self.restoreLexerState(saved);
                            if (self.parseUnionDecl()) |ed| {
                                try items.append(self.allocator, .{ .union_decl = ed });
                            } else |_| {
                                self.synchronize();
                            }
                        },
                        else => {
                            self.restoreLexerState(saved);
                            try self.addRichError(
                                "I was expecting `fn`, `macro`, `struct`, or `union` after `pub`",
                                self.currentSpan(),
                                null,
                                null,
                            );
                            _ = self.advance();
                        },
                    }
                },
                .keyword_fn => {
                    if (self.parseFunctionDecl(.private)) |func| {
                        try items.append(self.allocator, .{ .priv_function = func });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_macro => {
                    if (self.parseMacroDecl(.private)) |mac| {
                        try items.append(self.allocator, .{ .priv_macro = mac });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_struct => {
                    if (self.parseNestedStructDecl()) |sd| {
                        try items.append(self.allocator, .{ .struct_decl = sd });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .keyword_union => {
                    if (self.parseUnionDecl()) |ed| {
                        try items.append(self.allocator, .{ .union_decl = ed });
                    } else |_| {
                        self.synchronize();
                    }
                },
                // (legacy keyword_def/defp/defmacro/defmacrop/defstruct/defenum removed)
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
                // Contextual keywords: use, describe, test; also field declarations
                .identifier => {
                    if (self.checkIdentifier("use")) {
                        if (self.parseUseDecl()) |ud| {
                            try items.append(self.allocator, .{ .use_decl = ud });
                        } else |_| {
                            self.synchronize();
                        }
                    } else if (self.isFieldDecl()) {
                        const field = try self.parseStructField();
                        try fields.append(self.allocator, field);
                    } else {
                        // Try parsing as a module-level expression (macro call like describe/test).
                        // These are collected into an auto-generated run/0 function.
                        const expr = try self.parseExpr();
                        try items.append(self.allocator, .{ .struct_level_expr = expr });
                    }
                },
                .at_sign => {
                    if (self.parseAttributeDecl()) |attr| {
                        try items.append(self.allocator, .{ .attribute = attr });
                    } else |_| {
                        self.synchronize();
                    }
                },
                .newline => {
                    _ = self.advance();
                },
                else => {
                    try self.addRichError(
                        std.fmt.allocPrint(self.allocator, "I was not expecting {s} inside a struct", .{
                            tokenHumanName(self.current.tag),
                        }) catch "unexpected token in struct",
                        self.currentSpan(),
                        "not valid inside a struct body",
                        "structs can contain `pub fn`, `fn`, `pub macro`, `macro`, `pub struct`, `pub union`, `type`, `alias`, `import`, and `@attribute` declarations",
                    );
                    _ = self.advance();
                },
            }
        }

        self.skipNewlines();
        if (!self.check(.right_brace)) {
            if (close_brace) {
                try self.addRichError(
                    "I was expecting `}` to close the struct that starts here",
                    start,
                    "this struct was opened here",
                    "add `}` to close the struct body",
                );
            } else {
                try self.addRichError(
                    "I was expecting `end` to close the struct that starts here",
                    start,
                    "this struct was opened here",
                    "add `end` to close the struct body",
                );
            }
            return error.ParseError;
        }
        _ = self.advance();

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .parent = parent,
            .items = try items.toOwnedSlice(self.allocator),
            .fields = try fields.toOwnedSlice(self.allocator),
            .is_private = is_private,
        };
    }

    fn isFieldDecl(self: *Parser) bool {
        if (!self.check(.identifier)) return false;
        const saved = self.saveLexerState();
        _ = self.advance();
        const is_field = self.check(.double_colon);
        self.restoreLexerState(saved);
        return is_field;
    }

    fn parseStructField(self: *Parser) !ast.StructFieldDecl {
        const field_start = self.currentSpan();
        const name_tok = try self.expect(.identifier);
        const field_name = try self.internToken(name_tok);
        _ = try self.expect(.double_colon);
        const type_expr = try self.parseTypeExpr();
        var default: ?*const ast.Expr = null;
        if (self.match(.equal)) {
            default = try self.parseExpr();
        }
        return .{
            .meta = .{ .span = ast.SourceSpan.merge(field_start, self.previousSpan()) },
            .name = field_name,
            .type_expr = type_expr,
            .default = default,
        };
    }

    fn parseProtocolDecl(self: *Parser, is_private: bool) !ast.ProtocolDecl {
        const start = self.currentSpan();
        if (self.check(.keyword_pub)) _ = self.advance();
        _ = try self.expect(.keyword_protocol);

        if (!self.check(.module_identifier)) {
            try self.addRichError(
                "I was expecting a protocol name (like `Enumerable`) after `protocol`",
                start,
                "protocol declaration starts here",
                "protocol names must start with an uppercase letter",
            );
            return error.ParseError;
        }
        const name = try self.parseStructName();

        _ = try self.expect(.left_brace);
        self.skipNewlines();

        var functions: std.ArrayList(ast.ProtocolFunctionSig) = .empty;
        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            if (self.check(.keyword_fn)) {
                const sig = try self.parseProtocolFunctionSig();
                try functions.append(self.allocator, sig);
            } else if (self.check(.at_sign)) {
                // Allow @doc attributes
                _ = try self.parseAttributeDecl();
            } else {
                try self.addRichError(
                    "only function signatures are allowed inside protocol declarations",
                    self.currentSpan(),
                    null,
                    "protocol bodies contain `fn name(params) -> ReturnType` signatures without bodies",
                );
                self.synchronize();
            }
            self.skipNewlines();
        }
        _ = try self.expect(.right_brace);

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .functions = try functions.toOwnedSlice(self.allocator),
            .is_private = is_private,
        };
    }

    fn parseProtocolFunctionSig(self: *Parser) !ast.ProtocolFunctionSig {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_fn);

        const name_tok = try self.parseSymbolicName();
        const name = try self.internToken(name_tok);

        _ = try self.expect(.left_paren);

        var params: std.ArrayList(ast.ProtocolParam) = .empty;
        while (!self.check(.right_paren) and !self.check(.eof)) {
            const param_start = self.currentSpan();
            const param_name_tok = try self.expect(.identifier);
            const param_name = try self.internToken(param_name_tok);

            var type_ann: ?*const ast.TypeExpr = null;
            if (self.match(.double_colon)) {
                type_ann = try self.parseTypeExpr();
            }

            try params.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.merge(param_start, self.previousSpan()) },
                .name = param_name,
                .type_annotation = type_ann,
            });

            if (!self.match(.comma)) break;
        }
        _ = try self.expect(.right_paren);

        var return_type: ?*const ast.TypeExpr = null;
        if (self.match(.arrow)) {
            return_type = try self.parseTypeExpr();
        }

        // Protocol functions must NOT have bodies
        if (self.check(.left_brace)) {
            try self.addRichError(
                "protocol functions are signatures only — they cannot have bodies",
                self.currentSpan(),
                "unexpected function body",
                "remove the `{ ... }` body — implementations go in `impl` blocks",
            );
            return error.ParseError;
        }

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
        };
    }

    fn parseImplDecl(self: *Parser, is_private: bool) !ast.ImplDecl {
        const start = self.currentSpan();
        if (self.check(.keyword_pub)) _ = self.advance();
        _ = try self.expect(.keyword_impl);

        if (!self.check(.module_identifier)) {
            try self.addRichError(
                "I was expecting a protocol name (like `Enumerable`) after `impl`",
                start,
                "impl declaration starts here",
                "impl blocks look like: `impl ProtocolName for TypeName { ... }`",
            );
            return error.ParseError;
        }
        const protocol_name = try self.parseStructName();

        if (!self.match(.keyword_for)) {
            try self.addRichError(
                "I was expecting `for` after the protocol name in this `impl` block",
                self.currentSpan(),
                null,
                "impl blocks look like: `impl ProtocolName for TypeName { ... }`",
            );
            return error.ParseError;
        }

        if (!self.check(.module_identifier)) {
            try self.addRichError(
                "I was expecting a type name (like `List`) after `for`",
                self.currentSpan(),
                null,
                "impl blocks look like: `impl ProtocolName for TypeName { ... }`",
            );
            return error.ParseError;
        }
        const target_type = try self.parseStructName();

        // Optional type parameters: `Map(K, V)` declares K and V as type
        // variables visible inside the impl's function signatures. Each
        // entry must be a bare identifier — no nested type expressions
        // and no constraints (those would belong to a future where-clause).
        var type_params: std.ArrayList(ast.StringId) = .empty;
        if (self.check(.left_paren)) {
            _ = self.advance();
            while (!self.check(.right_paren) and !self.check(.eof)) {
                if (!self.check(.identifier) and !self.check(.module_identifier)) {
                    try self.addRichError(
                        "I was expecting a type-parameter name (like `K`) inside the parens",
                        self.currentSpan(),
                        null,
                        "type parameters look like: `impl Enumerable for Map(K, V) { ... }`",
                    );
                    return error.ParseError;
                }
                const tok = self.advance();
                try type_params.append(self.allocator, try self.internToken(tok));
                if (!self.match(.comma)) break;
                self.skipNewlines();
            }
            _ = try self.expect(.right_paren);
        }

        _ = try self.expect(.left_brace);
        self.skipNewlines();

        var functions: std.ArrayList(*const ast.FunctionDecl) = .empty;
        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            if (self.check(.keyword_pub)) {
                const saved = self.saveLexerState();
                _ = self.advance();
                if (self.check(.keyword_fn)) {
                    self.restoreLexerState(saved);
                    const func = try self.parseFunctionDecl(.public);
                    try functions.append(self.allocator, func);
                } else {
                    self.restoreLexerState(saved);
                    try self.addRichError(
                        "I was expecting `fn` after `pub` inside an impl block",
                        self.currentSpan(),
                        null,
                        "impl blocks can only contain function declarations",
                    );
                    self.synchronize();
                }
            } else if (self.check(.keyword_fn)) {
                const func = try self.parseFunctionDecl(.private);
                try functions.append(self.allocator, func);
            } else if (self.check(.at_sign)) {
                // Allow @doc attributes before functions
                _ = try self.parseAttributeDecl();
            } else if (self.check(.newline)) {
                _ = self.advance();
            } else {
                try self.addRichError(
                    "only function declarations are allowed inside `impl` blocks",
                    self.currentSpan(),
                    null,
                    "impl blocks look like: `impl ProtocolName for TypeName { pub fn name(...) { ... } }`",
                );
                self.synchronize();
            }
            self.skipNewlines();
        }
        _ = try self.expect(.right_brace);

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .protocol_name = protocol_name,
            .target_type = target_type,
            .type_params = try type_params.toOwnedSlice(self.allocator),
            .functions = try functions.toOwnedSlice(self.allocator),
            .is_private = is_private,
        };
    }

    fn parseStructName(self: *Parser) !ast.StructName {
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

    /// Peek ahead to determine if a struct declaration is field-only (data struct)
    /// versus a module-like struct with items (functions, macros, etc.).
    /// Returns true if the struct body starts with `identifier ::` (field declaration).
    fn isFieldOnlyStruct(self: *Parser) bool {
        const saved = self.saveLexerState();
        defer self.restoreLexerState(saved);

        // Skip past pub/struct keywords
        if (self.check(.keyword_pub)) _ = self.advance();
        if (self.check(.keyword_struct)) _ = self.advance();

        // Skip dotted name (e.g., Foo.Bar)
        if (self.check(.module_identifier)) {
            _ = self.advance();
            while (self.check(.dot)) {
                _ = self.advance();
                if (self.check(.module_identifier) or self.check(.identifier)) {
                    _ = self.advance();
                } else break;
            }
        }

        // Skip optional extends
        if (self.check(.keyword_extends)) {
            _ = self.advance();
            if (self.check(.module_identifier)) _ = self.advance();
        }

        // Now we should be at `{`
        if (!self.check(.left_brace)) return false;
        _ = self.advance();

        // Skip newlines inside the brace
        while (self.check(.newline)) _ = self.advance();

        // If the first token after `{` is an identifier followed by `::`, it's field-only
        if (self.check(.identifier)) {
            _ = self.advance();
            return self.check(.double_colon);
        }

        // Empty struct `{}` is a field-only struct
        if (self.check(.right_brace)) return true;

        return false;
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

    fn parseNestedStructDecl(self: *Parser) !*const ast.StructDecl {
        const start = self.currentSpan();
        if (self.check(.keyword_pub)) _ = self.advance();
        _ = try self.expect(.keyword_struct);

        // Parse optional struct name (anonymous structs have no name)
        const name: ast.StructName = if (self.check(.module_identifier))
            try self.parseStructName()
        else
            .{ .parts = &.{}, .span = self.currentSpan() };

        _ = try self.expect(.left_brace);
        self.skipNewlines();

        var fields: std.ArrayList(ast.StructFieldDecl) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

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

            if (!self.match(.comma)) {
                self.skipNewlines();
                if (!self.check(.right_brace)) {
                    // Allow newline-separated fields too
                }
            } else {
                self.skipNewlines();
            }
        }

        self.skipNewlines();
        _ = try self.expect(.right_brace);

        return self.create(ast.StructDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .fields = try fields.toOwnedSlice(self.allocator),
        });
    }

    fn parseTopLevelStructDecl(self: *Parser) !*const ast.StructDecl {
        const start = self.currentSpan();
        if (self.check(.keyword_pub)) _ = self.advance();
        _ = try self.expect(.keyword_struct);

        // Parse name via parseStructName for dotted names support
        const name = try self.parseStructName();

        // Parse optional extends
        var parent: ?ast.StringId = null;
        if (self.match(.keyword_extends)) {
            const parent_tok = try self.expect(.module_identifier);
            parent = try self.internToken(parent_tok);
        }

        _ = try self.expectAt(.left_brace, start);
        self.skipNewlines();

        var fields: std.ArrayList(ast.StructFieldDecl) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

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

            if (!self.match(.comma)) {
                self.skipNewlines();
                if (!self.check(.right_brace)) {
                    // Allow newline-separated fields too
                }
            } else {
                self.skipNewlines();
            }
        }

        self.skipNewlines();
        _ = try self.expectAt(.right_brace, start);

        return self.create(ast.StructDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .parent = parent,
            .fields = try fields.toOwnedSlice(self.allocator),
        });
    }

    fn parseUnionDecl(self: *Parser) !*const ast.UnionDecl {
        const start = self.currentSpan();
        if (self.check(.keyword_pub)) _ = self.advance();
        _ = try self.expect(.keyword_union);

        // Parse dotted name (e.g., IO.Mode) via parseStructName, then intern as single string
        const struct_name = try self.parseStructName();
        const name = if (struct_name.parts.len == 1)
            struct_name.parts[0]
        else blk: {
            var name_buf: std.ArrayList(u8) = .empty;
            for (struct_name.parts, 0..) |part, i| {
                if (i > 0) name_buf.append(self.allocator, '.') catch {};
                name_buf.appendSlice(self.allocator, self.interner.get(part)) catch {};
            }
            break :blk try self.interner.intern(name_buf.items);
        };

        _ = try self.expectAt(.left_brace, start);
        self.skipNewlines();

        var variants: std.ArrayList(ast.UnionVariant) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            const variant_tok = try self.expect(.module_identifier);
            const variant_name = try self.internToken(variant_tok);

            var type_expr: ?*const ast.TypeExpr = null;
            if (self.match(.double_colon)) {
                type_expr = try self.parseTypeExpr();
            }

            try variants.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.from(variant_tok.loc) },
                .name = variant_name,
                .type_expr = type_expr,
            });

            // Allow comma between variants
            _ = self.match(.comma);
            self.skipNewlines();
        }

        self.skipNewlines();
        _ = try self.expectAt(.right_brace, start);

        return self.create(ast.UnionDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .variants = try variants.toOwnedSlice(self.allocator),
        });
    }

    // ============================================================
    // Function declarations
    // ============================================================

    /// Parse the name token of a `fn` or `macro` declaration. Accepts a regular
    /// identifier or any operator/keyword token usable as a callable name
    /// (so `pub fn <>(...)`, `pub macro |>(...)`, `pub fn rem(...)` all parse).
    fn parseSymbolicName(self: *Parser) !Token {
        if (self.check(.identifier)) return self.advance();
        if (self.check(.keyword_if) or self.check(.keyword_cond) or
            self.check(.keyword_and) or self.check(.keyword_or) or
            self.check(.keyword_not) or self.check(.keyword_rem) or
            self.check(.keyword_in) or self.check(.keyword_fn) or
            self.check(.keyword_struct) or self.check(.keyword_union) or
            self.check(.keyword_macro)) return self.advance();
        if (self.check(.plus) or self.check(.minus) or self.check(.star) or
            self.check(.slash) or self.check(.equal_equal) or
            self.check(.not_equal) or self.check(.less) or self.check(.greater) or
            self.check(.less_equal) or self.check(.greater_equal) or
            self.check(.diamond) or self.check(.pipe_operator) or
            self.check(.tilde_arrow)) return self.advance();
        return try self.expect(.identifier); // emits the standard "expected identifier" error
    }

    fn parseFunctionDecl(self: *Parser, visibility: ast.FunctionDecl.Visibility) !*const ast.FunctionDecl {
        const start = self.currentSpan();
        // consume `pub fn` or `fn`
        if (self.check(.keyword_pub)) _ = self.advance();
        if (self.check(.keyword_fn)) {
            _ = self.advance();
        } else {
            return error.ParseError;
        }

        const name_tok = try self.parseSymbolicName();
        const name = try self.internToken(name_tok);

        const clause = try self.parseFunctionClause(start);

        return self.create(ast.FunctionDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .clauses = try self.allocator.dupe(ast.FunctionClause, &[_]ast.FunctionClause{clause}),
            .visibility = visibility,
        });
    }

    fn parseMacroDecl(self: *Parser, visibility: ast.FunctionDecl.Visibility) !*const ast.FunctionDecl {
        const start = self.currentSpan();
        // consume `pub macro` or `macro`
        if (self.check(.keyword_pub)) _ = self.advance();
        _ = try self.expect(.keyword_macro);

        const name_tok = try self.parseSymbolicName();
        const name = try self.internToken(name_tok);

        const clause = try self.parseFunctionClause(start);

        return self.create(ast.FunctionDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .clauses = try self.allocator.dupe(ast.FunctionClause, &[_]ast.FunctionClause{clause}),
            .visibility = visibility,
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
        if (self.match(.arrow)) {
            return_type = try self.parseTypeExpr();
        }

        var refinement: ?*const ast.Expr = null;
        self.skipNewlinesForContinuation(.keyword_if);
        if (self.match(.keyword_if)) {
            refinement = try self.parseGuardExpr();
        }

        // Bodyless declaration: @native functions have no body
        if (!self.check(.left_brace)) {
            return .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .params = params,
                .return_type = return_type,
                .refinement = refinement,
                .body = null,
            };
        }
        _ = self.advance();
        self.skipNewlines();

        const body = try self.parseBlock();

        self.skipNewlines();
        if (!self.check(.right_brace)) {
            try self.addRichError(
                "I was expecting `}` to close the function that starts here",
                def_span,
                "this function was opened here",
                "add `}` to close the function body",
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
        var ownership: ast.Ownership = .shared;
        var ownership_explicit = false;
        if (self.match(.double_colon)) {
            if (self.match(.keyword_shared)) {
                ownership = .shared;
                ownership_explicit = true;
            } else if (self.match(.keyword_unique)) {
                ownership = .unique;
                ownership_explicit = true;
            } else if (self.match(.keyword_borrowed)) {
                ownership = .borrowed;
                ownership_explicit = true;
            }
            type_annotation = try self.parseTypeExpr();
        }

        var default: ?*const ast.Expr = null;
        if (self.match(.equal)) {
            default = try self.parseExpr();
        }

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .pattern = pattern,
            .type_annotation = type_annotation,
            .ownership = ownership,
            .ownership_explicit = ownership_explicit,
            .default = default,
        };
    }

    // ============================================================
    // Alias and Import
    // ============================================================

    fn parseAliasDecl(self: *Parser) !*const ast.AliasDecl {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_alias);

        const module_path = try self.parseStructName();

        var as_name: ?ast.StructName = null;
        if (self.match(.comma)) {
            if (self.check(.keyword_as)) {
                _ = self.advance();
                _ = try self.expect(.colon);
                as_name = try self.parseStructName();
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

        const module_path = try self.parseStructName();

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

    fn parseUseDecl(self: *Parser) !*const ast.UseDecl {
        const start = self.currentSpan();
        // "use" is a contextual keyword — consume it as an identifier
        _ = self.advance();

        const module_path = try self.parseStructName();

        // Optional opts after comma: use Module, key: value
        var opts: ?*const ast.Expr = null;
        if (self.match(.comma)) {
            opts = try self.parseExpr();
        }

        return self.create(ast.UseDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .module_path = module_path,
            .opts = opts,
        });
    }

    // ============================================================
    // Attribute declarations
    // ============================================================

    fn parseAttributeDecl(self: *Parser) !*const ast.AttributeDecl {
        const start = self.currentSpan();
        _ = try self.expect(.at_sign);

        if (!self.check(.identifier)) {
            try self.addRichError(
                "I was expecting an attribute name after `@`",
                start,
                "attribute starts here",
                "attribute names must be lowercase identifiers, like `@doc` or `@deprecated`",
            );
            return error.ParseError;
        }
        const name_tok = self.advance();
        const name = try self.internToken(name_tok);

        // Check for typed attribute: @name :: Type = value
        if (self.check(.double_colon)) {
            _ = self.advance();
            const type_expr = try self.parseTypeExpr();
            if (!self.check(.equal)) {
                try self.addRichError(
                    "I was expecting `=` after the type in this attribute declaration",
                    self.currentSpan(),
                    null,
                    "typed attributes look like: `@name :: Type = value`",
                );
                return error.ParseError;
            }
            _ = self.advance();
            const value = try self.parseExpr();
            return self.create(ast.AttributeDecl, .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .name = name,
                .type_expr = type_expr,
                .value = value,
            });
        }

        // Value attribute without type: @name = value
        if (self.check(.equal)) {
            _ = self.advance();
            const value = try self.parseExpr();
            return self.create(ast.AttributeDecl, .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .name = name,
                .type_expr = null,
                .value = value,
            });
        }

        // Marker attribute: @name (no type, no value)
        return self.create(ast.AttributeDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .type_expr = null,
            .value = null,
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

        while (!self.check(.right_brace) and !self.check(.keyword_else) and
            !self.check(.eof))
        {
            self.skipNewlines();
            if (self.check(.right_brace) or self.check(.keyword_else) or
                self.check(.eof)) break;

            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);

            self.skipNewlines();
        }

        return stmts.toOwnedSlice(self.allocator);
    }

    fn parseStmt(self: *Parser) !ast.Stmt {
        if (self.check(.keyword_pub)) {
            const saved = self.saveLexerState();
            _ = self.advance(); // consume pub
            if (self.check(.keyword_fn)) {
                self.restoreLexerState(saved);
                const func = try self.parseFunctionDecl(.public);
                return .{ .function_decl = func };
            } else if (self.check(.keyword_macro)) {
                self.restoreLexerState(saved);
                const mac = try self.parseMacroDecl(.public);
                return .{ .macro_decl = mac };
            }
            self.restoreLexerState(saved);
        }
        if (self.check(.keyword_fn)) {
            if (self.peekNext() == .identifier) {
                const func = try self.parseFunctionDecl(.private);
                return .{ .function_decl = func };
            }
        }
        if (self.check(.keyword_macro)) {
            const mac = try self.parseMacroDecl(.private);
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

    /// Parse a guard expression — like a regular expression but allows
    /// newlines before `and`/`or` continuation tokens.
    fn parseGuardExpr(self: *Parser) anyerror!*const ast.Expr {
        self.in_guard_expr = true;
        defer self.in_guard_expr = false;
        return self.parseGuardOrExpr();
    }

    fn parseGuardOrExpr(self: *Parser) anyerror!*const ast.Expr {
        var left = try self.parseGuardAndExpr();

        while (true) {
            self.skipNewlinesForContinuation(.keyword_or);
            if (!self.check(.keyword_or)) break;
            _ = self.advance();
            const right = try self.parseGuardAndExpr();
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

    fn parseGuardAndExpr(self: *Parser) anyerror!*const ast.Expr {
        var left = try self.parseCompareExpr();

        while (true) {
            self.skipNewlinesForContinuation(.keyword_and);
            if (!self.check(.keyword_and)) break;
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
            .keyword_in => .in_op,
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
        var left = try self.parseRangeExpr();

        while (true) {
            // Skip newlines/indentation to support multiline pipes:
            //   value
            //   |> transform()
            //   |> another()
            self.skipNewlinesForContinuation(.pipe_operator);
            if (!self.check(.pipe_operator)) break;
            _ = self.advance();
            const right = try self.parseRangeExpr();
            left = try self.create(ast.Expr, .{
                .pipe = .{
                    .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, right.getMeta().span) },
                    .lhs = left,
                    .rhs = right,
                },
            });
        }

        // Check for ~> error pipe after the pipe chain
        self.skipNewlinesForContinuation(.tilde_arrow);
        if (self.check(.tilde_arrow)) {
            _ = self.advance();
            left = try self.parseErrorPipeHandler(left);
        }

        return left;
    }

    fn parseErrorPipeHandler(self: *Parser, chain: *const ast.Expr) !*const ast.Expr {
        const start = chain.getMeta().span;

        // ~> { pattern -> body, ... } (inline block handler)
        if (self.check(.left_brace)) {
            _ = self.advance();
            self.skipNewlines();

            var clauses: std.ArrayList(ast.CaseClause) = .empty;
            while (!self.check(.right_brace) and !self.check(.eof)) {
                self.skipNewlines();
                if (self.check(.right_brace)) break;

                const clause = try self.parseCaseClause();
                try clauses.append(self.allocator, clause);
                self.skipNewlines();
            }

            self.skipNewlines();
            _ = try self.expect(.right_brace);

            return self.create(ast.Expr, .{
                .error_pipe = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .chain = chain,
                    .handler = .{ .block = try clauses.toOwnedSlice(self.allocator) },
                },
            });
        }

        // ~> handler_function() (function call handler)
        const func = try self.parseCallExpr();
        return self.create(ast.Expr, .{
            .error_pipe = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, func.getMeta().span) },
                .chain = chain,
                .handler = .{ .function = func },
            },
        });
    }

    fn parseRangeExpr(self: *Parser) !*const ast.Expr {
        const left = try self.parseAddExpr();

        if (!self.check(.dot_dot)) return left;
        _ = self.advance();

        const end = try self.parseAddExpr();

        var step: ?*const ast.Expr = null;
        if (self.check(.colon)) {
            _ = self.advance();
            step = try self.parseAddExpr();
        }

        return self.create(ast.Expr, .{
            .range = .{
                .meta = .{ .span = ast.SourceSpan.merge(left.getMeta().span, self.previousSpan()) },
                .start = left,
                .end = end,
                .step = step,
            },
        });
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

        // Type annotation: expr :: Type (e.g., 42 :: i32)
        if (self.check(.double_colon)) {
            _ = self.advance();
            const type_expr = try self.parseTypeExpr();
            expr = try self.create(ast.Expr, .{
                .type_annotated = .{
                    .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, self.previousSpan()) },
                    .expr = expr,
                    .type_expr = type_expr,
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

                // Trailing block: func(args) { body } → body becomes last argument
                // Disabled in guard expressions where { starts the function body.
                if (self.check(.left_brace) and !self.in_guard_expr) {
                    const block_expr = try self.parseBlockExpr();
                    try args.append(self.allocator, block_expr);
                }

                expr = try self.create(ast.Expr, .{
                    .call = .{
                        .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, ast.SourceSpan.from(end_tok.loc)) },
                        .callee = expr,
                        .args = try args.toOwnedSlice(self.allocator),
                    },
                });
            } else if (self.check(.dot)) {
                _ = self.advance();
                // Accept both lowercase identifiers and capitalized module names
                // (e.g., :zig.Prelude.println or map.field)
                const field_tok = if (self.check(.identifier))
                    self.advance()
                else if (self.check(.module_identifier))
                    self.advance()
                else
                    try self.expect(.identifier); // error if neither
                const field_name = try self.internToken(field_tok);

                // Check for function reference: Module.func/arity
                if (self.check(.slash)) {
                    const saved_lexer = self.lexer;
                    const saved_current = self.current;
                    const saved_previous = self.previous;
                    _ = self.advance(); // consume /
                    if (self.check(.int_literal)) {
                        const arity_tok = self.advance();
                        const arity_text = arity_tok.slice(self.source);
                        const arity = std.fmt.parseInt(u32, arity_text, 10) catch 0;

                        // Extract module name from the object expression
                        const mod_name: ?ast.StructName = switch (expr.*) {
                            .module_ref => |mr| mr.name,
                            else => null,
                        };

                        expr = try self.create(ast.Expr, .{
                            .function_ref = .{
                                .meta = .{ .span = ast.SourceSpan.merge(expr.getMeta().span, ast.SourceSpan.from(arity_tok.loc)) },
                                .module = mod_name,
                                .function = field_name,
                                .arity = arity,
                            },
                        });
                        break;
                    } else {
                        // Not a function ref — restore and fall through to field_access
                        self.lexer = saved_lexer;
                        self.current = saved_current;
                        self.previous = saved_previous;
                    }
                }

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
            .char_literal => return self.parseCharLiteral(),
            .float_literal => return self.parseFloatLiteral(),
            .string_literal => return self.parseStringLiteral(),
            .string_literal_start => return self.parseStringInterpolation(),
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
            .left_angle_angle => return self.parseBinaryExpr(),
            .keyword_if => return self.parseIfExpr(),
            .keyword_case => return self.parseCaseExpr(),
            .keyword_cond => return self.parseCondExpr(),
            .keyword_for => return self.parseForExpr(),
            .keyword_quote => return self.parseQuoteExpr(),
            .keyword_unquote => return self.parseUnquoteExpr(),
            .keyword_unquote_splicing => return self.parseUnquoteSplicingExpr(),
            .keyword_panic => return self.parsePanicExpr(),
            .keyword_fn => return self.parseAnonymousFunctionExpr(),
            .at_sign => return self.parseAtSignExpr(),
            .ampersand => return self.parseFunctionRefExpr(),
            .sigil_prefix => return self.parseSigilExpr(),
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
                    "expressions start with a value (number, string, variable), an operator, or a keyword like `if` or `case`",
                );
                return error.ParseError;
            },
        }
    }

    fn parseFunctionRefExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.ampersand);

        var module_name: ?ast.StructName = null;
        var function_name: ast.StringId = undefined;

        if (self.check(.module_identifier)) {
            module_name = try self.parseStructName();
            _ = try self.expect(.dot);
            const function_tok = try self.expect(.identifier);
            function_name = try self.internToken(function_tok);
        } else {
            const function_tok = try self.expect(.identifier);
            function_name = try self.internToken(function_tok);
        }

        _ = try self.expect(.slash);
        const arity_tok = try self.expect(.int_literal);
        const arity_text = arity_tok.slice(self.source);
        const arity = std.fmt.parseInt(u32, arity_text, 10) catch 0;

        return self.create(ast.Expr, .{
            .function_ref = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, ast.SourceSpan.from(arity_tok.loc)) },
                .module = module_name,
                .function = function_name,
                .arity = arity,
            },
        });
    }

    fn parseAnonymousFunctionExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_fn);

        const synthesized_name = try std.fmt.allocPrint(self.allocator, "__anon_fn_{d}", .{self.anon_function_counter});
        self.anon_function_counter += 1;
        const name = try self.interner.intern(synthesized_name);

        const clause = try self.parseFunctionClause(start);
        const decl = try self.create(ast.FunctionDecl, .{
            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
            .name = name,
            .clauses = try self.allocator.dupe(ast.FunctionClause, &[_]ast.FunctionClause{clause}),
            .visibility = .private,
        });

        return try self.create(ast.Expr, .{
            .anonymous_function = .{
                .meta = .{ .span = decl.meta.span },
                .decl = decl,
            },
        });
    }

    // ============================================================
    // Literal parsing
    // ============================================================

    fn parseIntLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const text = self.stripNumericUnderscores(tok.slice(self.source));
        const value = std.fmt.parseInt(i64, text, 0) catch 0;
        return self.create(ast.Expr, .{
            .int_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = value },
        });
    }

    fn parseCharLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const text = tok.slice(self.source); // e.g. "?A", "?\\n", "?\\x1b"
        const value: i64 = if (text.len >= 3 and text[1] == '\\') blk: {
            // Escape sequence
            break :blk switch (text[2]) {
                'n' => 10,
                't' => 9,
                'r' => 13,
                's' => 32,
                '\\' => 92,
                '0' => 0,
                'a' => 7,
                'e' => 27,
                'x', 'X' => if (text.len > 3)
                    std.fmt.parseInt(i64, text[3..], 16) catch 0
                else
                    0,
                else => text[2],
            };
        } else if (text.len >= 2) blk: {
            break :blk @intCast(text[1]);
        } else blk: {
            break :blk 0;
        };
        return self.create(ast.Expr, .{
            .int_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = value },
        });
    }

    fn parseFloatLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const text = self.stripNumericUnderscores(tok.slice(self.source));
        const value = std.fmt.parseFloat(f64, text) catch 0.0;
        return self.create(ast.Expr, .{
            .float_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = value },
        });
    }

    fn parseStringLiteral(self: *Parser) !*const ast.Expr {
        const tok = self.advance();
        const raw = tok.slice(self.source);

        // Heredoc: """content""" — strip 3 quotes each side, then strip indentation
        const is_heredoc = raw.len >= 6 and raw[0] == '"' and raw[1] == '"' and raw[2] == '"';
        const stripped = if (is_heredoc)
            stripHeredocIndent(raw[3 .. raw.len - 3])
        else if (raw.len >= 2)
            raw[1 .. raw.len - 1]
        else
            raw;

        const value = self.unescapeString(stripped);
        return self.create(ast.Expr, .{
            .string_literal = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) }, .value = try self.interner.intern(value) },
        });
    }

    /// Strip indentation from heredoc content.
    /// The indentation of the closing line (last line) determines strip amount.
    fn stripHeredocIndent(content: []const u8) []const u8 {
        if (content.len == 0) return content;

        // Skip leading newline (content starts after opening """ line)
        var start: usize = 0;
        if (content[0] == '\n') start = 1;

        // Find the last line — its leading whitespace is the indent to strip
        var indent: usize = 0;
        var last_line_start: usize = start;
        for (content[start..], start..) |ch, i| {
            if (ch == '\n') last_line_start = i + 1;
        }
        // Count whitespace on the last line
        var i = last_line_start;
        while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {
            indent += 1;
        }

        // If last line is only whitespace, strip it and use its indent
        const end = if (last_line_start > start and i >= content.len)
            last_line_start - 1 // remove trailing newline before closing indent line
        else
            content.len;

        // Return content between start and end (indent stripping of individual
        // lines would require allocation — for now we trim the envelope)
        if (start >= end or indent == 0) {
            if (start >= content.len) return "";
            return if (end <= content.len) content[start..end] else content[start..];
        }
        // Can't allocate in a pure function, so return trimmed without per-line strip
        if (start >= content.len) return "";
        return content[start..end];
    }

    fn parseStringInterpolation(self: *Parser) !*const ast.Expr {
        const start_tok = self.advance(); // consume string_literal_start
        var parts: std.ArrayList(ast.StringPart) = .empty;

        // Add the literal prefix (strip opening quote, unescape)
        const prefix_raw = start_tok.slice(self.source);
        const prefix_stripped = if (prefix_raw.len > 0 and prefix_raw[0] == '"') prefix_raw[1..] else prefix_raw;
        const prefix = self.unescapeString(prefix_stripped);
        if (prefix.len > 0) {
            try parts.append(self.allocator, .{ .literal = try self.interner.intern(prefix) });
        }

        // Parse first interpolation expression
        const first_expr = try self.parseExpr();
        try parts.append(self.allocator, .{ .expr = first_expr });

        // Continue: string_literal_part (more interpolations) or string_literal_end
        while (true) {
            switch (self.peek()) {
                .string_literal_part => {
                    const part_tok = self.advance();
                    const part_raw = self.unescapeString(part_tok.slice(self.source));
                    if (part_raw.len > 0) {
                        try parts.append(self.allocator, .{ .literal = try self.interner.intern(part_raw) });
                    }
                    const expr = try self.parseExpr();
                    try parts.append(self.allocator, .{ .expr = expr });
                },
                .string_literal_end => {
                    const end_tok = self.advance();
                    const end_raw = end_tok.slice(self.source);
                    // Strip closing quote, unescape
                    const suffix_stripped = if (end_raw.len > 0 and end_raw[end_raw.len - 1] == '"') end_raw[0 .. end_raw.len - 1] else end_raw;
                    const suffix = self.unescapeString(suffix_stripped);
                    if (suffix.len > 0) {
                        try parts.append(self.allocator, .{ .literal = try self.interner.intern(suffix) });
                    }
                    break;
                },
                else => {
                    try self.addRichError(
                        "unterminated string interpolation",
                        self.currentSpan(),
                        "expected continuation or end of interpolated string",
                        "close the interpolation with }",
                    );
                    return error.ParseError;
                },
            }
        }

        return self.create(ast.Expr, .{
            .string_interpolation = .{
                .meta = .{ .span = ast.SourceSpan.from(start_tok.loc) },
                .parts = try parts.toOwnedSlice(self.allocator),
            },
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

    fn parseForExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_for);

        const var_tok = try self.expect(.identifier);
        const var_name = try self.internToken(var_tok);
        _ = try self.expect(.back_arrow); // <-
        const iterable = try self.parseExpr();

        // Optional filter: for x <- list, x > 0 { ... }
        var filter: ?*const ast.Expr = null;
        if (self.match(.comma)) {
            filter = try self.parseExpr();
        }

        self.skipNewlines();
        _ = try self.expect(.left_brace);
        self.skipNewlines();
        const body = try self.parseExpr();
        self.skipNewlines();
        _ = try self.expect(.right_brace);

        return self.create(ast.Expr, .{
            .for_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .var_name = var_name,
                .iterable = iterable,
                .filter = filter,
                .body = body,
            },
        });
    }

    fn parseModuleRefExpr(self: *Parser) !*const ast.Expr {
        const name = try self.parseStructName();
        return self.create(ast.Expr, .{
            .module_ref = .{ .meta = .{ .span = name.span }, .name = name },
        });
    }

    /// Parse a block expression: { stmt; stmt; ... expr }
    /// The block's value is the last expression.
    fn parseBlockExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.left_brace);
        self.skipNewlines();

        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;
            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);
            self.skipNewlines();
        }

        _ = try self.expect(.right_brace);

        return self.create(ast.Expr, .{
            .block = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .stmts = try stmts.toOwnedSlice(self.allocator),
            },
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
            // Keyword list sugar: [key: value, ...] → [{:key, value}, ...]
            if (self.check(.identifier)) {
                const saved = self.saveLexerState();
                const key_tok = self.advance();
                if (self.check(.colon)) {
                    _ = self.advance(); // consume colon
                    const key_name = try self.internToken(key_tok);
                    const value = try self.parseExpr();
                    // Desugar to {:key, value} tuple
                    const atom_key = try self.create(ast.Expr, .{
                        .atom_literal = .{ .meta = .{ .span = ast.SourceSpan.from(key_tok.loc) }, .value = key_name },
                    });
                    const tuple = try self.create(ast.Expr, .{
                        .tuple = .{
                            .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(key_tok.loc), self.previousSpan()) },
                            .elements = try self.allocator.dupe(*const ast.Expr, &.{ atom_key, value }),
                        },
                    });
                    try elements.append(self.allocator, tuple);
                    if (!self.match(.comma)) break;
                    continue;
                } else {
                    self.restoreLexerState(saved);
                }
            }
            const elem = try self.parseExpr();
            try elements.append(self.allocator, elem);
            // List cons expression: [head | tail]
            if (self.check(.pipe)) {
                _ = self.advance(); // consume |
                const tail = try self.parseExpr();
                _ = try self.expect(.right_bracket);
                // Build nested cons: for [a, b | tail], create cons(a, cons(b, tail))
                var result: *const ast.Expr = tail;
                var i = elements.items.len;
                while (i > 0) {
                    i -= 1;
                    result = try self.create(ast.Expr, .{
                        .list_cons_expr = .{
                            .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                            .head = elements.items[i],
                            .tail = result,
                        },
                    });
                }
                return result;
            }
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

        // Check for map update: %{expr | key: value, ...}
        var update_source: ?*const ast.Expr = null;
        if (self.check(.identifier)) {
            const saved = self.saveLexerState();
            const id_tok = self.advance();
            if (self.check(.pipe)) {
                // This is %{var | ...} — map update syntax
                _ = self.advance(); // consume |
                update_source = try self.create(ast.Expr, .{
                    .var_ref = .{ .meta = .{ .span = ast.SourceSpan.from(id_tok.loc) }, .name = try self.internToken(id_tok) },
                });
            } else {
                self.restoreLexerState(saved);
            }
        }

        // Parse key:value fields — could be map (key -> value) or struct (name: value)
        // Detect struct fields (identifier followed by colon) vs map fields (expr followed by arrow)
        var struct_fields: std.ArrayList(ast.StructField) = .empty;
        var map_fields: std.ArrayList(ast.MapField) = .empty;
        var is_struct = false;
        var is_map = false;

        while (!self.check(.right_brace) and !self.check(.eof)) {
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

        while (self.check(.newline)) {
            _ = self.advance();
        }
        _ = try self.expect(.right_brace);

        // Check for :: Type annotation (converts to struct expression)
        if (self.check(.double_colon)) {
            _ = self.advance(); // consume ::
            const type_name = try self.parseStructName();
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
            // Struct fields without :: Type — treat as map with atom keys.
            // %{name: "alice"} is shorthand for %{:name => "alice"}.
            for (struct_fields.items) |sf| {
                const key_atom = try self.create(ast.Expr, .{
                    .atom_literal = .{
                        .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                        .value = sf.name,
                    },
                });
                try map_fields.append(self.allocator, .{ .key = key_atom, .value = sf.value });
            }
            return self.create(ast.Expr, .{
                .map = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .update_source = update_source,
                    .fields = try map_fields.toOwnedSlice(self.allocator),
                },
            });
        }

        return self.create(ast.Expr, .{
            .map = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .update_source = update_source,
                .fields = try map_fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseStructExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.percent);

        const module_name = try self.parseStructName();
        _ = try self.expect(.left_brace);

        // Support multiline: %Name{\n  field: val,\n  ...\n}
        self.skipNewlines();

        // Check for struct update: %Name{expr | field: val, ...}
        var update_source: ?*const ast.Expr = null;
        if (self.check(.identifier)) {
            const saved = self.saveLexerState();
            const id_tok = self.advance();
            if (self.check(.pipe)) {
                _ = self.advance(); // consume |
                update_source = try self.create(ast.Expr, .{
                    .var_ref = .{ .meta = .{ .span = ast.SourceSpan.from(id_tok.loc) }, .name = try self.internToken(id_tok) },
                });
            } else {
                self.restoreLexerState(saved);
            }
        }

        var fields: std.ArrayList(ast.StructField) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            const field_tok = try self.expect(.identifier);
            const field_name = try self.internToken(field_tok);
            _ = try self.expect(.colon);
            const value = try self.parseExpr();
            try fields.append(self.allocator, .{ .name = field_name, .value = value });
            if (!self.match(.comma)) break;
        }

        self.skipNewlines();
        _ = try self.expect(.right_brace);

        return self.create(ast.Expr, .{
            .struct_expr = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .module_name = module_name,
                .update_source = update_source,
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

        _ = try self.expect(.left_brace);
        self.skipNewlines();

        const then_block = try self.parseBlock();

        self.skipNewlines();
        _ = try self.expect(.right_brace);
        self.skipNewlines();

        var else_block: ?[]const ast.Stmt = null;
        if (self.match(.keyword_else)) {
            _ = try self.expect(.left_brace);
            self.skipNewlines();
            else_block = try self.parseBlock();
            self.skipNewlines();
            _ = try self.expect(.right_brace);
        }

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

        _ = try self.expect(.left_brace);
        self.skipNewlines();

        var clauses: std.ArrayList(ast.CaseClause) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            const clause = try self.parseCaseClause();
            try clauses.append(self.allocator, clause);
            self.skipNewlines();
        }

        self.skipNewlines();
        _ = try self.expect(.right_brace);

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
            guard = try self.parseGuardExpr();
        }

        _ = try self.expect(.arrow);

        // Case arm body: three forms
        // 1. Same-line expression:  pattern -> expr
        // 2. Multi-statement block: pattern ->\n  { stmts }
        // 3. Same-line tuple/map:   pattern -> {:ok, v}  (expression starting with {)
        var body: []const ast.Stmt = undefined;
        if (self.check(.newline)) {
            // After newline: check if next non-newline token is { for braced block
            self.skipNewlines();
            if (self.check(.left_brace)) {
                _ = self.advance();
                self.skipNewlines();
                body = try self.parseBlock();
                self.skipNewlines();
                _ = try self.expect(.right_brace);
            } else {
                // Single expression on next line
                const expr = try self.parseExpr();
                const stmts = try self.allocator.alloc(ast.Stmt, 1);
                stmts[0] = .{ .expr = expr };
                body = stmts;
            }
        } else {
            // Same line: always parse as single expression (handles tuples like {:ok, v})
            const expr = try self.parseExpr();
            const stmts = try self.allocator.alloc(ast.Stmt, 1);
            stmts[0] = .{ .expr = expr };
            body = stmts;
        }

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
        _ = try self.expect(.left_brace);
        self.skipNewlines();

        var clauses: std.ArrayList(ast.CondClause) = .empty;

        while (!self.check(.right_brace) and !self.check(.eof)) {
            self.skipNewlines();
            if (self.check(.right_brace)) break;

            const clause_start = self.currentSpan();
            const condition = try self.parseExpr();
            _ = try self.expect(.arrow);

            // Single expression or braced block for clause body
            var body: []const ast.Stmt = undefined;
            if (self.check(.left_brace)) {
                _ = self.advance();
                self.skipNewlines();
                body = try self.parseBlock();
                self.skipNewlines();
                _ = try self.expect(.right_brace);
            } else {
                const expr = try self.parseExpr();
                const stmts = try self.allocator.alloc(ast.Stmt, 1);
                stmts[0] = .{ .expr = expr };
                body = stmts;
            }

            try clauses.append(self.allocator, .{
                .meta = .{ .span = ast.SourceSpan.merge(clause_start, self.previousSpan()) },
                .condition = condition,
                .body = body,
            });
            self.skipNewlines();
        }

        self.skipNewlines();
        _ = try self.expect(.right_brace);

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
        _ = try self.expect(.left_brace);
        self.skipNewlines();

        const body = try self.parseBlock();

        self.skipNewlines();
        _ = try self.expect(.right_brace);

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

    fn parseUnquoteSplicingExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.keyword_unquote_splicing);
        _ = try self.expect(.left_paren);
        const expr = try self.parseExpr();
        _ = try self.expect(.right_paren);

        return self.create(ast.Expr, .{
            .unquote_splicing_expr = .{
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

    /// Parse a sigil expression: ~x"content" or ~abc"""heredoc"""
    /// Desugars to sigil_x("content", []) — a regular function call.
    /// All sigils desugar to sigil_NAME(content, []) — a regular function call.
    /// Sigil implementations are defined in Zap code (Kernel for built-ins).
    fn parseSigilExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        const sigil_tok = self.advance();
        const sigil_text = sigil_tok.slice(self.source);
        const sigil_name = sigil_text[1..];

        const string_expr = if (self.check(.string_literal))
            try self.parseStringLiteral()
        else if (self.check(.string_literal_start))
            try self.parseStringInterpolation()
        else {
            try self.addRichError(
                "sigil must be followed by a string",
                start,
                "expected a string after the sigil",
                "sigils must be followed by a string literal: ~x\"content\"",
            );
            return error.ParseError;
        };

        const func_name = try std.fmt.allocPrint(self.allocator, "sigil_{s}", .{sigil_name});
        const func_id = try self.interner.intern(func_name);

        const empty_list = try self.create(ast.Expr, .{
            .list = .{ .meta = .{ .span = start }, .elements = &.{} },
        });
        const callee = try self.create(ast.Expr, .{
            .var_ref = .{ .meta = .{ .span = start }, .name = func_id },
        });
        return self.create(ast.Expr, .{
            .call = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .callee = callee,
                .args = try self.allocator.dupe(*const ast.Expr, &.{ string_expr, empty_list }),
            },
        });
    }

    /// Disambiguate @name(args) (intrinsic call) from @name (attribute reference).
    /// If @ identifier is followed by (, it's an intrinsic. Otherwise it's an attr ref.
    fn parseAtSignExpr(self: *Parser) !*const ast.Expr {
        // Peek ahead: @ identifier ( → intrinsic, @ identifier → attr ref
        const start = self.currentSpan();
        if (self.peekNext() == .identifier) {
            // Look two tokens ahead (past @, past identifier) for (
            // We can't easily peek that far, so consume @ and identifier,
            // then check for (
            _ = self.advance(); // consume @
            const name_tok = self.advance(); // consume identifier
            const name = try self.internToken(name_tok);

            if (self.check(.left_paren)) {
                // Intrinsic call: @name(args...)
                _ = self.advance(); // consume (
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

            // Attribute reference: @name
            return self.create(ast.Expr, .{
                .attr_ref = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .name = name,
                },
            });
        }

        // Fall back to intrinsic parsing for other patterns
        return self.parseIntrinsicExpr();
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
                const text = self.stripNumericUnderscores(tok.slice(self.source));
                const value = std.fmt.parseInt(i64, text, 0) catch 0;
                return self.create(ast.Pattern, .{
                    .literal = .{ .int = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = value,
                    } },
                });
            },
            .char_literal => {
                // ?A → 65 — parse as int literal pattern
                const tok = self.advance();
                const text = tok.slice(self.source);
                const value: i64 = if (text.len >= 3 and text[1] == '\\') blk: {
                    break :blk switch (text[2]) {
                        'n' => 10, 't' => 9, 'r' => 13, 's' => 32,
                        '\\' => 92, '0' => 0, 'a' => 7, 'e' => 27,
                        'x', 'X' => if (text.len > 3)
                            std.fmt.parseInt(i64, text[3..], 16) catch 0
                        else
                            0,
                        else => text[2],
                    };
                } else if (text.len >= 2) @intCast(text[1]) else 0;
                return self.create(ast.Pattern, .{
                    .literal = .{ .int = .{
                        .meta = .{ .span = ast.SourceSpan.from(tok.loc) },
                        .value = value,
                    } },
                });
            },
            .float_literal => {
                const tok = self.advance();
                const text = self.stripNumericUnderscores(tok.slice(self.source));
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
            .left_angle_angle => return self.parseBinaryPattern(),
            .caret => return self.parsePinPattern(),
            .left_paren => return self.parseParenPattern(),
            .minus => {
                const start = self.currentSpan();
                _ = self.advance();
                if (self.check(.int_literal)) {
                    const tok = self.advance();
                    const text = self.stripNumericUnderscores(tok.slice(self.source));
                    const value = std.fmt.parseInt(i64, text, 0) catch 0;
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

        while (!self.check(.right_bracket) and !self.check(.pipe) and !self.check(.eof)) {
            // Keyword list pattern sugar: [key: pat, ...] → [{:key, pat}, ...]
            if (self.check(.identifier)) {
                const saved = self.saveLexerState();
                const key_tok = self.advance();
                if (self.check(.colon)) {
                    _ = self.advance(); // consume colon
                    const key_name = try self.internToken(key_tok);
                    const value_pat = try self.parsePattern();
                    // Desugar to {:key, pattern} tuple pattern
                    const atom_key = try self.create(ast.Pattern, .{
                        .literal = .{ .atom = .{ .meta = .{ .span = ast.SourceSpan.from(key_tok.loc) }, .value = key_name } },
                    });
                    const tuple = try self.create(ast.Pattern, .{
                        .tuple = .{
                            .meta = .{ .span = ast.SourceSpan.merge(ast.SourceSpan.from(key_tok.loc), self.previousSpan()) },
                            .elements = try self.allocator.dupe(*const ast.Pattern, &.{ atom_key, value_pat }),
                        },
                    });
                    try elements.append(self.allocator, tuple);
                    if (!self.match(.comma)) break;
                    continue;
                } else {
                    self.restoreLexerState(saved);
                }
            }
            const elem = try self.parsePattern();
            try elements.append(self.allocator, elem);
            if (!self.match(.comma)) break;
        }

        // Check for [head | tail] cons pattern
        if (self.check(.pipe)) {
            _ = self.advance(); // consume |
            const tail = try self.parsePattern();
            _ = try self.expect(.right_bracket);
            return self.create(ast.Pattern, .{
                .list_cons = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .heads = try elements.toOwnedSlice(self.allocator),
                    .tail = tail,
                },
            });
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

        const module_name = try self.parseStructName();

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
    // Binary expression/pattern parsing
    // ============================================================

    fn parseBinaryExpr(self: *Parser) !*const ast.Expr {
        const start = self.currentSpan();
        _ = try self.expect(.left_angle_angle);

        var segments: std.ArrayList(ast.BinarySegment) = .empty;

        if (!self.check(.right_angle_angle)) {
            while (true) {
                const seg = try self.parseBinarySegment(.expr);
                try segments.append(self.allocator, seg);
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.right_angle_angle);

        return self.create(ast.Expr, .{
            .binary_literal = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .segments = try segments.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseBinaryPattern(self: *Parser) !*const ast.Pattern {
        const start = self.currentSpan();
        _ = try self.expect(.left_angle_angle);

        var segments: std.ArrayList(ast.BinarySegment) = .empty;

        if (!self.check(.right_angle_angle)) {
            while (true) {
                const seg = try self.parseBinarySegment(.pattern);
                try segments.append(self.allocator, seg);
                if (!self.match(.comma)) break;
            }
        }

        _ = try self.expect(.right_angle_angle);

        return self.create(ast.Pattern, .{
            .binary = .{
                .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                .segments = try segments.toOwnedSlice(self.allocator),
            },
        });
    }

    const BinarySegmentContext = enum { expr, pattern };

    fn parseBinarySegment(self: *Parser, context: BinarySegmentContext) !ast.BinarySegment {
        const seg_start = self.currentSpan();

        // Parse value: could be a string literal (prefix match), int literal, or identifier (variable/wildcard)
        const value: ast.BinarySegmentValue = blk: {
            if (self.check(.string_literal)) {
                // String literal in binary: <<"GET "::String, rest::String>>
                const tok = self.advance();
                const raw = tok.slice(self.source);
                const str_val = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                break :blk .{ .string_literal = try self.interner.intern(str_val) };
            }
            if (context == .pattern) {
                break :blk .{ .pattern = try self.parsePattern() };
            } else {
                break :blk .{ .expr = try self.parseExpr() };
            }
        };

        // Parse optional ::type-endianness-size(n) specifier
        var type_spec: ast.BinarySegmentType = .default;
        var endianness: ast.Endianness = .big;
        var size: ?ast.BinarySegmentSize = null;

        if (self.check(.double_colon)) {
            _ = self.advance(); // consume ::

            // Parse type specifier from identifier
            if (self.check(.identifier) or self.check(.module_identifier)) {
                const type_tok = self.advance();
                const type_text = type_tok.slice(self.source);
                type_spec = parseBinaryTypeSpec(type_text);

                // Parse optional endianness: -big, -little, -native
                if (self.check(.minus)) {
                    _ = self.advance();
                    if (self.check(.identifier)) {
                        const end_tok = self.advance();
                        const end_text = end_tok.slice(self.source);
                        if (std.mem.eql(u8, end_text, "big")) {
                            endianness = .big;
                        } else if (std.mem.eql(u8, end_text, "little")) {
                            endianness = .little;
                        } else if (std.mem.eql(u8, end_text, "native")) {
                            endianness = .native;
                        } else if (std.mem.eql(u8, end_text, "size")) {
                            // String-size(n) syntax
                            _ = try self.expect(.left_paren);
                            size = try self.parseBinarySize();
                            _ = try self.expect(.right_paren);
                        }
                    }
                }
            }
        }

        return .{
            .meta = .{ .span = ast.SourceSpan.merge(seg_start, self.previousSpan()) },
            .value = value,
            .type_spec = type_spec,
            .endianness = endianness,
            .size = size,
        };
    }

    fn parseBinarySize(self: *Parser) !ast.BinarySegmentSize {
        if (self.check(.int_literal)) {
            const tok = self.advance();
            const text = self.stripNumericUnderscores(tok.slice(self.source));
            const value = std.fmt.parseInt(u32, text, 0) catch 0;
            return .{ .literal = value };
        }
        if (self.check(.identifier)) {
            const tok = self.advance();
            return .{ .variable = try self.internToken(tok) };
        }
        try self.addRichError(
            "I was expecting a size value (number or variable)",
            self.currentSpan(),
            null,
            "e.g., `size(4)` or `size(length)`",
        );
        return error.ParseError;
    }

    fn parseBinaryTypeSpec(text: []const u8) ast.BinarySegmentType {
        // Integer types: u8, u16, u32, u64, i8, i16, i32, i64, and arbitrary widths
        if (text.len >= 2 and (text[0] == 'u' or text[0] == 'i')) {
            const signed = text[0] == 'i';
            if (std.fmt.parseInt(u16, text[1..], 10)) |bits| {
                return .{ .integer = .{ .signed = signed, .bits = bits } };
            } else |_| {}
        }
        // Float types: f16, f32, f64
        if (text.len >= 2 and text[0] == 'f') {
            if (std.fmt.parseInt(u16, text[1..], 10)) |bits| {
                if (bits == 16 or bits == 32 or bits == 64) {
                    return .{ .float = .{ .bits = bits } };
                }
            } else |_| {}
        }
        // String type
        if (std.mem.eql(u8, text, "String")) return .string;
        // UTF types
        if (std.mem.eql(u8, text, "utf8")) return .utf8;
        if (std.mem.eql(u8, text, "utf16")) return .utf16;
        if (std.mem.eql(u8, text, "utf32")) return .utf32;
        // Default to u8 for unknown types
        return .default;
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
            const return_q = try self.parseOptionalOwnershipQualifier();
            const return_type = try self.parseTypeExpr();
            _ = try self.expect(.right_paren);
            return self.create(ast.TypeExpr, .{
                .function = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .params = &[_]*const ast.TypeExpr{},
                    .param_ownerships = &[_]ast.Ownership{},
                    .param_ownerships_explicit = &[_]bool{},
                    .return_type = return_type,
                    .return_ownership = return_q.ownership,
                    .return_ownership_explicit = return_q.explicit,
                },
            });
        }

        const first_q = try self.parseOptionalOwnershipQualifier();
        const first = try self.parseTypeExpr();

        if (self.check(.arrow)) {
            _ = self.advance();
            const return_q = try self.parseOptionalOwnershipQualifier();
            const return_type = try self.parseTypeExpr();
            _ = try self.expect(.right_paren);
            return self.create(ast.TypeExpr, .{
                .function = .{
                    .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                    .params = try self.allocator.dupe(*const ast.TypeExpr, &[_]*const ast.TypeExpr{first}),
                    .param_ownerships = try self.allocator.dupe(ast.Ownership, &[_]ast.Ownership{first_q.ownership}),
                    .param_ownerships_explicit = try self.allocator.dupe(bool, &[_]bool{first_q.explicit}),
                    .return_type = return_type,
                    .return_ownership = return_q.ownership,
                    .return_ownership_explicit = return_q.explicit,
                },
            });
        }

        if (self.check(.comma)) {
            var params: std.ArrayList(*const ast.TypeExpr) = .empty;
            var param_ownerships: std.ArrayList(ast.Ownership) = .empty;
            var param_ownerships_explicit: std.ArrayList(bool) = .empty;
            try params.append(self.allocator, first);
            try param_ownerships.append(self.allocator, first_q.ownership);
            try param_ownerships_explicit.append(self.allocator, first_q.explicit);
            while (self.match(.comma)) {
                if (self.check(.arrow)) break;
                const ownership = try self.parseOptionalOwnershipQualifier();
                const param = try self.parseTypeExpr();
                try params.append(self.allocator, param);
                try param_ownerships.append(self.allocator, ownership.ownership);
                try param_ownerships_explicit.append(self.allocator, ownership.explicit);
            }
            if (self.check(.arrow)) {
                _ = self.advance();
                const return_q = try self.parseOptionalOwnershipQualifier();
                const return_type = try self.parseTypeExpr();
                _ = try self.expect(.right_paren);
                return self.create(ast.TypeExpr, .{
                    .function = .{
                        .meta = .{ .span = ast.SourceSpan.merge(start, self.previousSpan()) },
                        .params = try params.toOwnedSlice(self.allocator),
                        .param_ownerships = try param_ownerships.toOwnedSlice(self.allocator),
                        .param_ownerships_explicit = try param_ownerships_explicit.toOwnedSlice(self.allocator),
                        .return_type = return_type,
                        .return_ownership = return_q.ownership,
                        .return_ownership_explicit = return_q.explicit,
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

    fn parseOptionalOwnershipQualifier(self: *Parser) !struct { ownership: ast.Ownership, explicit: bool } {
        if (self.match(.keyword_shared)) return .{ .ownership = .shared, .explicit = true };
        if (self.match(.keyword_unique)) return .{ .ownership = .unique, .explicit = true };
        if (self.match(.keyword_borrowed)) return .{ .ownership = .borrowed, .explicit = true };
        return .{ .ownership = .shared, .explicit = false };
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

        const module_name = try self.parseStructName();

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
        var text = tok.slice(self.source);

        if (std.mem.eql(u8, text, "Never")) {
            return self.create(ast.TypeExpr, .{
                .never = .{ .meta = .{ .span = ast.SourceSpan.from(tok.loc) } },
            });
        }

        // Handle dot-separated type names (e.g., Zap.Project)
        if (tok.tag == .module_identifier) {
            while (self.check(.dot)) {
                const saved_lexer = self.lexer;
                const saved_current = self.current;
                const saved_previous = self.previous;
                _ = self.advance(); // consume dot
                if (self.check(.module_identifier) or self.check(.identifier)) {
                    const part = self.advance();
                    const part_text = part.slice(self.source);
                    text = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ text, part_text });
                } else {
                    // Not a type name continuation — restore the dot
                    self.lexer = saved_lexer;
                    self.current = saved_current;
                    self.previous = saved_previous;
                    break;
                }
            }
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
                "i8",    "i16", "i32", "i64",
                "u8",    "u16", "u32", "u64",
                "f16",   "f32", "f64", "usize",
                "isize",
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
            .binary_literal => |v| {
                return self.create(ast.Pattern, .{
                    .binary = .{ .meta = v.meta, .segments = v.segments },
                });
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
        .keyword_pub => "`pub`",
        .keyword_fn => "`fn`",
        .keyword_macro => "`macro`",
        .keyword_struct => "`struct`",
        .keyword_union => "`union`",
        .keyword_if => "`if`",
        .keyword_else => "`else`",
        .keyword_case => "`case`",
        .keyword_cond => "`cond`",
        .keyword_type => "`type`",
        .keyword_opaque => "`opaque`",
        .keyword_alias => "`alias`",
        .keyword_import => "`import`",
        .keyword_quote => "`quote`",
        .keyword_unquote => "`unquote`",
        .keyword_unquote_splicing => "`unquote_splicing`",
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
        .left_angle_angle => "`<<`",
        .right_angle_angle => "`>>`",
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
        .eof => "end of file",
        .invalid => "an invalid token",
        .tilde_arrow => "`~>`",
        .double_ampersand => "`&&`",
        .double_pipe => "`||`",
        .plus_plus => "`++`",
        else => Token.tagName(tag),
    };
}

// ============================================================
// Tests
// ============================================================

test "top-level fn is rejected" {
    const source =
        \\fn foo() {
        \\  42
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const result = parser.parseProgram();
    try std.testing.expectError(error.ParseError, result);
}

test "top-level pub fn is also rejected" {
    const source =
        \\pub fn foo() {
        \\  42
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const result = parser.parseProgram();
    try std.testing.expectError(error.ParseError, result);
}

test "parse simple function" {
    const source =
        \\pub struct Test {
        \\  pub fn add(x :: i64, y :: i64) -> i64 {
        \\    x + y
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 1), program.structs[0].items.len);
    try std.testing.expect(program.structs[0].items[0] == .function);
    try std.testing.expectEqual(ast.Ownership.shared, program.structs[0].items[0].function.clauses[0].params[0].ownership);
}

test "parse unique param ownership annotation" {
    const source =
        \\pub struct Test {
        \\  pub fn use(handle :: unique String) {
        \\    handle
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(ast.Ownership.unique, program.structs[0].items[0].function.clauses[0].params[0].ownership);
}

test "parse borrowed param ownership annotation" {
    const source =
        \\pub struct Test {
        \\  pub fn use(handle :: borrowed String) {
        \\    handle
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(ast.Ownership.borrowed, program.structs[0].items[0].function.clauses[0].params[0].ownership);
}

test "parse function type ownership annotations" {
    const source =
        \\pub struct Test {
        \\  pub fn apply(f :: (borrowed String -> unique String)) {
        \\    f
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const fn_type = program.structs[0].items[0].function.clauses[0].params[0].type_annotation.?.function;
    try std.testing.expectEqual(ast.Ownership.borrowed, fn_type.param_ownerships[0]);
    try std.testing.expectEqual(ast.Ownership.unique, fn_type.return_ownership);
}

test "parse module" {
    const source =
        \\pub struct Foo {
        \\  pub fn bar() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 1), program.structs[0].items.len);
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
        \\pub struct Test {
        \\  pub fn foo(x :: i64) -> i64 {
        \\    if x > 0 {
        \\      x
        \\    } else {
        \\      0
        \\    }
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
}

test "parse case expression" {
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
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
}

test "parse binary operators" {
    const source =
        \\pub struct Test {
        \\  pub fn calc(x :: i64, y :: i64) -> i64 {
        \\    x + y * 2
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);

    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expectEqual(@as(usize, 1), body.len);

    const expr = body[0].expr;
    try std.testing.expect(expr.* == .binary_op);
    try std.testing.expectEqual(ast.BinaryOp.Op.add, expr.binary_op.op);
}

test "parse tuple and list" {
    const source =
        \\pub struct Test {
        \\  pub fn foo() {
        \\    {1, 2, 3}
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
}

test "parse refinement predicate" {
    const source =
        \\pub struct Test {
        \\  pub fn abs(x :: i64) -> i64 if x < 0 {
        \\    -x
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    try std.testing.expect(func.clauses[0].refinement != null);
}

test "parse assignment" {
    const source =
        \\pub struct Test {
        \\  pub fn foo() {
        \\    x = 42
        \\    x
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expectEqual(@as(usize, 2), body.len);
    try std.testing.expect(body[0] == .assignment);
}

test "parse function call" {
    const source =
        \\pub struct Test {
        \\  pub fn foo() {
        \\    bar(1, 2)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expect(body[0].expr.* == .call);
}

test "parse pipe operator" {
    const source =
        \\pub struct Test {
        \\  pub fn foo(x) {
        \\    x |> bar(1)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expect(body[0].expr.* == .pipe);
}

test "parse struct declaration" {
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
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);

    var found_struct = false;
    for (program.structs[0].items) |item| {
        if (item == .struct_decl) {
            found_struct = true;
            try std.testing.expectEqual(@as(usize, 2), item.struct_decl.fields.len);
        }
    }
    try std.testing.expect(found_struct);
}

test "parse panic expression" {
    const source =
        \\pub struct Test {
        \\  pub fn foo() {
        \\    panic("oops")
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expect(body[0].expr.* == .panic_expr);
}

test "parse local function" {
    const source =
        \\pub struct Test {
        \\  pub fn outer(x :: i64) -> String {
        \\    fn inner(s :: String) -> String {
        \\      s
        \\    }
        \\    inner("ok")
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expect(body.len >= 2);
    try std.testing.expect(body[0] == .function_decl);
}

test "parse module with types and functions" {
    const source =
        \\pub struct Foo {
        \\  type Result(a, e) = {:ok, a} | {:error, e}
        \\
        \\  pub fn b(s :: String) -> String {
        \\    s <> "foo"
        \\  }
        \\
        \\  pub fn a(x :: i64) -> String {
        \\    fn b(n :: i64) -> String {
        \\      int_to_string(n)
        \\    }
        \\    b("other")
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 3), program.structs[0].items.len);
}

test "parse top-level defstruct" {
    const source =
        \\pub struct User {
        \\  name :: String
        \\  age :: i64
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    const sd = program.top_items[0].struct_decl;
    try std.testing.expect(sd.name.parts.len > 0);
    try std.testing.expectEqual(@as(usize, 2), sd.fields.len);
}

test "parse defstruct extends" {
    const source =
        \\pub struct Shape {
        \\  color :: String
        \\}
        \\
        \\pub struct Circle extends Shape {
        \\  radius :: f64
        \\}
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

test "parse union declaration" {
    const source =
        \\pub union Color {
        \\  Red,
        \\  Green,
        \\  Blue
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    const ed = program.top_items[0].union_decl;
    try std.testing.expectEqual(@as(usize, 3), ed.variants.len);
}

test "parse defmodule extends" {
    const source =
        \\pub struct Animal {
        \\  pub fn breathe() -> String {
        \\    "inhale"
        \\  }
        \\}
        \\
        \\pub struct Dog extends Animal {
        \\  pub fn speak() -> String {
        \\    "woof"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), program.structs.len);
    try std.testing.expect(program.structs[1].parent != null);
}

test "parse struct init with type annotation" {
    const source =
        \\pub struct Point {
        \\  x :: f64
        \\  y :: f64
        \\}
        \\
        \\pub struct Test {
        \\  pub fn main() {
        \\    %{x: 1.0, y: 2.0} :: Point
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    // Should have Point (field-only) + Test (module-like)
    try std.testing.expectEqual(@as(usize, 2), program.top_items.len);
    try std.testing.expectEqual(@as(usize, 2), program.structs.len);
    // Test is the second struct (module-like), Point is first (field-only)
    const func = program.structs[1].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expect(body[0].expr.* == .struct_expr);
}

test "parse private struct" {
    const source =
        \\struct Internal {
        \\  pub fn helper() -> i64 {
        \\    42
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expect(program.structs[0].is_private);
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);
    try std.testing.expect(program.top_items[0] == .priv_struct_decl);
}

test "parse defmacrop inside module" {
    const source =
        \\pub struct Foo {
        \\  macro helper(x) {
        \\    x
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 1), program.structs[0].items.len);
    try std.testing.expect(program.structs[0].items[0] == .priv_macro);
    try std.testing.expectEqual(ast.FunctionDecl.Visibility.private, program.structs[0].items[0].priv_macro.visibility);
}

test "parse defmodule is_private false by default" {
    const source =
        \\pub struct Foo {
        \\  pub fn bar() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expect(!program.structs[0].is_private);
}

test "parse typed module attribute" {
    const source =
        \\pub struct Foo {
        \\  @doc :: String = "hello world"
        \\  pub fn bar() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 2), program.structs[0].items.len);
    // First item is the attribute
    try std.testing.expect(program.structs[0].items[0] == .attribute);
    const attr = program.structs[0].items[0].attribute;
    try std.testing.expectEqualStrings("doc", parser.interner.get(attr.name));
    try std.testing.expect(attr.type_expr != null);
    try std.testing.expect(attr.value != null);
    // Second item is the function
    try std.testing.expect(program.structs[0].items[1] == .function);
}

test "parse marker attribute" {
    const source =
        \\pub struct Foo {
        \\  @debug
        \\  pub fn bar() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 2), program.structs[0].items.len);
    const attr = program.structs[0].items[0].attribute;
    try std.testing.expectEqualStrings("debug", parser.interner.get(attr.name));
    try std.testing.expect(attr.type_expr == null);
    try std.testing.expect(attr.value == null);
}

test "parse multiple attributes on same function" {
    const source =
        \\pub struct Foo {
        \\  @doc :: String = "does something"
        \\  @deprecated :: String = "use bar2 instead"
        \\  pub fn bar() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    // 2 attributes + 1 function = 3 items
    try std.testing.expectEqual(@as(usize, 3), program.structs[0].items.len);
    try std.testing.expect(program.structs[0].items[0] == .attribute);
    try std.testing.expect(program.structs[0].items[1] == .attribute);
    try std.testing.expect(program.structs[0].items[2] == .function);

    const doc = program.structs[0].items[0].attribute;
    try std.testing.expectEqualStrings("doc", parser.interner.get(doc.name));

    const dep = program.structs[0].items[1].attribute;
    try std.testing.expectEqualStrings("deprecated", parser.interner.get(dep.name));
}

test "parse module-level attribute" {
    const source =
        \\pub struct Foo {
        \\  @moduledoc :: String = "A module"
        \\  @version :: String = "1.0.0"
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
    try std.testing.expectEqual(@as(usize, 2), program.structs[0].items.len);
    try std.testing.expect(program.structs[0].items[0] == .attribute);
    try std.testing.expect(program.structs[0].items[1] == .attribute);

    const moduledoc = program.structs[0].items[0].attribute;
    try std.testing.expectEqualStrings("moduledoc", parser.interner.get(moduledoc.name));

    const version = program.structs[0].items[1].attribute;
    try std.testing.expectEqualStrings("version", parser.interner.get(version.name));
}

test "parse attribute with integer value" {
    const source =
        \\pub struct Foo {
        \\  @timeout :: i64 = 5000
        \\  pub fn connect() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), program.structs[0].items.len);
    const attr = program.structs[0].items[0].attribute;
    try std.testing.expectEqualStrings("timeout", parser.interner.get(attr.name));
    try std.testing.expect(attr.type_expr != null);
    try std.testing.expect(attr.value != null);
    // Value should be an int literal
    try std.testing.expect(attr.value.?.* == .int_literal);
}

test "parse attribute with list value" {
    const source =
        \\pub struct Foo {
        \\  @flags :: List(Atom) = [:read, :write]
        \\  pub fn connect() -> i64 {
        \\    1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), program.structs[0].items.len);
    const attr = program.structs[0].items[0].attribute;
    try std.testing.expectEqualStrings("flags", parser.interner.get(attr.name));
    try std.testing.expect(attr.value.?.* == .list);
}

test "parse error pipe ~> with block handler" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> String {
        \\    read_file("test.txt")
        \\    |> parse()
        \\    ~> {
        \\      :not_found -> "default"
        \\    }
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expect(body.len > 0);
    // The expression should be an error_pipe
    try std.testing.expect(body[0].expr.* == .error_pipe);
}

test "parse error pipe ~> with function handler" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> String {
        \\    read_file("test.txt")
        \\    |> parse()
        \\    ~> handle_error()
        \\  }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    try std.testing.expect(body.len > 0);
    try std.testing.expect(body[0].expr.* == .error_pipe);
}

test "parse keyword list expression desugars to tuples" {
    const source = "[name: \"Brian\", age: 42]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    // Should be a list of 2 tuple elements
    try std.testing.expect(expr.* == .list);
    try std.testing.expectEqual(@as(usize, 2), expr.list.elements.len);

    // First: {:name, "Brian"}
    const first = expr.list.elements[0];
    try std.testing.expect(first.* == .tuple);
    try std.testing.expectEqual(@as(usize, 2), first.tuple.elements.len);
    try std.testing.expect(first.tuple.elements[0].* == .atom_literal);
    try std.testing.expect(first.tuple.elements[1].* == .string_literal);

    // Second: {:age, 42}
    const second = expr.list.elements[1];
    try std.testing.expect(second.* == .tuple);
    try std.testing.expect(second.tuple.elements[0].* == .atom_literal);
    try std.testing.expect(second.tuple.elements[1].* == .int_literal);
    try std.testing.expectEqual(@as(i64, 42), second.tuple.elements[1].int_literal.value);
}

test "parse keyword list pattern desugars to tuple patterns" {
    const source = "[name: n, age: a]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const pat = try parser.parsePattern();
    try std.testing.expect(pat.* == .list);
    try std.testing.expectEqual(@as(usize, 2), pat.list.elements.len);

    // First: {:name, n} tuple pattern
    const first = pat.list.elements[0];
    try std.testing.expect(first.* == .tuple);
    try std.testing.expectEqual(@as(usize, 2), first.tuple.elements.len);
    try std.testing.expect(first.tuple.elements[0].* == .literal);
    try std.testing.expect(first.tuple.elements[1].* == .bind);
}

test "parse non-keyword list unchanged" {
    const source = "[1, 2, 3]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .list);
    try std.testing.expectEqual(@as(usize, 3), expr.list.elements.len);
    try std.testing.expect(expr.list.elements[0].* == .int_literal);
    try std.testing.expect(expr.list.elements[1].* == .int_literal);
    try std.testing.expect(expr.list.elements[2].* == .int_literal);
}

test "parse for comprehension" {
    const source = "for x <- items { x * 2 }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .for_expr);
    try std.testing.expect(expr.for_expr.filter == null);
    try std.testing.expect(expr.for_expr.iterable.* == .var_ref);
    try std.testing.expect(expr.for_expr.body.* == .binary_op);
}

test "parse for comprehension with filter" {
    const source = "for x <- items, x > 0 { x }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .for_expr);
    try std.testing.expect(expr.for_expr.filter != null);
    try std.testing.expect(expr.for_expr.filter.?.* == .binary_op);
}

test "parse list cons expression [h | t]" {
    const source = "[1 | rest]";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    try std.testing.expect(expr.* == .list_cons_expr);
    try std.testing.expect(expr.list_cons_expr.head.* == .int_literal);
    try std.testing.expect(expr.list_cons_expr.tail.* == .var_ref);
}

test "parse trailing block as last argument" {
    const source = "foo(\"name\") { 1 + 2 }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    // Should be a call with 2 args: "name" and a block
    try std.testing.expect(expr.* == .call);
    try std.testing.expectEqual(@as(usize, 2), expr.call.args.len);
    try std.testing.expect(expr.call.args[0].* == .string_literal);
    try std.testing.expect(expr.call.args[1].* == .block);
}

test "parse nested trailing blocks" {
    const source = "describe(\"math\") { test(\"add\") { 1 + 1 } }";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const expr = try parser.parseExpr();
    // describe("math") { ... } → call with 2 args
    try std.testing.expect(expr.* == .call);
    try std.testing.expectEqual(@as(usize, 2), expr.call.args.len);
    try std.testing.expect(expr.call.args[0].* == .string_literal);
    // The block contains a test(...) { ... } call
    try std.testing.expect(expr.call.args[1].* == .block);
}

test "parse sigil desugars to function call" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> String {
        \\    ~z"hello zig"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    // ~z"hello zig" desugars to sigil_z("hello zig", [])
    try std.testing.expect(expr.* == .call);
    try std.testing.expectEqualStrings("sigil_z", parser.interner.get(expr.call.callee.var_ref.name));
    try std.testing.expectEqual(@as(usize, 2), expr.call.args.len);
    try std.testing.expect(expr.call.args[0].* == .string_literal);
    try std.testing.expect(expr.call.args[1].* == .list);
    try std.testing.expectEqual(@as(usize, 0), expr.call.args[1].list.elements.len);
}

test "parse multi-char sigil" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> String {
        \\    ~sql"SELECT * FROM users"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    try std.testing.expect(expr.* == .call);
    try std.testing.expectEqualStrings("sigil_sql", parser.interner.get(expr.call.callee.var_ref.name));
}

test "parse ~s sigil desugars to sigil_s call" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> String {
        \\    ~s"hello world"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    try std.testing.expect(expr.* == .call);
    try std.testing.expectEqualStrings("sigil_s", parser.interner.get(expr.call.callee.var_ref.name));
    try std.testing.expectEqual(@as(usize, 2), expr.call.args.len);
    try std.testing.expect(expr.call.args[0].* == .string_literal);
    try std.testing.expect(expr.call.args[1].* == .list);
}

test "parse ~w sigil desugars to sigil_w call" {
    const source =
        \\pub struct Test {
        \\  pub fn run() -> String {
        \\    ~w"foo bar baz"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    try std.testing.expect(expr.* == .call);
    try std.testing.expectEqualStrings("sigil_w", parser.interner.get(expr.call.callee.var_ref.name));
}

test "parse &Module.function/arity as function_ref" {
    const source =
        \\pub struct Test {
        \\  pub fn run() {
        \\    &Math.double/1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    try std.testing.expect(expr.* == .function_ref);
    try std.testing.expect(expr.function_ref.module != null);
    try std.testing.expectEqualStrings("Math", parser.interner.get(expr.function_ref.module.?.parts[0]));
    try std.testing.expectEqualStrings("double", parser.interner.get(expr.function_ref.function));
    try std.testing.expectEqual(@as(u32, 1), expr.function_ref.arity);
}

test "parse &function/arity as local function_ref" {
    const source =
        \\pub struct Test {
        \\  pub fn run() {
        \\    &double/1
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    try std.testing.expect(expr.* == .function_ref);
    try std.testing.expect(expr.function_ref.module == null);
    try std.testing.expectEqualStrings("double", parser.interner.get(expr.function_ref.function));
    try std.testing.expectEqual(@as(u32, 1), expr.function_ref.arity);
}

test "parse anonymous function expression" {
    const source =
        \\pub struct Test {
        \\  pub fn run() {
        \\    fn(x :: i64) -> i64 {
        \\      x + 1
        \\    }
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const func = program.structs[0].items[0].function;
    const body = func.clauses[0].body.?;
    const expr = body[0].expr;

    try std.testing.expect(expr.* == .anonymous_function);
    try std.testing.expectEqual(@as(usize, 1), expr.anonymous_function.decl.clauses.len);
    try std.testing.expectEqual(@as(usize, 1), expr.anonymous_function.decl.clauses[0].params.len);
}

test "parse protocol declaration" {
    const source =
        \\pub protocol Enumerable {
        \\  fn each(collection, callback :: (member -> member)) -> collection
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);

    const proto = program.top_items[0].protocol;
    try std.testing.expectEqual(@as(usize, 1), proto.name.parts.len);
    try std.testing.expectEqual(@as(usize, 1), proto.functions.len);
    try std.testing.expectEqual(false, proto.is_private);

    const sig = proto.functions[0];
    try std.testing.expectEqual(@as(usize, 2), sig.params.len);
    // First param: collection (no type annotation)
    try std.testing.expect(sig.params[0].type_annotation == null);
    // Second param: callback (has type annotation)
    try std.testing.expect(sig.params[1].type_annotation != null);
    // Return type present
    try std.testing.expect(sig.return_type != null);
}

test "parse protocol with multiple function signatures" {
    const source =
        \\pub protocol Collection {
        \\  fn size(collection) -> i64
        \\  fn empty?(collection) -> Bool
        \\  fn contains?(collection, value :: member) -> Bool
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const proto = program.top_items[0].protocol;
    try std.testing.expectEqual(@as(usize, 3), proto.functions.len);
    try std.testing.expectEqual(@as(usize, 1), proto.functions[0].params.len);
    try std.testing.expectEqual(@as(usize, 1), proto.functions[1].params.len);
    try std.testing.expectEqual(@as(usize, 2), proto.functions[2].params.len);
}

test "parse impl declaration" {
    const source =
        \\pub impl Enumerable for List {
        \\  pub fn each(list :: [member], callback :: (member -> member)) -> [member] {
        \\    :zig.List.eachFn(list, callback)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.top_items.len);

    const impl_d = program.top_items[0].impl_decl;
    try std.testing.expectEqual(@as(usize, 1), impl_d.protocol_name.parts.len);
    try std.testing.expectEqual(@as(usize, 1), impl_d.target_type.parts.len);
    try std.testing.expectEqual(@as(usize, 1), impl_d.functions.len);
    try std.testing.expectEqual(false, impl_d.is_private);
}

test "parse impl with multiple functions" {
    const source =
        \\pub impl Enumerable for List {
        \\  pub fn each(list :: [member], callback :: (member -> member)) -> [member] {
        \\    :zig.List.eachFn(list, callback)
        \\  }
        \\
        \\  pub fn reduce(list :: [member], acc :: result, callback :: (result, member -> result)) -> result {
        \\    :zig.List.reduceFn(list, acc, callback)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const impl_d = program.top_items[0].impl_decl;
    try std.testing.expectEqual(@as(usize, 2), impl_d.functions.len);
}

test "parse private protocol" {
    const source =
        \\protocol Internal {
        \\  fn process(item) -> item
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const proto = program.top_items[0].priv_protocol;
    try std.testing.expectEqual(true, proto.is_private);
    try std.testing.expectEqual(@as(usize, 1), proto.functions.len);
}

test "parse private impl" {
    const source =
        \\impl Printable for MyType {
        \\  pub fn to_string(value :: MyType) -> String {
        \\    "MyType"
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const impl_d = program.top_items[0].priv_impl_decl;
    try std.testing.expectEqual(true, impl_d.is_private);
    try std.testing.expectEqual(@as(usize, 1), impl_d.functions.len);
}

test "parse impl with generic type parameters" {
    const source =
        \\pub impl Enumerable for Map(K, V) {
        \\  pub fn next(map :: %{K => V}) -> {Atom, {K, V}, %{K => V}} {
        \\    :zig.Map.next(map)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const impl_d = program.top_items[0].impl_decl;
    try std.testing.expectEqual(@as(usize, 1), impl_d.target_type.parts.len);
    try std.testing.expectEqual(@as(usize, 2), impl_d.type_params.len);
    // Verify the parameters are K and V in order
    const k_name = parser.interner.get(impl_d.type_params[0]);
    const v_name = parser.interner.get(impl_d.type_params[1]);
    try std.testing.expectEqualStrings("K", k_name);
    try std.testing.expectEqualStrings("V", v_name);
    try std.testing.expectEqual(@as(usize, 1), impl_d.functions.len);
}

test "parse impl with single type parameter" {
    const source =
        \\pub impl Enumerable for List(T) {
        \\  pub fn next(list :: [T]) -> {Atom, T, [T]} {
        \\    :zig.List.next(list)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const impl_d = program.top_items[0].impl_decl;
    try std.testing.expectEqual(@as(usize, 1), impl_d.type_params.len);
    try std.testing.expectEqualStrings("T", parser.interner.get(impl_d.type_params[0]));
}

test "parse impl with no type parameters keeps existing shape" {
    const source =
        \\pub impl Enumerable for Range {
        \\  pub fn next(range :: Range) -> {Atom, i64, Range} {
        \\    :zig.Range.next(range)
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    const impl_d = program.top_items[0].impl_decl;
    try std.testing.expectEqual(@as(usize, 0), impl_d.type_params.len);
}

test "parse impl rejects nested type expression as type parameter" {
    const source =
        \\pub impl Enumerable for Map(List(K), V) {
        \\  pub fn next(map :: Map) -> Map { map }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    // Type-parameter slot must be a bare name. Nested calls like
    // `List(K)` inside the impl header parens belong to a future
    // where-clause / partial-application syntax — for now reject.
    const result = parser.parseProgram();
    try std.testing.expectError(error.ParseError, result);
}

test "less-than expression after struct call still parses as comparison" {
    // Defensive: confirm we didn't break expression-context `<`.
    // This file's impl-header parens are isolated from expressions.
    const source =
        \\pub struct Test {
        \\  pub fn check(a :: i64, b :: i64) -> Bool {
        \\    a < b
        \\  }
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), source);
    defer parser.deinit();

    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.structs.len);
}
