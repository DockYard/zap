//! Phase 4.a — the `--error-format=json` serializer.
//!
//! A stable, versioned JSON projection of the canonical Error IR
//! (`src/error_ir.zig` / `diagnostics.Diagnostic`). The shape is a deliberate
//! union of two consumers (brief Part IV §4 + Part V):
//!
//!   * the **LSP `Diagnostic`** shape — `range`, `severity` (numeric),
//!     `code`, `codeDescription`, `message`, `relatedInformation`, `source`;
//!     and
//!   * **rustc's `--error-format=json`** shape — a stable `code`, a fully
//!     `rendered` human string, `spans[]`, and `suggestions[]` each with an
//!     `applicability` tag.
//!
//! A consumer that speaks LSP reads the LSP fields; a consumer that speaks
//! rustc-JSON (CI gates, `zap fix`) reads the rustc fields; both live in one
//! object so neither needs a translation layer. The document is deterministic
//! (diagnostics are emitted in the renderer's canonical order) and carries a
//! `schema_version` so downstream tools can pin against it.
//!
//! The schema is documented in `docs/error-json-schema.md`. This module is
//! the single producer; the renderer (`diagnostics.zig`) produces the human
//! text and `rendered` mirrors it, so the two formats never disagree on
//! content — only on shape.
//!
//! ## LSP coordinate convention
//!
//! LSP `Position` is ZERO-based for both line and character; Zap's
//! `SourceSpan` is ONE-based (`line`/`col` as the lexer emits them, after the
//! engine's `line_offset` adjustment for stdlib-prepended lines). The
//! serializer converts: `lsp_line = displayLine - 1`, `lsp_char = col - 1`,
//! clamped at zero. The rustc-style `line`/`column` fields keep the one-based
//! values a human expects.

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const error_ir = @import("error_ir.zig");
const error_format = @import("error_format.zig");

/// The schema version embedded in every document. Bump on any
/// backward-incompatible change to the field set; additive fields do not bump.
pub const SCHEMA_VERSION: u32 = 1;

/// Serialize all diagnostics held by `engine` into a single JSON document and
/// return the owned string. The document is:
///
///   { "schema_version": 1, "diagnostics": [ <diagnostic>, ... ] }
///
/// Diagnostics are emitted in the renderer's canonical deterministic order
/// (via `engine.orderedDiagnostics`) so the JSON is snapshot-stable across
/// runs. `rendered_text`, when non-null, is the human-rendered text of the
/// whole batch (from `engine.format`) — but each diagnostic also carries its
/// OWN `rendered` field produced here, so a tool need not split the batch.
///
/// Caller owns the returned slice.
pub fn serialize(engine: *const diagnostics.DiagnosticEngine, allocator: std.mem.Allocator) ![]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(allocator);
    const out = JsonWriter{ .list = &buffer, .alloc = allocator };

    const ordered = try engine.orderedDiagnostics(allocator);
    defer allocator.free(ordered);

    try out.raw("{\"schema_version\":");
    try out.print("{d}", .{SCHEMA_VERSION});
    try out.raw(",\"diagnostics\":[");
    for (ordered, 0..) |diag, index| {
        if (index > 0) try out.raw(",");
        try serializeDiagnostic(engine, out, diag);
    }
    try out.raw("]}");

    return buffer.toOwnedSlice(allocator);
}

