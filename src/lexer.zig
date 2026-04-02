const std = @import("std");
const Token = @import("token.zig").Token;

pub const Lexer = struct {
    pub const SourceMapSegment = struct {
        start: u32,
        end: u32,
        source_id: u32,
    };

    source: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,
    source_id: ?u32 = null,

    // String interpolation tracking
    interp_depth: u32,

    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .source_id = null,
            .interp_depth = 0,
        };
    }

    pub fn initWithSourceId(source: []const u8, source_id: u32) Lexer {
        var self = init(source);
        self.source_id = source_id;
        return self;
    }

    pub fn next(self: *Lexer) Token {
        // Skip whitespace (not newlines)
        self.skipHorizontalWhitespace();

        if (self.pos >= self.source.len) {
            return self.makeToken(.eof, self.pos, self.pos);
        }

        const c = self.source[self.pos];

        // Newlines
        if (c == '\n') {
            const start = self.pos;
            self.pos += 1;
            self.line += 1;
            self.line_start = self.pos;
            return self.makeToken(.newline, start, self.pos);
        }

        // Comments
        if (c == '#' and (self.pos + 1 >= self.source.len or self.source[self.pos + 1] != '{')) {
            self.skipToEndOfLine();
            return self.next();
        }

        // String literals
        if (c == '"') {
            return self.lexString();
        }

        // Atom literals
        if (c == ':' and self.pos + 1 < self.source.len and isIdentStart(self.source[self.pos + 1])) {
            return self.lexAtom();
        }

        // Numbers
        if (isDigit(c)) {
            return self.lexNumber();
        }

        // Identifiers and keywords
        if (isIdentStart(c)) {
            return self.lexIdentifier();
        }

        // Operators and delimiters
        return self.lexOperator();
    }

    fn skipHorizontalWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipToEndOfLine(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
    }

    fn lexString(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip opening quote

        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '"') {
                self.pos += 1;
                return self.makeToken(.string_literal, start, self.pos);
            }
            if (ch == '#' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                self.pos += 2;
                self.interp_depth += 1;
                var brace_depth: u32 = 1;
                while (self.pos < self.source.len and brace_depth > 0) {
                    if (self.source[self.pos] == '{') brace_depth += 1;
                    if (self.source[self.pos] == '}') brace_depth -= 1;
                    if (brace_depth > 0) self.pos += 1;
                }
                if (self.pos < self.source.len) self.pos += 1;
                self.interp_depth -= 1;
                continue;
            }
            if (ch == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2;
                continue;
            }
            if (ch == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            }
            self.pos += 1;
        }

        return self.makeToken(.invalid, start, self.pos);
    }

    fn lexAtom(self: *Lexer) Token {
        const start = self.pos;
        self.pos += 1; // skip ':'
        while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        return self.makeToken(.atom_literal, start, self.pos);
    }

    fn lexNumber(self: *Lexer) Token {
        const start = self.pos;
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '0' and
            (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X'))
        {
            self.pos += 2;
            while (self.pos < self.source.len and (isHexDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.pos += 1;
            }
            return self.makeToken(.int_literal, start, self.pos);
        }
        while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '.' and
            self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))
        {
            self.pos += 1;
            while (self.pos < self.source.len and (isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
                self.pos += 1;
            }
            return self.makeToken(.float_literal, start, self.pos);
        }
        return self.makeToken(.int_literal, start, self.pos);
    }

    fn lexIdentifier(self: *Lexer) Token {
        const start = self.pos;
        const first_char = self.source[self.pos];
        self.pos += 1;

        while (self.pos < self.source.len and isIdentContinue(self.source[self.pos])) {
            self.pos += 1;
        }

        const text = self.source[start..self.pos];

        if (Token.getKeyword(text)) |kw_tag| {
            return self.makeToken(kw_tag, start, self.pos);
        }

        if (first_char >= 'A' and first_char <= 'Z') {
            return self.makeToken(.module_identifier, start, self.pos);
        }

        return self.makeToken(.identifier, start, self.pos);
    }

    fn lexOperator(self: *Lexer) Token {
        const start = self.pos;
        const c = self.source[self.pos];
        self.pos += 1;

        switch (c) {
            '+' => {
                if (self.pos < self.source.len and self.source[self.pos] == '+') {
                    self.pos += 1;
                    return self.makeToken(.plus_plus, start, self.pos);
                }
                return self.makeToken(.plus, start, self.pos);
            },
            '*' => return self.makeToken(.star, start, self.pos),
            '/' => return self.makeToken(.slash, start, self.pos),
            '^' => return self.makeToken(.caret, start, self.pos),
            ',' => return self.makeToken(.comma, start, self.pos),
            '(' => return self.makeToken(.left_paren, start, self.pos),
            ')' => return self.makeToken(.right_paren, start, self.pos),
            '[' => return self.makeToken(.left_bracket, start, self.pos),
            ']' => return self.makeToken(.right_bracket, start, self.pos),
            '{' => return self.makeToken(.left_brace, start, self.pos),
            '}' => return self.makeToken(.right_brace, start, self.pos),
            '@' => return self.makeToken(.at_sign, start, self.pos),
            '-' => {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return self.makeToken(.arrow, start, self.pos);
                }
                return self.makeToken(.minus, start, self.pos);
            },
            '=' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.equal_equal, start, self.pos);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return self.makeToken(.arrow, start, self.pos);
                }
                return self.makeToken(.equal, start, self.pos);
            },
            '!' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.not_equal, start, self.pos);
                }
                return self.makeToken(.bang, start, self.pos);
            },
            '<' => {
                if (self.pos < self.source.len and self.source[self.pos] == '<') {
                    self.pos += 1;
                    return self.makeToken(.left_angle_angle, start, self.pos);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.less_equal, start, self.pos);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return self.makeToken(.diamond, start, self.pos);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '-') {
                    self.pos += 1;
                    return self.makeToken(.back_arrow, start, self.pos);
                }
                return self.makeToken(.less, start, self.pos);
            },
            '>' => {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return self.makeToken(.right_angle_angle, start, self.pos);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.greater_equal, start, self.pos);
                }
                return self.makeToken(.greater, start, self.pos);
            },
            '|' => {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return self.makeToken(.pipe_operator, start, self.pos);
                }
                if (self.pos < self.source.len and self.source[self.pos] == '|') {
                    self.pos += 1;
                    return self.makeToken(.double_pipe, start, self.pos);
                }
                return self.makeToken(.pipe, start, self.pos);
            },
            ':' => {
                if (self.pos < self.source.len and self.source[self.pos] == ':') {
                    self.pos += 1;
                    return self.makeToken(.double_colon, start, self.pos);
                }
                return self.makeToken(.colon, start, self.pos);
            },
            '.' => {
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    self.pos += 1;
                    return self.makeToken(.dot_brace, start, self.pos);
                }
                return self.makeToken(.dot, start, self.pos);
            },
            '%' => {
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    self.pos += 1;
                    return self.makeToken(.percent_brace, start, self.pos);
                }
                return self.makeToken(.percent, start, self.pos);
            },
            '#' => {
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    self.pos += 1;
                    return self.makeToken(.hash_brace, start, self.pos);
                }
                return self.makeToken(.hash, start, self.pos);
            },
            '~' => {
                if (self.pos < self.source.len and self.source[self.pos] == '>') {
                    self.pos += 1;
                    return self.makeToken(.tilde_arrow, start, self.pos);
                }
                return self.makeToken(.invalid, start, self.pos);
            },
            '&' => {
                if (self.pos < self.source.len and self.source[self.pos] == '&') {
                    self.pos += 1;
                    return self.makeToken(.double_ampersand, start, self.pos);
                }
                return self.makeToken(.invalid, start, self.pos);
            },
            else => return self.makeToken(.invalid, start, self.pos),
        }
    }

    fn makeToken(self: *Lexer, tag: Token.Tag, start: u32, end: u32) Token {
        const mapped = self.mapLocation(start, end);
        return .{
            .tag = tag,
            .loc = .{
                .start = mapped.start,
                .end = mapped.end,
                .line = mapped.line,
                .col = mapped.col,
                .source_id = mapped.source_id,
            },
        };
    }

    fn mapLocation(self: *const Lexer, start: u32, end: u32) Token.Location {
        return .{
            .start = start,
            .end = end,
            .line = self.line,
            .col = start -| self.line_start + 1,
            .source_id = self.source_id,
        };
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isIdentContinue(c: u8) bool {
        return isIdentStart(c) or isDigit(c) or c == '!' or c == '?';
    }
};

