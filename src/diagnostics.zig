const std = @import("std");
const ast = @import("ast.zig");

// ============================================================
// Diagnostics Engine
//
// Rich error reporting with:
//   - Caret underlines (^^^ primary, ~~~ secondary)
//   - Box-drawing format (│, └─)
//   - Color support (respects NO_COLOR)
//   - Contextual labels, help text, and suggestions
//   - Error codes (Z0001-style)
//   - Multi-error support with configurable limit
// ============================================================

pub const Severity = enum {
    @"error",
    warning,
    note,
    help,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .note => "note",
            .help => "help",
        };
    }
};

pub const SecondarySpan = struct {
    span: ast.SourceSpan,
    label: []const u8,
};

pub const Suggestion = struct {
    span: ast.SourceSpan,
    replacement: []const u8,
    description: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    span: ast.SourceSpan,
    notes: []const Note = &.{},

    // Rich fields
    label: ?[]const u8 = null,
    secondary_spans: []const SecondarySpan = &.{},
    help: ?[]const u8 = null,
    suggestion: ?Suggestion = null,
    code: ?[]const u8 = null,

    pub const Note = struct {
        message: []const u8,
        span: ?ast.SourceSpan,
    };
};

// ============================================================
// Color support
// ============================================================

const Color = struct {
    enabled: bool,

    const RESET = "\x1b[0m";
    const BOLD = "\x1b[1m";
    const RED = "\x1b[31m";
    const YELLOW = "\x1b[33m";
    const CYAN = "\x1b[36m";
    const BOLD_RED = "\x1b[1;31m";
    const BOLD_YELLOW = "\x1b[1;33m";
    const BOLD_CYAN = "\x1b[1;36m";
    const BOLD_BLUE = "\x1b[1;34m";

    fn severityStyle(self: Color, severity: Severity) struct { start: []const u8, end: []const u8 } {
        if (!self.enabled) return .{ .start = "", .end = "" };
        return switch (severity) {
            .@"error" => .{ .start = BOLD_RED, .end = RESET },
            .warning => .{ .start = BOLD_YELLOW, .end = RESET },
            .note => .{ .start = BOLD_CYAN, .end = RESET },
            .help => .{ .start = BOLD, .end = RESET },
        };
    }

    fn caretStyle(self: Color, severity: Severity) struct { start: []const u8, end: []const u8 } {
        if (!self.enabled) return .{ .start = "", .end = "" };
        return switch (severity) {
            .@"error" => .{ .start = RED, .end = RESET },
            .warning => .{ .start = YELLOW, .end = RESET },
            .note, .help => .{ .start = CYAN, .end = RESET },
        };
    }

    fn gutterStyle(self: Color) struct { start: []const u8, end: []const u8 } {
        if (!self.enabled) return .{ .start = "", .end = "" };
        return .{ .start = BOLD_BLUE, .end = RESET };
    }

    fn locationStyle(self: Color) struct { start: []const u8, end: []const u8 } {
        if (!self.enabled) return .{ .start = "", .end = "" };
        return .{ .start = CYAN, .end = RESET };
    }
};

pub fn detectColor() bool {
    if (std.c.getenv("NO_COLOR")) |_| return false;
    return true; // 0.16: default to color
}

// ============================================================
// Diagnostic Engine
// ============================================================