/// Serialize a single diagnostic object. Emits the LSP fields and the rustc
/// fields side by side. The exact field set is documented in
/// `docs/error-json-schema.md`.
fn serializeDiagnostic(
    engine: *const diagnostics.DiagnosticEngine,
    out: JsonWriter,
    diag: diagnostics.Diagnostic,
) !void {
    try out.raw("{");

    // ── rustc + canonical-IR scalar fields ──
    try out.raw("\"domain\":");
    try out.jsonString(diag.domain.wireName());

    try out.raw(",\"severity\":");
    try out.jsonString(diag.severity.label());

    // LSP numeric severity (1=Error..4=Hint).
    try out.raw(",\"lsp_severity\":");
    try out.print("{d}", .{error_ir.lspSeverity(diag.severity)});

    if (diag.code) |code| {
        try out.raw(",\"code\":");
        try out.jsonString(code);
        // LSP codeDescription.href points at `zap explain <code>`; we emit the
        // command form so an LSP client can surface "see full explanation".
        try out.raw(",\"code_description\":{\"href\":");
        try out.jsonStringFmt("zap explain {s}", .{code});
        try out.raw("}");
    }

    try out.raw(",\"message\":");
    try out.jsonString(diag.message);

    try out.raw(",\"trace_policy\":");
    try out.jsonString(diag.trace_policy.wireName());

    try out.raw(",\"visibility\":");
    try out.jsonString(diag.visibility.wireName());

    // ── Primary span / LSP range ──
    try out.raw(",\"primary_span\":");
    try serializeSpan(engine, out, diag.span, diag.label);

    // ── relatedInformation: secondary spans + related spans ──
    try out.raw(",\"related_information\":[");
    var related_count: usize = 0;
    for (diag.secondary_spans) |secondary| {
        if (related_count > 0) try out.raw(",");
        try serializeRelated(engine, out, secondary.span, secondary.label);
        related_count += 1;
    }
    for (diag.related_spans) |related| {
        if (related_count > 0) try out.raw(",");
        try serializeRelated(engine, out, related.span, related.message);
        related_count += 1;
    }
    try out.raw("]");

    // ── notes ──
    try out.raw(",\"notes\":[");
    for (diag.notes, 0..) |note, note_index| {
        if (note_index > 0) try out.raw(",");
        try out.raw("{\"message\":");
        try out.jsonString(note.message);
        if (note.span) |note_span| {
            try out.raw(",\"span\":");
            try serializeSpan(engine, out, note_span, null);
        }
        try out.raw("}");
    }
    try out.raw("]");

    // ── help (free-form) ──
    if (diag.help) |help_text| {
        try out.raw(",\"help\":");
        try out.jsonString(help_text);
    }

    // ── suggestions[] (rustc): the legacy suggestion + canonical fixits ──
    try out.raw(",\"suggestions\":[");
    var suggestion_count: usize = 0;
    if (diag.suggestion) |suggestion| {
        try serializeSuggestion(
            engine,
            out,
            suggestion.span,
            suggestion.replacement,
            suggestion.description,
            .unspecified,
        );
        suggestion_count += 1;
    }
    for (diag.fixits) |fixit| {
        if (suggestion_count > 0) try out.raw(",");
        try serializeSuggestion(
            engine,
            out,
            fixit.span,
            fixit.replacement,
            fixit.description,
            fixit.applicability,
        );
        suggestion_count += 1;
    }
    try out.raw("]");

    // ── cause_chain[] ──
    try out.raw(",\"cause_chain\":[");
    for (diag.cause_chain, 0..) |cause, cause_index| {
        if (cause_index > 0) try out.raw(",");
        try out.raw("{");
        if (cause.code) |cause_code| {
            try out.raw("\"code\":");
            try out.jsonString(cause_code);
            try out.raw(",");
        }
        try out.raw("\"message\":");
        try out.jsonString(cause.message);
        if (cause.span) |cause_span| {
            try out.raw(",\"span\":");
            try serializeSpan(engine, out, cause_span, null);
        }
        try out.raw("}");
    }
    try out.raw("]");

    // ── machine_data{} (object of string->string) ──
    // The failing-pass name of an ICE (carried in the dedicated `ice_pass`
    // field) is surfaced here under the stable `ice_pass` key so a tool reads
    // it from one well-known place alongside any other machine data.
    try out.raw(",\"machine_data\":{");
    var datum_count: usize = 0;
    if (diag.ice_pass) |pass| {
        try out.jsonString("ice_pass");
        try out.raw(":");
        try out.jsonString(pass);
        datum_count += 1;
    }
    for (diag.machine_data) |datum| {
        if (datum_count > 0) try out.raw(",");
        try out.jsonString(datum.key);
        try out.raw(":");
        try out.jsonString(datum.value);
        datum_count += 1;
    }
    try out.raw("}");

    // ── expansion_backtrace[] (Phase 4.b) ──
    // The macro-expansion chain from the innermost frame out to user source,
    // each entry a `{ macro, call_site }`. A tool can render the same
    // Rust/Elixir macro backtrace the text renderer prints. Empty/absent for
    // ordinary source-level diagnostics.
    if (diag.expansion) |innermost| {
        try out.raw(",\"expansion_backtrace\":[");
        var frame: ?*const ast.ExpansionInfo = innermost;
        var frame_index: usize = 0;
        while (frame) |current| : (frame = current.parent) {
            if (frame_index > 0) try out.raw(",");
            try out.raw("{\"macro\":");
            if (engine.interner) |interner| {
                try out.jsonString(interner.get(current.macro_name));
            } else {
                try out.raw("null");
            }
            try out.raw(",\"call_site\":");
            try serializeSpan(engine, out, current.call_site, null);
            try out.raw("}");
            frame_index += 1;
        }
        try out.raw("]");
    }

    // ── rendered: the human text for THIS diagnostic ──
    const rendered = try renderSingle(engine, out.alloc, diag);
    defer out.alloc.free(rendered);
    try out.raw(",\"rendered\":");
    try out.jsonString(rendered);

    try out.raw("}");
}

