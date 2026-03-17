const std = @import("std");
const ast = @import("ast.zig");

// ============================================================
// Diagnostics Engine (spec §23)
//
// Provides structured error reporting with:
//   - Source location tracking
//   - Error severity levels
//   - Dispatch resolution traces
//   - Contextual help messages
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

pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    span: ast.SourceSpan,
    notes: []const Note,

    pub const Note = struct {
        message: []const u8,
        span: ?ast.SourceSpan,
    };
};

pub const DiagnosticEngine = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(Diagnostic),
    source: ?[]const u8,
    file_path: ?[]const u8,
    line_offset: u32,

    pub fn init(allocator: std.mem.Allocator) DiagnosticEngine {
        return .{
            .allocator = allocator,
            .diagnostics = .empty,
            .source = null,
            .file_path = null,
            .line_offset = 0,
        };
    }

    pub fn deinit(self: *DiagnosticEngine) void {
        self.diagnostics.deinit(self.allocator);
    }

    pub fn setSource(self: *DiagnosticEngine, source: []const u8, file_path: []const u8) void {
        self.source = source;
        self.file_path = file_path;
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
        try self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .message = message,
            .span = span,
            .notes = &.{},
        });
    }

    pub fn reportWithNotes(
        self: *DiagnosticEngine,
        severity: Severity,
        message: []const u8,
        span: ast.SourceSpan,
        notes: []const Diagnostic.Note,
    ) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = severity,
            .message = message,
            .span = span,
            .notes = notes,
        });
    }

    pub fn err(self: *DiagnosticEngine, message: []const u8, span: ast.SourceSpan) !void {
        try self.report(.@"error", message, span);
    }

    pub fn warn(self: *DiagnosticEngine, message: []const u8, span: ast.SourceSpan) !void {
        try self.report(.warning, message, span);
    }

    // ============================================================
    // Specialized error constructors (spec §23.1)
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
        const msg = try std.fmt.allocPrint(self.allocator, "ambiguous overload for `{s}/{d}` — multiple clauses match with equal specificity", .{ name, arity });
        try self.err(msg, span);
    }

    pub fn nonExhaustiveMatch(self: *DiagnosticEngine, span: ast.SourceSpan) !void {
        try self.err("non-exhaustive match — not all cases are covered", span);
    }

    pub fn unreachableClause(self: *DiagnosticEngine, span: ast.SourceSpan) !void {
        try self.warn("unreachable clause — previous clauses match all inputs", span);
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
    // Formatting
    // ============================================================

    pub fn format(self: *const DiagnosticEngine, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        for (self.diagnostics.items) |diag| {
            // Apply line offset (subtract stdlib lines) for user-facing line numbers
            const display_line = if (diag.span.line > self.line_offset)
                diag.span.line - self.line_offset
            else
                diag.span.line;

            // File location
            if (self.file_path) |fp| {
                try writer.print("{s}:", .{fp});
            }
            if (display_line > 0) {
                try writer.print("{d}:{d}: ", .{ display_line, diag.span.col });
            }

            // Severity and message
            try writer.print("{s}: {s}\n", .{ diag.severity.label(), diag.message });

            // Source context
            if (self.source) |src| {
                if (diag.span.line > 0) {
                    if (getSourceLine(src, diag.span.line)) |line| {
                        try writer.print(" {d} | {s}\n", .{ display_line, line });
                    }
                }
            }

            // Notes
            for (diag.notes) |note| {
                if (note.span) |s| {
                    const note_display_line = if (s.line > self.line_offset)
                        s.line - self.line_offset
                    else
                        s.line;
                    if (self.file_path) |fp| {
                        try writer.print("{s}:", .{fp});
                    }
                    try writer.print("{d}:{d}: ", .{ note_display_line, s.col });
                }
                try writer.print("note: {s}\n", .{note.message});
            }
        }

        return buf.toOwnedSlice(allocator);
    }
};

fn getSourceLine(source: []const u8, line_number: u32) ?[]const u8 {
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

    engine.setSource("def foo() do\n  bar()\nend\n", "test.zip");

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
