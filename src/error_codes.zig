//! Phase 1.5 — numeric error-code infrastructure.
//!
//! Stable `Zxxxx` diagnostic codes are public API: once a `pub error`
//! declaration carries `@code Z1234`, that code is part of the contract
//! and is never reused for a different error. This module is the
//! compile-time registry that enforces the *uniqueness* half of that
//! contract — two `pub error` declarations that claim the same code are
//! a hard compile error.
//!
//! The registry walks the parsed (pre-desugar) per-unit ASTs, where each
//! `error_decl` / `priv_error_decl` still carries its `code: ?StringId`
//! field (the parser-captured `@code Zxxxx` bareword). It runs once
//! across *all* units so a collision between two separately-compiled
//! files is caught, then emits a rich diagnostic that points at both the
//! offending site and the original claimant.
//!
//! ## Numbering scheme (documented contract)
//!
//! Codes are written `Z<digits>`. The stdlib reserves low ranges so user
//! codes never collide with the standard library's reserved bands:
//!
//!   * `Z1xxx` — runtime / general failures (`RuntimeError`,
//!     `ArgumentError`, `ArithmeticError`, `IndexError`).
//!   * `Z2xxx` — type-system / contract failures (reserved).
//!   * `Z3xxx` and up — available for user code.
//!
//! The numeric value is monotonically growing within a band and is never
//! reused once retired (a retired code keeps its slot; new errors take
//! fresh numbers). This module does not police the *band* a code falls
//! in — that is a convention — but it does guarantee global uniqueness.

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

/// A single registered `@code Zxxxx` claim: the code text plus the source
/// span of the `pub error` declaration that claimed it and the error's
/// name (for diagnostic prose).
pub const CodeClaim = struct {
    /// The interned bareword, e.g. `"Z3041"`.
    code: []const u8,
    /// Dotted name of the claiming error type, e.g. `"ParseError"`.
    error_name: []const u8,
    /// Span of the claiming declaration (used as the secondary span when
    /// a later declaration collides with this one).
    span: ast.SourceSpan,
};

/// Outcome of registering a single code claim.
pub const RegisterResult = union(enum) {
    /// The code was not previously claimed — registration succeeded.
    registered,
    /// The code was already claimed by `prior`. The caller emits a
    /// collision diagnostic.
    collision: CodeClaim,
};

/// Compile-time registry of `@code Zxxxx` claims, keyed by the code text.
/// The keys and the `error_name` strings are borrowed from the caller's
/// interner / arena (stable for the registry's lifetime); only the map
/// spine is owned here.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    claims: std.StringHashMapUnmanaged(CodeClaim) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.claims.deinit(self.allocator);
    }

    /// Register one code claim. Returns `.registered` on the first claim
    /// of a code, or `.collision` carrying the prior claimant when the
    /// code was already taken. The first claimant always wins the slot;
    /// later collisions do not overwrite it (so the diagnostic points at
    /// the stable original).
    pub fn register(self: *Registry, claim: CodeClaim) !RegisterResult {
        const gop = try self.claims.getOrPut(self.allocator, claim.code);
        if (gop.found_existing) {
            return .{ .collision = gop.value_ptr.* };
        }
        gop.value_ptr.* = claim;
        return .registered;
    }

    /// Look up a previously-registered claim by code text.
    pub fn lookup(self: *const Registry, code: []const u8) ?CodeClaim {
        return self.claims.get(code);
    }
};

/// Return the `Zxxxx` text of a `@code` attribute item that immediately
/// precedes the top item at `decl_index` (separated only by other
/// attribute items such as `@doc`), or `null` when none is present. The
/// parser stores the bareword value as a `string_literal` Expr on the
/// attribute. Mirrors `Desugarer.takePendingCodeAttribute`.
fn precedingCodeAttributeValue(
    interner: *const ast.StringInterner,
    top_items: []const ast.TopItem,
    decl_index: usize,
) ?[]const u8 {
    if (decl_index == 0) return null;
    var i: isize = @as(isize, @intCast(decl_index)) - 1;
    while (i >= 0) : (i -= 1) {
        const item = top_items[@intCast(i)];
        if (item != .attribute) return null;
        const attr = item.attribute;
        if (std.mem.eql(u8, interner.get(attr.name), "code")) {
            const value_expr = attr.value orelse return null;
            return switch (value_expr.*) {
                .string_literal => |lit| interner.get(lit.value),
                else => null,
            };
        }
    }
    return null;
}