pub const DiagnosticEngine = struct {
    pub const SourceFile = struct {
        source: []const u8,
        file_path: []const u8,
    };

    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    source: ?[]const u8,
    file_path: ?[]const u8,
    sources: std.ArrayList(SourceFile),
    line_offset: u32,
    max_errors: u32,
    use_color: bool,

    pub fn init(allocator: std.mem.Allocator) DiagnosticEngine {
        return .{
            .allocator = allocator,
            .diagnostics = .empty,
            .source = null,
            .file_path = null,
            .sources = .empty,
            .line_offset = 0,
            .max_errors = 20,
            .use_color = false,
        };
    }

    pub fn deinit(self: *DiagnosticEngine) void {
        self.diagnostics.deinit(self.allocator);
        self.sources.deinit(self.allocator);
    }

    pub fn setSource(self: *DiagnosticEngine, source: []const u8, file_path: []const u8) void {
        self.source = source;
        self.file_path = file_path;
        self.sources.clearRetainingCapacity();
        self.sources.append(self.allocator, .{ .source = source, .file_path = file_path }) catch {};
    }

    pub fn setSources(self: *DiagnosticEngine, sources: []const SourceFile) void {
        self.sources.clearRetainingCapacity();
        self.sources.appendSlice(self.allocator, sources) catch {};
        if (sources.len > 0) {
            self.source = sources[0].source;
            self.file_path = sources[0].file_path;
        } else {
            self.source = null;
            self.file_path = null;
        }
    }

    /// Set the number of lines prepended before user source (e.g. stdlib).
    /// Error line numbers will be adjusted by subtracting this offset.
    pub fn setLineOffset(self: *DiagnosticEngine, offset: u32) void {
        self.line_offset = offset;
    }

    // ============================================================
    // Error reporting
    // ============================================================

    pub fn report(self: *DiagnosticEngine, severity: Severity, message: []const u8, span: ast.SourceSpan) !void {
        try self.reportDiagnostic(.{
            .severity = severity,
            .message = message,
            .span = span,
        });
    }

    pub fn reportWithNotes(
        self: *DiagnosticEngine,
        severity: Severity,
        message: []const u8,
        span: ast.SourceSpan,
        notes: []const Diagnostic.Note,
    ) !void {
        try self.reportDiagnostic(.{
            .severity = severity,
            .message = message,
            .span = span,
            .notes = notes,
        });
    }

    pub fn reportDiagnostic(self: *DiagnosticEngine, diag: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diag);
    }

    pub fn err(self: *DiagnosticEngine, message: []const u8, span: ast.SourceSpan) !void {
        try self.report(.@"error", message, span);
    }

    pub fn warn(self: *DiagnosticEngine, message: []const u8, span: ast.SourceSpan) !void {
        try self.report(.warning, message, span);
    }

    // ============================================================
    // Specialized error constructors
    // ============================================================

    pub fn typeError(self: *DiagnosticEngine, expected: []const u8, got: []const u8, span: ast.SourceSpan) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "type mismatch: expected `{s}`, got `{s}`", .{ expected, got });
        try self.err(msg, span);
    }

    pub fn undefinedVariable(self: *DiagnosticEngine, name: []const u8, span: ast.SourceSpan) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "undefined variable `{s}`", .{name});
        try self.err(msg, span);
    }

    pub fn undefinedFunction(self: *DiagnosticEngine, name: []const u8, arity: u32, span: ast.SourceSpan) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "undefined function `{s}/{d}`", .{ name, arity });
        try self.err(msg, span);
    }

    pub fn ambiguousOverload(self: *DiagnosticEngine, name: []const u8, arity: u32, span: ast.SourceSpan) !void {
        const msg = try std.fmt.allocPrint(self.allocator, "ambiguous overload for `{s}/{d}` \u{2014} multiple clauses match with equal specificity", .{ name, arity });
        try self.err(msg, span);
    }

    pub fn nonExhaustiveMatch(self: *DiagnosticEngine, span: ast.SourceSpan) !void {
        try self.err("non-exhaustive match \u{2014} not all cases are covered", span);
    }

    pub fn unreachableClause(self: *DiagnosticEngine, span: ast.SourceSpan) !void {
        try self.warn("unreachable clause \u{2014} previous clauses match all inputs", span);
    }

    // ============================================================
    // Error count
    // ============================================================

    pub fn hasErrors(self: *const DiagnosticEngine) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn errorCount(self: *const DiagnosticEngine) usize {
        var count: usize = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .@"error") count += 1;
        }
        return count;
    }

    pub fn warningCount(self: *const DiagnosticEngine) usize {
        var count: usize = 0;
        for (self.diagnostics.items) |d| {
            if (d.severity == .warning) count += 1;
        }
        return count;
    }

    // ============================================================
    // Display helpers
    // ============================================================

    fn displayLine(self: *const DiagnosticEngine, line: u32) u32 {
        if (line > self.line_offset) return line - self.line_offset;
        return line;
    }

    fn displaySpanLine(self: *const DiagnosticEngine, span: ast.SourceSpan) u32 {
        if (span.source_id != null) return span.line;
        return self.displayLine(span.line);
    }

    fn sourceForSpan(self: *const DiagnosticEngine, span: ast.SourceSpan) ?SourceFile {
        if (span.source_id) |source_id| {
            if (source_id < self.sources.items.len) return self.sources.items[source_id];
            return null;
        }
        if (self.source != null and self.file_path != null) {
            return .{ .source = self.source.?, .file_path = self.file_path.? };
        }
        return null;
    }

    // ============================================================
    // Formatting
    // ============================================================

    pub fn format(self: *const DiagnosticEngine, allocator: std.mem.Allocator) ![]const u8 {
        // In Zig 0.16, ArrayList no longer has .writer(). Use a simple
        // accumulator approach instead.
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        // Shim: create a write interface that appends to buf
        const Writer = struct {
            list: *std.ArrayListUnmanaged(u8),
            alloc: std.mem.Allocator,
            pub fn print(self_w: @This(), comptime fmt_str: []const u8, args: anytype) !void {
                const s = try std.fmt.allocPrint(self_w.alloc, fmt_str, args);
                defer self_w.alloc.free(s);
                try self_w.list.appendSlice(self_w.alloc, s);
            }
            pub fn writeAll(self_w: @This(), data: []const u8) !void {
                try self_w.list.appendSlice(self_w.alloc, data);
            }
            pub fn writeByte(self_w: @This(), byte: u8) !void {
                try self_w.list.append(self_w.alloc, byte);
            }
            pub fn writeByteNTimes(self_w: @This(), byte: u8, n: usize) !void {
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    try self_w.list.append(self_w.alloc, byte);
                }
            }
        };
        const writer = Writer{ .list = &buf, .alloc = allocator };
        const color = Color{ .enabled = self.use_color };

        var errors_shown: usize = 0;
        var total_errors: usize = 0;

        for (self.diagnostics.items) |diag| {
            if (diag.severity == .@"error") {
                total_errors += 1;
                if (errors_shown >= self.max_errors) continue;
                errors_shown += 1;
            }
            try self.formatDiagnostic(writer, diag, color);
        }

        if (total_errors > self.max_errors) {
            const remaining = total_errors - self.max_errors;
            try writer.print("... and {d} more error{s}\n", .{
                remaining,
                @as([]const u8, if (remaining == 1) "" else "s"),
            });
        }

        return buf.toOwnedSlice(allocator);
    }

    fn formatDiagnostic(
        self: *const DiagnosticEngine,
        writer: anytype,
        diag: Diagnostic,
        color: Color,
    ) !void {
        const display_line = self.displaySpanLine(diag.span);
        const source_file = self.sourceForSpan(diag.span);

        // Compute gutter width from max line number in this diagnostic
        var max_line = display_line;
        for (diag.secondary_spans) |ss| {
            max_line = @max(max_line, self.displaySpanLine(ss.span));
        }
        for (diag.notes) |note| {
            if (note.span) |s| {
                max_line = @max(max_line, self.displaySpanLine(s));
            }
        }
        const gutter = @max(digitCount(max_line), @as(u32, 1));

        const has_source = source_file != null and diag.span.line > 0;

        // ── Header: severity[code]: message ──
        const sev = color.severityStyle(diag.severity);
        try writer.writeAll(sev.start);
        try writer.writeAll(diag.severity.label());
        if (diag.code) |code| {
            try writer.print("[{s}]", .{code});
        }
        try writer.writeAll(": ");
        try writer.writeAll(sev.end);
        if (color.enabled) try writer.writeAll(Color.BOLD);
        try writer.writeAll(diag.message);
        if (color.enabled) try writer.writeAll(Color.RESET);
        try writer.writeByte('\n');

        // ── Source context ──
        if (has_source) {
            if (getSourceLine(source_file.?.source, diag.span.line)) |line| {
                // Empty gutter line
                try writeGutterEmpty(writer, gutter, color);

                // Context: 1 line above if available
                if (diag.span.line > 1) {
                    const prev_line_num = diag.span.line - 1;
                    const prev_display = self.displayLine(prev_line_num);
                    if (prev_display > 0) {
                        if (getSourceLine(source_file.?.source, prev_line_num)) |prev_line| {
                            if (prev_line.len > 0) {
                                try writeGutterLine(writer, gutter, prev_display, prev_line, color);
                            }
                        }
                    }
                }

                // Source line with line number
                try writeGutterLine(writer, gutter, display_line, line, color);

                // Primary underline with label
                if (diag.span.col > 0) {
                    const col0 = diag.span.col - 1;
                    const line_len: u32 = @intCast(line.len);
                    const raw_len: u32 = if (diag.span.end > diag.span.start)
                        diag.span.end - diag.span.start
                    else
                        1;
                    const clamped = if (col0 < line_len)
                        @min(raw_len, line_len - col0)
                    else
                        raw_len;
                    const underline_len = @max(clamped, @as(u32, 1));
                    try writeGutterUnderline(writer, gutter, col0, underline_len, '^', diag.label, color, diag.severity);
                }

                // Secondary spans
                for (diag.secondary_spans) |ss| {
                    const ss_display = self.displaySpanLine(ss.span);
                    if (ss.span.line != diag.span.line) {
                        if (getSourceLine(source_file.?.source, ss.span.line)) |ss_line| {
                            try writeGutterLine(writer, gutter, ss_display, ss_line, color);
                        }
                    }
                    if (ss.span.col > 0) {
                        if (getSourceLine(source_file.?.source, ss.span.line)) |ss_line| {
                            const ss_col0 = ss.span.col - 1;
                            const ss_line_len: u32 = @intCast(ss_line.len);
                            const ss_raw_len: u32 = if (ss.span.end > ss.span.start)
                                ss.span.end - ss.span.start
                            else
                                1;
                            const ss_clamped = if (ss_col0 < ss_line_len)
                                @min(ss_raw_len, ss_line_len - ss_col0)
                            else
                                ss_raw_len;
                            const ss_ulen = @max(ss_clamped, @as(u32, 1));
                            try writeGutterUnderline(writer, gutter, ss_col0, ss_ulen, '~', ss.label, color, .note);
                        }
                    }
                }
            }
        }

        // ── Notes ──
        for (diag.notes) |note| {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            const note_c = color.severityStyle(.note);
            try writer.writeAll(note_c.start);
            try writer.writeAll("= note: ");
            try writer.writeAll(note_c.end);
            try writer.writeAll(note.message);
            try writer.writeByte('\n');
        }

        // ── Help ──
        if (diag.help) |help_text| {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            if (color.enabled) try writer.writeAll(Color.BOLD);
            try writer.writeAll("= help: ");
            if (color.enabled) try writer.writeAll(Color.RESET);
            try writer.writeAll(help_text);
            try writer.writeByte('\n');
        }

        // ── Suggestion code block ──
        if (diag.suggestion) |suggestion| {
            if (diag.help == null) {
                if (has_source) {
                    try writeGutterEmpty(writer, gutter, color);
                }
                try writer.writeByteNTimes(' ', gutter + 1);
                if (color.enabled) try writer.writeAll(Color.BOLD);
                try writer.writeAll("= help: ");
                if (color.enabled) try writer.writeAll(Color.RESET);
                try writer.writeAll(suggestion.description);
                try writer.writeByte('\n');
            }
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            const gs = color.gutterStyle();
            var line_iter = std.mem.splitScalar(u8, suggestion.replacement, '\n');
            while (line_iter.next()) |repl_line| {
                try writer.writeByteNTimes(' ', gutter + 1);
                try writer.writeAll(gs.start);
                try writer.writeAll("\u{2502}");
                try writer.writeAll(gs.end);
                try writer.writeByte(' ');
                try writer.writeAll(repl_line);
                try writer.writeByte('\n');
            }
        }

        // ── Footer: └─ file:line:col ──
        if ((source_file != null and source_file.?.file_path.len > 0) or display_line > 0) {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            const loc = color.locationStyle();
            try writer.writeAll(loc.start);
            try writer.writeAll("\u{2514}\u{2500} ");
            if (source_file) |sf| {
                try writer.writeAll(sf.file_path);
            }
            if (display_line > 0) {
                try writer.print(":{d}:{d}", .{ display_line, diag.span.col });
            }
            try writer.writeAll(loc.end);
            try writer.writeByte('\n');
        }

        // Blank line after diagnostic
        try writer.writeByte('\n');
    }
};