/// Render exactly one diagnostic to its human text by running it through the
/// renderer in isolation. This guarantees the JSON `rendered` field is
/// byte-identical to what the text renderer would print for that diagnostic —
/// one renderer, one visual language, mirrored into JSON.
fn renderSingle(
    engine: *const diagnostics.DiagnosticEngine,
    allocator: std.mem.Allocator,
    diag: diagnostics.Diagnostic,
) ![]const u8 {
    var single = diagnostics.DiagnosticEngine.init(allocator);
    defer single.deinit();
    // Mirror the parent engine's rendering context so the single-diagnostic
    // render matches the batch render exactly (sources, line offset, tier).
    // Color is forced OFF for the embedded `rendered` string so the JSON
    // payload is free of ANSI escapes regardless of the parent's TTY state.
    try single.setSources(engine.sources.items);
    single.setLineOffset(engine.line_offset);
    single.tier = engine.tier;
    single.use_color = false;
    try single.reportDiagnostic(diag);
    return single.format(allocator);
}

/// Serialize a `SourceSpan` as an object carrying BOTH the LSP `range`
/// (zero-based) and the rustc-style one-based `line`/`column`, plus byte
/// offsets and the resolved (tier-stripped) file path. An optional `label`
/// rides along (the primary span's underline label).
fn serializeSpan(
    engine: *const diagnostics.DiagnosticEngine,
    out: JsonWriter,
    span: ast.SourceSpan,
    label: ?[]const u8,
) !void {
    const display_line = engine.displaySpanLinePub(span);
    const lsp_line: u32 = if (display_line > 0) display_line - 1 else 0;
    const lsp_char: u32 = if (span.col > 0) span.col - 1 else 0;
    const end_char: u32 = blk: {
        // End character on the same line: col + (end-start), zero-based.
        const width: u32 = if (span.end > span.start) span.end - span.start else 1;
        break :blk lsp_char + width;
    };

    try out.raw("{\"file\":");
    if (engine.sourceForSpanPub(span)) |source_file| {
        try out.jsonString(error_format.applyPathPolicy(engine.tier, source_file.file_path));
    } else {
        try out.raw("null");
    }
    try out.raw(",\"range\":{\"start\":{\"line\":");
    try out.print("{d}", .{lsp_line});
    try out.raw(",\"character\":");
    try out.print("{d}", .{lsp_char});
    try out.raw("},\"end\":{\"line\":");
    try out.print("{d}", .{lsp_line});
    try out.raw(",\"character\":");
    try out.print("{d}", .{end_char});
    try out.raw("}}");
    try out.raw(",\"line\":");
    try out.print("{d}", .{display_line});
    try out.raw(",\"column\":");
    try out.print("{d}", .{span.col});
    try out.raw(",\"byte_start\":");
    try out.print("{d}", .{span.start});
    try out.raw(",\"byte_end\":");
    try out.print("{d}", .{span.end});
    if (label) |label_text| {
        try out.raw(",\"label\":");
        try out.jsonString(label_text);
    }
    try out.raw("}");
}