/// Validate that no two `pub error` declarations across `programs` claim
/// the same `@code Zxxxx`. Emits a rich `.error` diagnostic per collision
/// (pointing at the colliding site, with a secondary span on the original
/// claimant). Stdlib-reserved codes (claimed by `lib/` units) participate
/// in the same single namespace so a user code colliding with a stdlib
/// code is caught too.
///
/// `interner` resolves the error-name and code StringIds to text;
/// `name_arena` owns the dotted-name strings the diagnostics borrow (it
/// must outlive `engine`'s rendering). Returns the number of collisions
/// found (0 means clean).
pub fn checkCodeCollisions(
    name_arena: std.mem.Allocator,
    programs: []const ast.Program,
    interner: *const ast.StringInterner,
    engine: *diagnostics.DiagnosticEngine,
) !usize {
    var registry = Registry.init(name_arena);
    defer registry.deinit();

    var collisions: usize = 0;
    for (programs) |program| {
        for (program.top_items, 0..) |item, index| {
            const decl: *const ast.ErrorDecl = switch (item) {
                .error_decl, .priv_error_decl => |d| d,
                else => continue,
            };
            // The parser leaves `ErrorDecl.code` null and emits the
            // `@code Zxxxx` value as a separate preceding top-level
            // `attribute` item (folded into the generated `code/1` by the
            // desugar). Read the code from `decl.code` if a later pass
            // already populated it, else scan the preceding attribute
            // items — mirroring `Desugarer.takePendingCodeAttribute`.
            const code_text = blk: {
                if (decl.code) |code_id| break :blk interner.get(code_id);
                if (precedingCodeAttributeValue(interner, program.top_items, index)) |value| break :blk value;
                continue;
            };
            const error_name = try decl.name.toDottedString(name_arena, interner);
            const result = try registry.register(.{
                .code = code_text,
                .error_name = error_name,
                .span = decl.meta.span,
            });
            switch (result) {
                .registered => {},
                .collision => |prior| {
                    collisions += 1;
                    const message = try std.fmt.allocPrint(
                        name_arena,
                        "error code `{s}` is already used by `{s}`",
                        .{ code_text, prior.error_name },
                    );
                    const note_msg = try std.fmt.allocPrint(
                        name_arena,
                        "first claimed here by `{s}`; error codes are stable public " ++
                            "API and must be unique — give this error a fresh `@code`",
                        .{prior.error_name},
                    );
                    try engine.reportWithNotes(
                        .@"error",
                        message,
                        decl.meta.span,
                        &[_]diagnostics.Diagnostic.Note{.{
                            .message = note_msg,
                            .span = prior.span,
                        }},
                    );
                },
            }
        }
    }
    return collisions;
}

// ============================================================
// `zap explain Zxxxx` catalog reader
// ============================================================

/// One parsed catalog record: the long-form explanation backing
/// `zap explain Zxxxx`. All slices borrow the catalog source text passed
/// to `findCatalogEntry`, so they are valid only while that buffer lives.
pub const CatalogEntry = struct {
    code: []const u8,
    title: []const u8 = "",
    explanation: []const u8 = "",
    repro: []const u8 = "",
    fix: []const u8 = "",
};

/// True for a well-formed `Z<digits>` diagnostic code (`Z1003`). Mirrors
/// the parser's `isValidErrorCodeBareword`, kept here so the `zap explain`
/// reader can validate user input without pulling in the parser.
pub fn isValidCode(text: []const u8) bool {
    if (text.len < 2) return false;
    if (text[0] != 'Z') return false;
    for (text[1..]) |ch| {
        if (ch < '0' or ch > '9') return false;
    }
    return true;
}