// ============================================================
// Gutter rendering helpers
// ============================================================

fn writeGutterEmpty(writer: anytype, gutter_width: u32, color: Color) !void {
    try writer.writeByteNTimes(' ', gutter_width + 1);
    const gs = color.gutterStyle();
    try writer.writeAll(gs.start);
    try writer.writeAll("\u{2502}");
    try writer.writeAll(gs.end);
    try writer.writeByte('\n');
}

fn writeGutterLine(writer: anytype, gutter_width: u32, line_num: u32, source_line: []const u8, color: Color) !void {
    const digits = digitCount(line_num);
    const padding = gutter_width - digits;
    const gs = color.gutterStyle();

    try writer.writeByteNTimes(' ', padding);
    try writer.writeAll(gs.start);
    try writer.print("{d}", .{line_num});
    try writer.writeAll(gs.end);
    try writer.writeByte(' ');
    try writer.writeAll(gs.start);
    try writer.writeAll("\u{2502}");
    try writer.writeAll(gs.end);
    try writer.writeByte(' ');
    try writer.writeAll(source_line);
    try writer.writeByte('\n');
}

fn writeGutterUnderline(
    writer: anytype,
    gutter_width: u32,
    col0: u32,
    len: u32,
    char: u8,
    label_text: ?[]const u8,
    color: Color,
    severity: Severity,
) !void {
    try writer.writeByteNTimes(' ', gutter_width + 1);
    const gs = color.gutterStyle();
    try writer.writeAll(gs.start);
    try writer.writeAll("\u{2502}");
    try writer.writeAll(gs.end);
    try writer.writeByte(' ');
    try writer.writeByteNTimes(' ', col0);

    const caret = color.caretStyle(severity);
    try writer.writeAll(caret.start);
    try writer.writeByteNTimes(char, len);
    if (label_text) |lbl| {
        try writer.writeByte(' ');
        try writer.writeAll(lbl);
    }
    try writer.writeAll(caret.end);
    try writer.writeByte('\n');
}