/// Serialize one `relatedInformation` entry: `{ location: <span>, message }`,
/// matching LSP's `DiagnosticRelatedInformation`.
fn serializeRelated(
    engine: *const diagnostics.DiagnosticEngine,
    out: JsonWriter,
    span: ast.SourceSpan,
    message: []const u8,
) !void {
    try out.raw("{\"location\":");
    try serializeSpan(engine, out, span, null);
    try out.raw(",\"message\":");
    try out.jsonString(message);
    try out.raw("}");
}

/// Serialize one rustc-style `suggestion`: `{ span, replacement, description,
/// applicability }`. LSP projects `machine_applicable` ones into
/// auto-applicable `CodeAction`s.
fn serializeSuggestion(
    engine: *const diagnostics.DiagnosticEngine,
    out: JsonWriter,
    span: ast.SourceSpan,
    replacement: []const u8,
    description: []const u8,
    applicability: error_ir.Applicability,
) !void {
    try out.raw("{\"span\":");
    try serializeSpan(engine, out, span, null);
    try out.raw(",\"replacement\":");
    try out.jsonString(replacement);
    try out.raw(",\"description\":");
    try out.jsonString(description);
    try out.raw(",\"applicability\":");
    try out.jsonString(applicability.wireName());
    try out.raw("}");
}

/// A minimal JSON-emitting writer over an `ArrayListUnmanaged(u8)`. Handles
/// proper string escaping (the only correctness-critical part — control chars,
/// quotes, backslashes, and the solidus are escaped per RFC 8259). The
/// structural syntax is emitted by the caller via `raw`, which keeps the
/// serializer above readable as a literal transcription of the schema.
const JsonWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    fn raw(self: JsonWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }

    fn print(self: JsonWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(formatted);
        try self.list.appendSlice(self.alloc, formatted);
    }

    /// Emit a properly-escaped, double-quoted JSON string literal.
    fn jsonString(self: JsonWriter, value: []const u8) !void {
        try self.list.append(self.alloc, '"');
        try appendEscaped(self.list, self.alloc, value);
        try self.list.append(self.alloc, '"');
    }

    /// Emit a `std.fmt`-formatted, escaped, quoted JSON string.
    fn jsonStringFmt(self: JsonWriter, comptime fmt: []const u8, args: anytype) !void {
        const formatted = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(formatted);
        try self.jsonString(formatted);
    }
};

/// Append `value` to `list` with JSON string escaping per RFC 8259: `"` and
/// `\` are backslash-escaped; the C0 control characters get their short
/// escapes (`\n`, `\r`, `\t`, `\b`, `\f`) or `\u00XX`; everything else
/// (including UTF-8 multibyte sequences) passes through verbatim.
fn appendEscaped(
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    value: []const u8,
) !void {
    for (value) |byte| {
        switch (byte) {
            '"' => try list.appendSlice(alloc, "\\\""),
            '\\' => try list.appendSlice(alloc, "\\\\"),
            '\n' => try list.appendSlice(alloc, "\\n"),
            '\r' => try list.appendSlice(alloc, "\\r"),
            '\t' => try list.appendSlice(alloc, "\\t"),
            0x08 => try list.appendSlice(alloc, "\\b"),
            0x0c => try list.appendSlice(alloc, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                var escape: [6]u8 = .{ '\\', 'u', '0', '0', 0, 0 };
                escape[4] = hex[(byte >> 4) & 0xF];
                escape[5] = hex[byte & 0xF];
                try list.appendSlice(alloc, &escape);
            },
            else => try list.append(alloc, byte),
        }
    }
}