/// Find the catalog record for `code` in `catalog_source` (the contents
/// of `lib/error_catalog.zap`). Returns the parsed entry, or `null` if
/// no `[code]` record exists. The record format is documented in
/// `lib/error_catalog.zap`: a `[Zxxxx]` header line (leading whitespace
/// allowed) followed by `key: value` lines whose values continue onto
/// indented lines until the next key or the next `[Zxxxx]` header.
///
/// `value_arena` owns the joined multi-line value strings (continuation
/// lines are concatenated with single spaces); the returned slices borrow
/// from it. The `code` field borrows from `catalog_source`.
pub fn findCatalogEntry(
    value_arena: std.mem.Allocator,
    catalog_source: []const u8,
    code: []const u8,
) !?CatalogEntry {
    var in_target_record = false;
    var found = false;
    var entry = CatalogEntry{ .code = code };

    // The key currently accumulating continuation lines, and its buffer.
    const Key = enum { none, title, explanation, repro, fix };
    var current_key: Key = .none;
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(value_arena);

    const flush = struct {
        fn run(e: *CatalogEntry, k: Key, b: []const u8, arena: std.mem.Allocator) !void {
            const owned = try arena.dupe(u8, b);
            switch (k) {
                .title => e.title = owned,
                .explanation => e.explanation = owned,
                .repro => e.repro = owned,
                .fix => e.fix = owned,
                .none => {},
            }
        }
    }.run;

    var lines = std.mem.splitScalar(u8, catalog_source, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        // Catalog-heredoc close: the records live inside `@doc = """ … """`,
        // and a line that is exactly `"""` ends that heredoc — i.e. the end
        // of the catalog data. The LAST `[Zxxxx]` record is followed by this
        // close and then unrelated source (the `Zap.ErrorCatalog` marker
        // struct's own `@doc`, the `pub struct` line). Without this, those
        // lines are mis-read as continuation lines of the last record's final
        // `key:` value (they are neither a `key:` line nor a `[Zxxxx]`
        // header), bleeding the trailing source into the explanation. Flush
        // the pending target value and stop scanning at the heredoc close.
        if (std.mem.eql(u8, trimmed, "\"\"\"")) {
            if (in_target_record) {
                try flush(&entry, current_key, buffer.items, value_arena);
            }
            break;
        }

        // Record header: `[Zxxxx]`.
        if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            const header_code = trimmed[1 .. trimmed.len - 1];
            // Close out the previous target record's pending value.
            if (in_target_record) {
                try flush(&entry, current_key, buffer.items, value_arena);
                break;
            }
            if (std.mem.eql(u8, header_code, code)) {
                in_target_record = true;
                found = true;
            }
            current_key = .none;
            buffer.clearRetainingCapacity();
            continue;
        }

        if (!in_target_record) continue;

        // A `key:` line opens a new value; anything else is a continuation
        // of the current value.
        const maybe_key = detectKey(trimmed);
        if (maybe_key) |kv| {
            try flush(&entry, current_key, buffer.items, value_arena);
            buffer.clearRetainingCapacity();
            current_key = switch (kv.key) {
                .title => .title,
                .explanation => .explanation,
                .repro => .repro,
                .fix => .fix,
            };
            try buffer.appendSlice(value_arena, std.mem.trim(u8, kv.value, " \t\r"));
        } else if (current_key != .none) {
            // Continuation line: join with a single space.
            if (buffer.items.len > 0 and trimmed.len > 0) {
                try buffer.append(value_arena, ' ');
            }
            try buffer.appendSlice(value_arena, trimmed);
        }
    }

    // If the loop exited at EOF while still inside the target record (no
    // closing `[Zxxxx]` header followed it), commit the pending value.
    // The break-on-next-header path already flushed, so this only fires
    // for a record that is the last in the file; flushing twice is
    // harmless because the second flush overwrites with the same bytes.
    if (in_target_record) {
        try flush(&entry, current_key, buffer.items, value_arena);
    }

    return if (found) entry else null;
}

const RecognizedKey = enum { title, explanation, repro, fix };

const KeyValue = struct { key: RecognizedKey, value: []const u8 };

fn detectKey(line: []const u8) ?KeyValue {
    const pairs = [_]struct { name: []const u8, key: RecognizedKey }{
        .{ .name = "title:", .key = .title },
        .{ .name = "explanation:", .key = .explanation },
        .{ .name = "repro:", .key = .repro },
        .{ .name = "fix:", .key = .fix },
    };
    for (pairs) |p| {
        if (std.mem.startsWith(u8, line, p.name)) {
            return .{ .key = p.key, .value = line[p.name.len..] };
        }
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const Parser = @import("parser.zig").Parser;

fn parseSource(alloc: std.mem.Allocator, source: []const u8, out_interner: **ast.StringInterner) !ast.Program {
    var parser = try Parser.init(alloc, source);
    const program = try parser.parseProgram();
    out_interner.* = parser.interner;
    return program;
}

test "registry registers a unique code then reports collision on reuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    defer registry.deinit();

    const first = try registry.register(.{
        .code = "Z3041",
        .error_name = "ParseError",
        .span = .{ .start = 0, .end = 1, .line = 1, .col = 1 },
    });
    try std.testing.expect(first == .registered);

    const second = try registry.register(.{
        .code = "Z3041",
        .error_name = "OtherError",
        .span = .{ .start = 40, .end = 41, .line = 9, .col = 1 },
    });
    try std.testing.expect(second == .collision);
    try std.testing.expectEqualStrings("ParseError", second.collision.error_name);

    // The original claimant keeps the slot.
    const looked_up = registry.lookup("Z3041").?;
    try std.testing.expectEqualStrings("ParseError", looked_up.error_name);
}

test "checkCodeCollisions flags two pub errors sharing a code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\@code Z3041
        \\pub error ParseError {}
        \\@code Z3041
        \\pub error LexError {}
    ;
    var interner: *ast.StringInterner = undefined;
    const program = try parseSource(alloc, source, &interner);

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    const collisions = try checkCodeCollisions(alloc, &[_]ast.Program{program}, interner, &engine);
    try std.testing.expectEqual(@as(usize, 1), collisions);
    try std.testing.expectEqual(@as(usize, 1), engine.errorCount());
}

