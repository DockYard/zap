const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Location,

    pub const Location = struct {
        start: u32,
        end: u32,
        line: u32 = 0,
        col: u32 = 0,
        source_id: ?u32 = null,
    };

    pub const Tag = enum {
        // Literals
        int_literal,
        float_literal,
        string_literal,
        string_literal_start, // start of interpolated string
        string_literal_part, // middle part between interpolations
        string_literal_end, // end of interpolated string
        atom_literal,
        char_literal, // ?A → 65, ?\n → 10

        // Identifiers
        identifier,
        type_identifier, // capitalized identifier

        // Keywords
        keyword_pub,
        keyword_fn,
        keyword_struct,
        keyword_union,
        keyword_macro,
        keyword_extends,
        keyword_if,
        keyword_else,
        keyword_case,
        keyword_cond,
        keyword_receive,
        keyword_type,
        keyword_opaque,
        keyword_alias,
        keyword_import,
        keyword_use,
        keyword_true,
        keyword_false,
        keyword_nil,
        keyword_and,
        keyword_or,
        keyword_not,
        keyword_rem,
        keyword_for,
        keyword_panic,
        keyword_only,
        keyword_except,
        keyword_as,
        keyword_shared,
        keyword_unique,
        keyword_borrowed,
        keyword_protocol,
        keyword_impl,
        keyword_in,

        // Operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        equal, // =
        equal_equal, // ==
        not_equal, // !=
        less, // <
        greater, // >
        less_equal, // <=
        greater_equal, // >=
        pipe_operator, // |>
        arrow, // ->
        back_arrow, // <-
        tilde_arrow, // ~>
        sigil_prefix, // ~z, ~r, ~MY_SIGIL (sigil name including ~)
        double_colon, // ::
        pipe, // |
        diamond, // <>
        bang, // !
        ampersand, // &
        caret, // ^
        hash_brace, // #{
        percent_brace, // %{
        dot, // .
        dot_dot, // ..
        dot_brace, // .{
        left_angle_angle, // <<
        right_angle_angle, // >>

        // Delimiters
        left_paren, // (
        right_paren, // )
        left_bracket, // [
        right_bracket, // ]
        left_brace, // {
        right_brace, // }
        comma, // ,
        colon, // :
        percent, // %
        at_sign, // @
        hash, // #

        // Layout tokens
        newline,

        // Special
        eof,
        invalid,

        // Foreign operators (from other languages — produce helpful errors)
        double_ampersand, // &&
        double_pipe, // ||
        plus_plus, // ++
    };

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }

    /// True when this token is an identifier whose text is exactly `quote`.
    /// Used by the parser to recognise the `quote { ... }` contextual
    /// keyword without making `quote` a reserved name.
    pub fn isQuoteIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "quote");
    }

    /// True when this token is an identifier whose text is exactly `unquote`.
    pub fn isUnquoteIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "unquote");
    }

    /// True when this token is an identifier whose text is exactly
    /// `unquote_splicing`.
    pub fn isUnquoteSplicingIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "unquote_splicing");
    }

    /// True when this token is an identifier whose text is exactly `error`.
    /// `error` is a contextual keyword: only the top-level declaration
    /// parser dispatches into `parseErrorDecl` on this shape. Treating
    /// `error` as a hard keyword would prevent `Result(t, e)` from having
    /// an `Error(e)` variant — and more generally, would reserve a common
    /// English word across every expression position. The parser uses
    /// this helper at the exact decl positions (`pub error`, bare
    /// `error`) where the contextual reading is unambiguous.
    pub fn isErrorIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "error");
    }

    /// `raise` is a contextual keyword (Phase 1.4), recognised only when
    /// it leads an expression (`raise "boom"`, `raise %E{...}`). It is not
    /// a hard keyword so the existing `Kernel.raise/1` function and any
    /// identifier named `raise` outside leading-expression position keep
    /// working. The parser confirms the contextual reading with a
    /// lookahead at `parsePrimaryExpr`.
    pub fn isRaiseIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "raise");
    }

    /// `try` is a contextual keyword (Phase 3.a), recognised only when it
    /// leads an expression and is immediately followed by a `{` block —
    /// `try { … } rescue { … }`. It opens a dynamic recoverable-error
    /// handler scope. It is NOT a hard keyword so the existing
    /// `try_parse`-style identifiers and any value named `try` keep
    /// working; the parser confirms the contextual reading with a
    /// lookahead at `parsePrimaryExpr`.
    pub fn isTryIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "try");
    }

    /// `rescue` is a contextual keyword (Phase 3.a), recognised only in
    /// the `rescue { … }` position immediately following a `try` block.
    /// Outside that position an identifier named `rescue` keeps working.
    pub fn isRescueIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "rescue");
    }

    /// `after` is a contextual keyword (Phase 3.a), recognised only in the
    /// `after { … }` finally position immediately following a `try`/`rescue`
    /// block. `after` is a common English word, so it is deliberately NOT a
    /// hard keyword — an identifier named `after` outside the handler tail
    /// keeps working; the parser confirms the contextual reading.
    pub fn isAfterIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "after");
    }

    /// `with` is a contextual keyword (Phase 3.c). It opens an
    /// Elixir-style multi-step Result composition only when it leads a
    /// `with <pattern> <- <expr> …` form — i.e. when the immediately
    /// following token can begin a step pattern (the parser additionally
    /// confirms the `<-` arrow). A bare `with` used as a plain identifier
    /// (e.g. `with.field`, `with(args)`, `with + 1`, or a local named
    /// `with`) keeps its identifier reading because those next tokens
    /// (`.`, `(`, operators) cannot begin a pattern.
    pub fn isWithIdent(self: Token, source: []const u8) bool {
        return self.tag == .identifier and std.mem.eql(u8, self.slice(source), "with");
    }

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "pub", .keyword_pub },
        .{ "fn", .keyword_fn },
        .{ "struct", .keyword_struct },
        .{ "union", .keyword_union },
        .{ "macro", .keyword_macro },
        .{ "extends", .keyword_extends },
        .{ "if", .keyword_if },
        .{ "else", .keyword_else },
        .{ "case", .keyword_case },
        .{ "cond", .keyword_cond },
        .{ "receive", .keyword_receive },
        .{ "type", .keyword_type },
        .{ "opaque", .keyword_opaque },
        .{ "alias", .keyword_alias },
        .{ "import", .keyword_import },
        // "use" is contextual — only recognized at struct item level in the parser,
        // not as a general keyword. This allows "use" as a function/variable name.
        // .{ "use", .keyword_use },
        // "quote", "unquote", and "unquote_splicing" are also contextual.
        // The parser dispatches by literal identifier text plus lookahead so
        // the names can still be used as ordinary functions/variables.
        .{ "true", .keyword_true },
        .{ "false", .keyword_false },
        .{ "nil", .keyword_nil },
        .{ "and", .keyword_and },
        .{ "or", .keyword_or },
        .{ "not", .keyword_not },
        .{ "rem", .keyword_rem },
        .{ "for", .keyword_for },
        .{ "panic", .keyword_panic },
        .{ "only", .keyword_only },
        .{ "except", .keyword_except },
        .{ "as", .keyword_as },
        .{ "shared", .keyword_shared },
        .{ "unique", .keyword_unique },
        .{ "borrowed", .keyword_borrowed },
        .{ "protocol", .keyword_protocol },
        .{ "impl", .keyword_impl },
        .{ "in", .keyword_in },
        // "error" is contextual — see Token.isErrorIdent. It is intentionally
        // omitted from this static keyword table so that `Result.Error`,
        // record fields named `error`, and other ordinary identifier
        // positions are not stolen by a hard keyword token.
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub fn tagName(tag: Tag) []const u8 {
        return @tagName(tag);
    }
};