// ============================================================
// Utility
// ============================================================

fn digitCount(n: u32) u32 {
    if (n == 0) return 1;
    var count: u32 = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

pub fn getSourceLine(source: []const u8, line_number: u32) ?[]const u8 {
    if (line_number == 0) return null;
    var current_line: u32 = 1;
    var line_start: usize = 0;

    for (source, 0..) |c, i| {
        if (current_line == line_number) {
            if (c == '\n') {
                return source[line_start..i];
            }
        } else {
            if (c == '\n') {
                current_line += 1;
                line_start = i + 1;
            }
        }
    }

    // Last line without trailing newline
    if (current_line == line_number and line_start < source.len) {
        return source[line_start..];
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

test "diagnostic engine basic error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    engine.setSource("pub fn foo() {\n  bar()\n}\n", "test.zip");

    try engine.undefinedFunction("bar", 0, .{ .start = 2, .end = 7, .line = 2 });

    try std.testing.expect(engine.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), engine.errorCount());

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.indexOf(u8, output, "undefined function `bar/0`") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test.zip") != null);
}

test "diagnostic engine multiple diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try engine.err("first error", .{ .start = 0, .end = 5 });
    try engine.warn("a warning", .{ .start = 10, .end = 15 });
    try engine.err("second error", .{ .start = 20, .end = 25 });

    try std.testing.expectEqual(@as(usize, 2), engine.errorCount());
    try std.testing.expectEqual(@as(usize, 1), engine.warningCount());
}