// ============================================================
// Tests
// ============================================================

test "lex simple tokens" {
    const source = "pub fn foo {";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.keyword_pub, t1.tag);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.keyword_fn, t2.tag);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t3.tag);
    try std.testing.expectEqualStrings("foo", t3.slice(source));

    const t4 = lexer.next();
    try std.testing.expectEqual(Token.Tag.left_brace, t4.tag);
}

test "lex numbers" {
    const source = "42 3.14";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t1.tag);
    try std.testing.expectEqualStrings("42", t1.slice(source));

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.float_literal, t2.tag);
    try std.testing.expectEqualStrings("3.14", t2.slice(source));
}

test "lex operators" {
    const source = "+ - * / == != <= >= |> -> <- :: <> !";
    var lexer = Lexer.init(source);

    const expected = [_]Token.Tag{
        .plus,       .minus,         .star,          .slash, .equal_equal, .not_equal,
        .less_equal, .greater_equal, .pipe_operator, .arrow, .back_arrow,  .double_colon,
        .diamond,    .bang,
    };

    for (expected) |exp| {
        const tok = lexer.next();
        try std.testing.expectEqual(exp, tok.tag);
    }
}

test "lex atom" {
    const source = ":ok :error :hello_world";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.atom_literal, t1.tag);
    try std.testing.expectEqualStrings(":ok", t1.slice(source));

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.atom_literal, t2.tag);
    try std.testing.expectEqualStrings(":error", t2.slice(source));

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.atom_literal, t3.tag);
    try std.testing.expectEqualStrings(":hello_world", t3.slice(source));
}