test "keyword lookup" {
    try std.testing.expectEqual(Token.Tag.keyword_fn, Token.getKeyword("fn").?);
    try std.testing.expectEqual(Token.Tag.keyword_struct, Token.getKeyword("struct").?);
    try std.testing.expectEqual(Token.Tag.keyword_pub, Token.getKeyword("pub").?);
    try std.testing.expect(Token.getKeyword("foobar") == null);
    // `quote`, `unquote`, and `unquote_splicing` are contextual and
    // must NOT be in the reserved keyword map.
    try std.testing.expect(Token.getKeyword("quote") == null);
    try std.testing.expect(Token.getKeyword("unquote") == null);
    try std.testing.expect(Token.getKeyword("unquote_splicing") == null);
}

test "token slice" {
    const source = "pub struct Foo {";
    const tok = Token{
        .tag = .keyword_pub,
        .loc = .{ .start = 0, .end = 3 },
    };
    try std.testing.expectEqualStrings("pub", tok.slice(source));
}

test "contextual keyword identifier predicates" {
    const source = "quote unquote unquote_splicing other";
    const quote_tok = Token{
        .tag = .identifier,
        .loc = .{ .start = 0, .end = 5 },
    };
    const unquote_tok = Token{
        .tag = .identifier,
        .loc = .{ .start = 6, .end = 13 },
    };
    const splicing_tok = Token{
        .tag = .identifier,
        .loc = .{ .start = 14, .end = 30 },
    };
    const other_tok = Token{
        .tag = .identifier,
        .loc = .{ .start = 31, .end = 36 },
    };

    try std.testing.expect(quote_tok.isQuoteIdent(source));
    try std.testing.expect(!quote_tok.isUnquoteIdent(source));
    try std.testing.expect(!quote_tok.isUnquoteSplicingIdent(source));

    try std.testing.expect(!unquote_tok.isQuoteIdent(source));
    try std.testing.expect(unquote_tok.isUnquoteIdent(source));
    try std.testing.expect(!unquote_tok.isUnquoteSplicingIdent(source));

    try std.testing.expect(!splicing_tok.isQuoteIdent(source));
    try std.testing.expect(!splicing_tok.isUnquoteIdent(source));
    try std.testing.expect(splicing_tok.isUnquoteSplicingIdent(source));

    try std.testing.expect(!other_tok.isQuoteIdent(source));
    try std.testing.expect(!other_tok.isUnquoteIdent(source));
    try std.testing.expect(!other_tok.isUnquoteSplicingIdent(source));

    // A non-identifier token whose text happens to be `quote` (e.g. a
    // string literal containing the word) must NOT trigger the
    // contextual-keyword predicates. Tag check is the gate.
    const non_ident = Token{
        .tag = .string_literal,
        .loc = .{ .start = 0, .end = 5 },
    };
    try std.testing.expect(!non_ident.isQuoteIdent(source));
}