test "diagnostic engine type error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try engine.typeError("i64", "String", .{ .start = 0, .end = 5 });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.indexOf(u8, output, "type mismatch: expected `i64`, got `String`") != null);
}

test "getSourceLine" {
    const source = "line one\nline two\nline three";
    try std.testing.expectEqualStrings("line one", getSourceLine(source, 1).?);
    try std.testing.expectEqualStrings("line two", getSourceLine(source, 2).?);
    try std.testing.expectEqualStrings("line three", getSourceLine(source, 3).?);
    try std.testing.expect(getSourceLine(source, 4) == null);
    try std.testing.expect(getSourceLine(source, 0) == null);
}

test "diagnostic no errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try std.testing.expect(!engine.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), engine.errorCount());
}

test "rich format with caret underlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("pub fn foo() {\n  bar()\n}\n", "test.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "I cannot find a function named `bar/0`",
        .span = .{ .start = 15, .end = 18, .line = 2, .col = 3 },
        .label = "not found in this scope",
    });

    const output = try engine.format(alloc);
    // Header
    try std.testing.expect(std.mem.indexOf(u8, output, "error: I cannot find a function named `bar/0`") != null);
    // Source line
    try std.testing.expect(std.mem.indexOf(u8, output, "bar()") != null);
    // Caret underline
    try std.testing.expect(std.mem.indexOf(u8, output, "^^^ not found in this scope") != null);
    // Footer
    try std.testing.expect(std.mem.indexOf(u8, output, "test.zap:2:3") != null);
}