test "lex string" {
    const source =
        \\"hello world"
    ;
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.string_literal, t1.tag);
    try std.testing.expectEqualStrings("\"hello world\"", t1.slice(source));
}

test "lex module identifier" {
    const source = "Foo Bar MyModule";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.module_identifier, t1.tag);
    try std.testing.expectEqualStrings("Foo", t1.slice(source));

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.module_identifier, t2.tag);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.module_identifier, t3.tag);
    try std.testing.expectEqualStrings("MyModule", t3.slice(source));
}

test "lex braces" {
    const source = "pub module Foo {\n  pub fn bar() :: i64 {\n    42\n  }\n}";
    var lexer = Lexer.init(source);

    var has_left_brace = false;
    var has_right_brace = false;
    while (true) {
        const tok = lexer.next();
        if (tok.tag == .left_brace) has_left_brace = true;
        if (tok.tag == .right_brace) has_right_brace = true;
        if (tok.tag == .eof) break;
    }
    try std.testing.expect(has_left_brace);
    try std.testing.expect(has_right_brace);
}

test "lex type annotations" {
    const source = "x :: i64";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t1.tag);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.double_colon, t2.tag);

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t3.tag);
    try std.testing.expectEqualStrings("i64", t3.slice(source));
}

test "lex delimiters" {
    const source = "() [] {} %{}";
    var lexer = Lexer.init(source);

    const expected = [_]Token.Tag{
        .left_paren, .right_paren, .left_bracket,  .right_bracket,
        .left_brace, .right_brace, .percent_brace, .right_brace,
    };

    for (expected) |exp| {
        const tok = lexer.next();
        try std.testing.expectEqual(exp, tok.tag);
    }
}