// ============================================================
// Tests
// ============================================================

/// Parse the produced JSON with std.json to assert it is well-formed and to
/// read fields back out. A round-trip parse is the strongest guarantee the
/// escaping and structure are valid.
fn parseDocument(alloc: std.mem.Allocator, json_text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
}

test "serialize produces a well-formed schema-versioned document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();
    try engine.setSource("pub fn foo() {\n  bar()\n}\n", "test.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .name,
        .message = "undefined function `bar/0`",
        .span = .{ .start = 15, .end = 18, .line = 2, .col = 3 },
        .label = "not found in this scope",
        .code = "Z0100",
    });

    const json_text = try serialize(&engine, alloc);
    const parsed = try parseDocument(alloc, json_text);
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, SCHEMA_VERSION), root.get("schema_version").?.integer);

    const diags = root.get("diagnostics").?.array;
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);

    const first = diags.items[0].object;
    try std.testing.expectEqualStrings("name", first.get("domain").?.string);
    try std.testing.expectEqualStrings("error", first.get("severity").?.string);
    try std.testing.expectEqual(@as(i64, 1), first.get("lsp_severity").?.integer);
    try std.testing.expectEqualStrings("Z0100", first.get("code").?.string);
    try std.testing.expectEqualStrings("undefined function `bar/0`", first.get("message").?.string);

    // LSP range is zero-based: line 2 -> 1, col 3 -> char 2.
    const primary_span = first.get("primary_span").?.object;
    try std.testing.expectEqualStrings("test.zap", primary_span.get("file").?.string);
    const range = primary_span.get("range").?.object;
    const start = range.get("start").?.object;
    try std.testing.expectEqual(@as(i64, 1), start.get("line").?.integer);
    try std.testing.expectEqual(@as(i64, 2), start.get("character").?.integer);

    // codeDescription points at `zap explain`.
    const code_desc = first.get("code_description").?.object;
    try std.testing.expectEqualStrings("zap explain Z0100", code_desc.get("href").?.string);

    // `rendered` mirrors the human text.
    const rendered = first.get("rendered").?.string;
    try std.testing.expect(std.mem.indexOf(u8, rendered, "undefined function `bar/0`") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "bar()") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "^^^ not found in this scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "test.zap:2:3") != null);
}

test "serialize propagates OOM from rendered source registration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();
    try engine.setSource("pub fn foo() {\n  bar()\n}\n", "test.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .name,
        .message = "undefined function `bar/0`",
        .span = .{ .start = 15, .end = 18, .line = 2, .col = 3 },
        .label = "not found in this scope",
        .code = "Z0100",
    });

    var saw_induced_failure = false;
    for (0..128) |fail_index| {
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failing_alloc = failing_allocator.allocator();

        const json_text = serialize(&engine, failing_alloc) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing_allocator.has_induced_failure);
            saw_induced_failure = true;
            continue;
        };
        failing_alloc.free(json_text);
        try std.testing.expect(!failing_allocator.has_induced_failure);
        break;
    }
    try std.testing.expect(saw_induced_failure);
}