test "rich format with help text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("def main()\n  1\nend\n", "test.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "I was expecting the `do` keyword to start the function body",
        .span = .{ .start = 0, .end = 3, .line = 1, .col = 1 },
        .label = "this function needs a `do` ... `end` block",
        .help = "add `do` after the function signature",
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.indexOf(u8, output, "= help: add `do` after the function signature") != null);
}

test "rich format with error code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "missing `do` keyword",
        .span = .{ .start = 0, .end = 3 },
        .code = "Z0001",
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.indexOf(u8, output, "error[Z0001]: missing `do` keyword") != null);
}

test "max error limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.max_errors = 3;

    // Add 5 errors
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try engine.err("an error", .{ .start = 0, .end = 1 });
    }

    const output = try engine.format(alloc);
    // Should show overflow message
    try std.testing.expect(std.mem.indexOf(u8, output, "... and 2 more errors") != null);
}

test "box drawing characters present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("x = 1\ny = 2\n", "test.zap");

    try engine.err("something wrong", .{ .start = 0, .end = 1, .line = 1, .col = 1 });

    const output = try engine.format(alloc);
    // Box drawing vertical bar in gutter
    try std.testing.expect(std.mem.indexOf(u8, output, "\u{2502}") != null);
    // Footer box drawing
    try std.testing.expect(std.mem.indexOf(u8, output, "\u{2514}\u{2500}") != null);
}

test "digitCount" {
    try std.testing.expectEqual(@as(u32, 1), digitCount(0));
    try std.testing.expectEqual(@as(u32, 1), digitCount(1));
    try std.testing.expectEqual(@as(u32, 1), digitCount(9));
    try std.testing.expectEqual(@as(u32, 2), digitCount(10));
    try std.testing.expectEqual(@as(u32, 2), digitCount(99));
    try std.testing.expectEqual(@as(u32, 3), digitCount(100));
    try std.testing.expectEqual(@as(u32, 4), digitCount(1000));
}

test "secondary spans with tildes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("name = get_input()\nnaem + 1\n", "test.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "I cannot find a variable named `naem`",
        .span = .{ .start = 19, .end = 23, .line = 2, .col = 1 },
        .label = "not found in this scope",
        .secondary_spans = &[_]SecondarySpan{
            .{
                .span = .{ .start = 0, .end = 4, .line = 1, .col = 1 },
                .label = "did you mean `name`?",
            },
        },
        .help = "a variable with a similar name exists",
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.indexOf(u8, output, "^^^ not found in this scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "~~~~ did you mean `name`?") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "= help:") != null);
}

test "diagnostic engine selects source by span source_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSources(&.{
        .{ .source = "first\n", .file_path = "first.zap" },
        .{ .source = "second\nthird\n", .file_path = "second.zap" },
    });

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "boom",
        .span = .{ .start = 0, .end = 5, .line = 2, .col = 1, .source_id = 1 },
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.indexOf(u8, output, "second.zap:2:1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "third") != null);
}