test "isValidCode accepts Z-digits and rejects malformed codes" {
    try std.testing.expect(isValidCode("Z1003"));
    try std.testing.expect(isValidCode("Z3041"));
    try std.testing.expect(!isValidCode("Z"));
    try std.testing.expect(!isValidCode("1003"));
    try std.testing.expect(!isValidCode("Z10a3"));
    try std.testing.expect(!isValidCode(""));
}

test "findCatalogEntry parses a multi-line record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const catalog =
        \\some preamble outside any record is ignored
        \\  [Z1003]
        \\  title: ArithmeticError trap
        \\  explanation: overflow in safe modes
        \\    traps and aborts
        \\  fix: use a wider type
        \\  [Z1004]
        \\  title: IndexError
    ;
    const entry = (try findCatalogEntry(alloc, catalog, "Z1003")).?;
    try std.testing.expectEqualStrings("Z1003", entry.code);
    try std.testing.expectEqualStrings("ArithmeticError trap", entry.title);
    try std.testing.expectEqualStrings("overflow in safe modes traps and aborts", entry.explanation);
    try std.testing.expectEqualStrings("use a wider type", entry.fix);
}

test "findCatalogEntry returns null for an unknown code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const catalog =
        \\[Z1003]
        \\title: known
    ;
    try std.testing.expect((try findCatalogEntry(alloc, catalog, "Z9999")) == null);
}

test "findCatalogEntry parses the last record in the file (EOF flush)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const catalog =
        \\[Z1003]
        \\title: first
        \\[Z1004]
        \\title: IndexError
        \\explanation: out of bounds
    ;
    const entry = (try findCatalogEntry(alloc, catalog, "Z1004")).?;
    try std.testing.expectEqualStrings("IndexError", entry.title);
    try std.testing.expectEqualStrings("out of bounds", entry.explanation);
}

test "findCatalogEntry stops the last record at the catalog heredoc close" {
    // The real `lib/error_catalog.zap` keeps the catalog inside an
    // `@doc = """ … """` heredoc; the LAST `[Zxxxx]` record is followed by
    // the closing `"""` and then unrelated source (a second `@doc` heredoc
    // and the `Zap.ErrorCatalog` marker struct). A `"""` line on its own
    // terminates the catalog data: the last record's final value must NOT
    // swallow the heredoc close or the trailing source as continuation lines.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const catalog =
        \\@doc = """
        \\  [Z9100]
        \\  title: ICE script
        \\  [Z9101]
        \\  title: ICE project
        \\  fix: file a report with the Z9101 code.
        \\  """
        \\
        \\@doc = """
        \\  Marker struct so the file is a well-formed Zap unit.
        \\  """
        \\
        \\pub struct Zap.ErrorCatalog {}
    ;
    const entry = (try findCatalogEntry(alloc, catalog, "Z9101")).?;
    try std.testing.expectEqualStrings("Z9101", entry.code);
    try std.testing.expectEqualStrings("ICE project", entry.title);
    // The `fix` value must end at the record's own text — it must not absorb
    // the closing `"""`, the second `@doc`, the marker-struct prose, or the
    // `pub struct` line.
    try std.testing.expectEqualStrings("file a report with the Z9101 code.", entry.fix);
}

test "checkCodeCollisions is clean when codes are distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const source =
        \\@code Z3041
        \\pub error ParseError {}
        \\@code Z3042
        \\pub error LexError {}
        \\pub error UncodedError {}
    ;
    var interner: *ast.StringInterner = undefined;
    const program = try parseSource(alloc, source, &interner);

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    const collisions = try checkCodeCollisions(alloc, &[_]ast.Program{program}, interner, &engine);
    try std.testing.expectEqual(@as(usize, 0), collisions);
    try std.testing.expectEqual(@as(usize, 0), engine.errorCount());
}