test "serialize projects fixits with applicability and cause chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();
    try engine.setSource("x = 1\n", "f.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .typecheck,
        .message = "type mismatch",
        .span = .{ .start = 0, .end = 1, .line = 1, .col = 1 },
        .fixits = &.{
            .{
                .span = .{ .start = 0, .end = 1, .line = 1, .col = 1 },
                .replacement = "y",
                .description = "rename to `y`",
                .applicability = .machine_applicable,
            },
        },
        .cause_chain = &.{
            .{ .code = "Z1002", .message = "ArgumentError: bad value" },
        },
        .machine_data = &.{
            .{ .key = "expected_type", .value = "i64" },
            .{ .key = "got_type", .value = "String" },
        },
    });

    const json_text = try serialize(&engine, alloc);
    const parsed = try parseDocument(alloc, json_text);
    defer parsed.deinit();

    const first = parsed.value.object.get("diagnostics").?.array.items[0].object;

    const suggestions = first.get("suggestions").?.array;
    try std.testing.expectEqual(@as(usize, 1), suggestions.items.len);
    const suggestion = suggestions.items[0].object;
    try std.testing.expectEqualStrings("y", suggestion.get("replacement").?.string);
    try std.testing.expectEqualStrings("machine_applicable", suggestion.get("applicability").?.string);

    const causes = first.get("cause_chain").?.array;
    try std.testing.expectEqual(@as(usize, 1), causes.items.len);
    try std.testing.expectEqualStrings("Z1002", causes.items[0].object.get("code").?.string);

    const machine = first.get("machine_data").?.object;
    try std.testing.expectEqualStrings("i64", machine.get("expected_type").?.string);
    try std.testing.expectEqualStrings("String", machine.get("got_type").?.string);
}

test "serialize round-trips a multi-diagnostic compile deterministically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();
    try engine.setSource("a\nb\nc\nd\n", "multi.zap");

    // Insert OUT OF ORDER; the serializer must canonicalize.
    try engine.reportDiagnostic(.{ .severity = .@"error", .message = "third", .span = .{ .start = 4, .end = 5, .line = 3, .col = 1 } });
    try engine.reportDiagnostic(.{ .severity = .@"error", .message = "first", .span = .{ .start = 0, .end = 1, .line = 1, .col = 1 } });
    try engine.reportDiagnostic(.{ .severity = .warning, .message = "second", .span = .{ .start = 2, .end = 3, .line = 2, .col = 1 } });

    const first_pass = try serialize(&engine, alloc);
    const second_pass = try serialize(&engine, alloc);
    // Determinism: identical bytes across runs.
    try std.testing.expectEqualStrings(first_pass, second_pass);

    const parsed = try parseDocument(alloc, first_pass);
    defer parsed.deinit();
    const diags = parsed.value.object.get("diagnostics").?.array;
    try std.testing.expectEqual(@as(usize, 3), diags.items.len);
    // Canonical order is by line: first, second, third.
    try std.testing.expectEqualStrings("first", diags.items[0].object.get("message").?.string);
    try std.testing.expectEqualStrings("second", diags.items[1].object.get("message").?.string);
    try std.testing.expectEqualStrings("third", diags.items[2].object.get("message").?.string);
}

test "json string escaping handles quotes, backslashes, control chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "weird \"quote\" and \\ slash and \n newline",
        .span = .{ .start = 0, .end = 1 },
    });

    const json_text = try serialize(&engine, alloc);
    // Must parse cleanly despite the embedded specials.
    const parsed = try parseDocument(alloc, json_text);
    defer parsed.deinit();
    const msg = parsed.value.object.get("diagnostics").?.array.items[0].object.get("message").?.string;
    try std.testing.expectEqualStrings("weird \"quote\" and \\ slash and \n newline", msg);
}

test "serialize projects an ICE diagnostic with domain=ice and the failing pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = diagnostics.DiagnosticEngine.init(alloc);
    defer engine.deinit();

    var diag = diagnostics.iceDiagnostic("monomorphize", "Z9002", "internal failure in monomorphize");
    diag.span = .{ .start = 0, .end = 1 };
    try engine.reportDiagnostic(diag);

    const json_text = try serialize(&engine, alloc);
    const parsed = try parseDocument(alloc, json_text);
    defer parsed.deinit();

    const first = parsed.value.object.get("diagnostics").?.array.items[0].object;
    try std.testing.expectEqualStrings("ice", first.get("domain").?.string);
    try std.testing.expectEqualStrings("Z9002", first.get("code").?.string);
    const machine = first.get("machine_data").?.object;
    try std.testing.expectEqualStrings("monomorphize", machine.get("ice_pass").?.string);
}