test "lex tilde arrow ~>" {
    const source = "foo ~> bar";
    var lexer = Lexer.init(source);

    try std.testing.expectEqual(Token.Tag.identifier, lexer.next().tag);
    try std.testing.expectEqual(Token.Tag.tilde_arrow, lexer.next().tag);
    try std.testing.expectEqual(Token.Tag.identifier, lexer.next().tag);
}

test "lex comments are skipped" {
    const source =
        \\# this is a comment
        \\42
    ;
    var lexer = Lexer.init(source);

    // Skip past any newline tokens from the comment line
    var tok = lexer.next();
    while (tok.tag == .newline) {
        tok = lexer.next();
    }
    try std.testing.expectEqual(Token.Tag.int_literal, tok.tag);
    try std.testing.expectEqualStrings("42", tok.slice(source));
}

test "lex map arrow =>" {
    const source = "a => b";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t1.tag);

    const t2 = lexer.next();
    try std.testing.expectEqual(Token.Tag.arrow, t2.tag);
}

test "lex function definition tokens" {
    const source = "pub fn add(x :: i64, y :: i64) :: i64 {";
    var lexer = Lexer.init(source);

    const expected_tags = [_]Token.Tag{
        .keyword_pub, .keyword_fn,    .identifier,
        .left_paren,  .identifier,    .double_colon,
        .identifier,  .comma,         .identifier,
        .double_colon, .identifier,   .right_paren,
        .double_colon, .identifier,   .left_brace,
    };

    for (expected_tags) |exp| {
        const tok = lexer.next();
        try std.testing.expectEqual(exp, tok.tag);
    }
}

test "lex pipe and percent" {
    const source = "|> | % %{";
    var lexer = Lexer.init(source);

    try std.testing.expectEqual(Token.Tag.pipe_operator, lexer.next().tag);
    try std.testing.expectEqual(Token.Tag.pipe, lexer.next().tag);
    try std.testing.expectEqual(Token.Tag.percent, lexer.next().tag);
    try std.testing.expectEqual(Token.Tag.percent_brace, lexer.next().tag);
}

test "lex column tracking on single line" {
    const source = "pub fn foo {";
    var lexer = Lexer.init(source);

    const t1 = lexer.next(); // pub at col 1
    try std.testing.expectEqual(Token.Tag.keyword_pub, t1.tag);
    try std.testing.expectEqual(@as(u32, 1), t1.loc.col);

    const t2 = lexer.next(); // fn at col 5
    try std.testing.expectEqual(Token.Tag.keyword_fn, t2.tag);
    try std.testing.expectEqual(@as(u32, 5), t2.loc.col);

    const t3 = lexer.next(); // foo at col 8
    try std.testing.expectEqual(Token.Tag.identifier, t3.tag);
    try std.testing.expectEqual(@as(u32, 8), t3.loc.col);

    const t4 = lexer.next(); // { at col 12
    try std.testing.expectEqual(Token.Tag.left_brace, t4.tag);
    try std.testing.expectEqual(@as(u32, 12), t4.loc.col);
}

test "lex column tracking across lines" {
    const source = "foo\nbar baz";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t1.tag);
    try std.testing.expectEqual(@as(u32, 1), t1.loc.line);
    try std.testing.expectEqual(@as(u32, 1), t1.loc.col);

    _ = lexer.next(); // newline

    const t3 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t3.tag);
    try std.testing.expectEqual(@as(u32, 2), t3.loc.line);
    try std.testing.expectEqual(@as(u32, 1), t3.loc.col);

    const t4 = lexer.next();
    try std.testing.expectEqual(Token.Tag.identifier, t4.tag);
    try std.testing.expectEqual(@as(u32, 2), t4.loc.line);
    try std.testing.expectEqual(@as(u32, 5), t4.loc.col);
}

test "lex column tracking with operators" {
    const source = "x + y";
    var lexer = Lexer.init(source);

    const t1 = lexer.next();
    try std.testing.expectEqual(@as(u32, 1), t1.loc.col);

    const t2 = lexer.next();
    try std.testing.expectEqual(@as(u32, 3), t2.loc.col);

    const t3 = lexer.next();
    try std.testing.expectEqual(@as(u32, 5), t3.loc.col);
}
