const std = @import("std");
const ast = @import("ast.zig");
const env = @import("env.zig");
const error_ir = @import("error_ir.zig");
const error_format = @import("error_format.zig");

pub const Domain = error_ir.Domain;
pub const Applicability = error_ir.Applicability;
pub const TracePolicy = error_ir.TracePolicy;
pub const Visibility = error_ir.Visibility;
pub const RelatedSpan = error_ir.RelatedSpan;
pub const FixIt = error_ir.FixIt;
pub const Cause = error_ir.Cause;
pub const MachineDatum = error_ir.MachineDatum;
pub const SecurityTier = error_format.SecurityTier;

// ============================================================
// Diagnostics Engine — the ONE renderer (Phase 4.a)
//
// Renders ANY diagnostic from the canonical Error IR (`src/error_ir.zig`):
// compile errors, runtime panics, ERT traces, and leak/cycle reports all
// lower into the same `Diagnostic` shape and render with ONE visual language.
//
// Rich error reporting with:
//   - Caret underlines (^^^ primary, ~~~ secondary)
//   - Box-drawing format (│, └─)
//   - Color support (respects NO_COLOR), ONE TTY/NO_COLOR policy
//   - Contextual labels, help text, fixits (with applicability), and notes
//   - Error codes (Zxxxx) + domain classification
//   - Cause chains (`caused by:`) for wrapped errors
//   - Security tiers (dev-local / CI-internal / user-safe): release strips
//     absolute paths to basename; never emits heap contents
//   - Deterministic sort/dedup ordering (source_id, line, col, code)
//   - Multi-error support with configurable limit
//
// The visual constants (header sigil, frame prefix, box glyphs, SGR colors)
// live in `src/error_format.zig` and are SHARED with the async-signal-safe
// runtime crash printer (`src/runtime.zig`) so the two surfaces never drift.
// The runtime path cannot share this allocating renderer — it writes the same
// constants via write(2) — but it draws from the same format spec.
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

/// The canonical Error IR record (Phase 4.a). Every diagnostic surface lowers
/// into this single shape; the renderer, the JSON serializer, and (later) LSP
/// all read it. The classic span-centric fields (`severity`, `message`,
/// `span`, `notes`, `label`, `secondary_spans`, `help`, `suggestion`, `code`)
/// are the compile-time frontend's ergonomic constructors; the canonical-IR
/// fields below (`domain`, `related_spans`, `fixits`, `cause_chain`,
/// `trace_policy`, `machine_data`, `visibility`) are the cross-surface
/// superset the brief mandates. All new fields default, so every existing
/// construction site is unchanged (backward-compatible generalization).
///
/// `span` is the brief's `primary_span`; `message` is the rendered form of the
/// brief's `message_template`. `secondary_spans` (legacy, tilde-underlined,
/// rendered inline under the source) and `related_spans` (canonical,
/// LSP `relatedInformation`, rendered as separate `note:`-style lines) coexist:
/// the frontend's two-sided type errors (4.b) populate `related_spans`, while
/// the existing "did you mean" suggestions keep using `secondary_spans`.
pub const Diagnostic = struct {
    severity: Severity,
    message: []const u8,
    /// The brief's `primary_span` — where the diagnostic points.
    span: ast.SourceSpan,
    notes: []const Note = &.{},

    // Rich (legacy compile-time) fields — unchanged shape.
    label: ?[]const u8 = null,
    secondary_spans: []const SecondarySpan = &.{},
    help: ?[]const u8 = null,
    suggestion: ?Suggestion = null,
    code: ?[]const u8 = null,

    // ── Canonical Error IR superset (Phase 4.a) ──
    /// Which subsystem produced this report. Drives JSON's `domain` field and
    /// future grouping; the visual language does not change per domain.
    domain: Domain = .typecheck,
    /// Labeled secondary locations — LSP `relatedInformation`. 4.b's two-sided
    /// `TypeProvenance` populates these.
    related_spans: []const RelatedSpan = &.{},
    /// Machine-applicable code edits with applicability tags. Projected into
    /// JSON `suggestions[]` and LSP `CodeAction`s.
    fixits: []const FixIt = &.{},
    /// Wrapped underlying causes, rendered as `caused by:` lines.
    cause_chain: []const Cause = &.{},
    /// How much trace context rides along (none for compile errors).
    trace_policy: TracePolicy = .none,
    /// Structured machine-only payload (never in the human text; rides in JSON).
    machine_data: []const MachineDatum = &.{},
    /// Public-API vs internal surface — gated by the security tier.
    visibility: Visibility = .public,
    /// Macro-expansion provenance (Phase 4.b). When this diagnostic points at a
    /// node produced by a macro expansion, `expansion` is the innermost
    /// `ExpansionInfo` frame; following its `parent` chain walks back out to
    /// user source. The renderer prints an "in expansion of macro `X`" frame
    /// list (Rust/Elixir macro backtrace) so the reader sees the chain from the
    /// error site out to the call they actually wrote. Null for ordinary
    /// source-level diagnostics (the common case).
    expansion: ?*const ast.ExpansionInfo = null,
    /// The failing compiler pass/phase for a `domain=ice` diagnostic (Phase
    /// 4.b) — e.g. `"zir_api.update"`, `"monomorphize"`, `"sema"`. Drives the
    /// ICE footer ("internal compiler error in <pass>, please report") and the
    /// JSON `ice_pass` field. Null for non-ICE diagnostics.
    ice_pass: ?[]const u8 = null,

    pub const Note = struct {
        message: []const u8,
        span: ?ast.SourceSpan,
    };
};

/// Stable internal-code prefix for an internal compiler error (Phase 4.b). The
/// `Z9xxx` band is reserved for ICEs so a user can tell a compiler bug from a
/// language error at a glance, and so `zap explain Z9xxx` routes to the ICE
/// catalog entry.
pub const ICE_CODE_PREFIX = "Z9";

/// Build a structured internal-compiler-error diagnostic (Phase 4.b). Nothing
/// internal ever escapes as a bare string: an OOM in a pass, a Sema failure,
/// the `zir_api: update failed` path, or any unreachable compiler state lowers
/// into THIS shape — `domain=ice`, the failing `pass` name, a stable `code`,
/// and a "this is a compiler bug, please report" footer (the Rust ICE-hook
/// model). The failing `pass` rides in the dedicated `ice_pass` field (surfaced
/// in JSON's `machine_data.ice_pass` and the renderer's footer). The span
/// defaults to "no location" (an ICE often has no user span); callers that have
/// one set `.span` after constructing.
pub fn iceDiagnostic(pass: []const u8, code: []const u8, message: []const u8) Diagnostic {
    return .{
        .severity = .@"error",
        .domain = .ice,
        .code = code,
        .message = message,
        .span = .{ .start = 0, .end = 0, .line = 0, .col = 0 },
        .visibility = .internal,
        .ice_pass = pass,
    };
}

// ============================================================
// Color support
// ============================================================

const Color = struct {
    enabled: bool,

    // The SGR vocabulary is the SHARED palette in `error_format.sgr`, so the
    // compile renderer and the runtime crash printer emit identical color
    // bytes. These aliases keep the existing call sites readable.
    const RESET = error_format.sgr.reset;
    const BOLD = error_format.sgr.bold;
    const RED = error_format.sgr.red;
    const YELLOW = error_format.sgr.yellow;
    const CYAN = error_format.sgr.cyan;
    const BOLD_RED = error_format.sgr.bold_red;
    const BOLD_YELLOW = error_format.sgr.bold_yellow;
    const BOLD_CYAN = error_format.sgr.bold_cyan;
    const BOLD_BLUE = error_format.sgr.bold_blue;

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
    if (env.getenv("NO_COLOR")) |_| return false;
    return true; // 0.16: default to color
}

// ============================================================
// Diagnostic output policy (process-wide, set once at CLI parse)
// ============================================================

/// How rendered diagnostics are formatted at the CLI boundary. `text` is the
/// human-facing renderer (the default); `json` emits the stable
/// LSP-projectable schema (`src/error_json.zig`) for LSP / CI / `zap fix`.
pub const OutputFormat = enum { text, json };

/// The process-wide diagnostic-output policy. Set ONCE at CLI argument
/// parsing (`--error-format=json`, release tier) — the same one-shot,
/// cache-at-startup discipline the runtime crash printer uses — and read by
/// the central `compiler.emitDiagnostics` funnel. A single source of truth so
/// every diagnostic emit site (parse errors, type errors, lints) honors the
/// flag without threading it through every call.
pub const OutputPolicy = struct {
    format: OutputFormat = .text,
    tier: SecurityTier = .dev_local,
};

var output_policy: OutputPolicy = .{};

/// Install the process-wide diagnostic-output policy. Idempotent-by-overwrite;
/// the CLI calls it once after parsing arguments and before any compile begins.
pub fn setOutputPolicy(policy: OutputPolicy) void {
    output_policy = policy;
}

/// The current process-wide diagnostic-output policy.
pub fn outputPolicy() OutputPolicy {
    return output_policy;
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
    /// Security tier (brief VI.B #9). `dev_local` by default — full paths and
    /// internal detail; the CLI sets `user_safe` for a release build so the
    /// renderer strips absolute paths to basename and suppresses internal-only
    /// detail. The compile renderer and the runtime crash printer share this
    /// tier vocabulary (`error_format.SecurityTier`).
    tier: SecurityTier = .dev_local,
    /// Optional string interner (Phase 4.b). When set, the renderer can resolve
    /// interned `StringId`s — specifically the `macro_name` on an
    /// `ExpansionInfo` frame — into their text for the macro-expansion
    /// backtrace. Null when no interner is available (e.g. a runtime/leak
    /// engine), in which case the backtrace falls back to a generic label.
    interner: ?*const ast.StringInterner = null,
    mutex: std.atomic.Mutex = .unlocked,

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
            .tier = .dev_local,
        };
    }

    /// Attach a string interner so the renderer can resolve interned names
    /// (the macro-expansion backtrace's `macro_name`). Idempotent-by-overwrite.
    pub fn setInterner(self: *DiagnosticEngine, interner: *const ast.StringInterner) void {
        self.interner = interner;
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
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        defer self.mutex.unlock();
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

    /// Public accessor for the display line of a span (applies the stdlib
    /// `line_offset`). Used by the JSON serializer (`error_json.zig`) so it
    /// resolves coordinates identically to the text renderer.
    pub fn displaySpanLinePub(self: *const DiagnosticEngine, span: ast.SourceSpan) u32 {
        return self.displaySpanLine(span);
    }

    /// Public accessor for the source file backing a span. Used by the JSON
    /// serializer so it resolves the file path (and applies the tier's path
    /// policy) identically to the text renderer's footer.
    pub fn sourceForSpanPub(self: *const DiagnosticEngine, span: ast.SourceSpan) ?SourceFile {
        return self.sourceForSpan(span);
    }

    // ============================================================
    // Deterministic ordering (brief VI.B #11)
    // ============================================================

    /// Return a freshly-allocated, deterministically-ordered, de-duplicated
    /// copy of the diagnostics for rendering. Sorted by the canonical key
    /// (source_id, then line, then column, then code, then message) so the
    /// same set of diagnostics always renders byte-identically — a hard
    /// requirement for snapshot tests across all four surfaces (brief VI.B
    /// #11). Exact duplicates (same key AND same severity) are dropped, since
    /// the same error reported twice by two passes should appear once. Caller
    /// owns and frees the returned slice.
    pub fn orderedDiagnostics(self: *const DiagnosticEngine, allocator: std.mem.Allocator) ![]Diagnostic {
        const copy = try allocator.alloc(Diagnostic, self.diagnostics.items.len);
        errdefer allocator.free(copy);
        @memcpy(copy, self.diagnostics.items);

        std.sort.block(Diagnostic, copy, {}, diagnosticOrderLess);

        // Drop adjacent exact duplicates (post-sort, equal keys are adjacent).
        var write_index: usize = 0;
        for (copy, 0..) |diag, read_index| {
            if (read_index > 0 and diagnosticsEqualForDedup(copy[write_index - 1], diag)) {
                continue;
            }
            copy[write_index] = diag;
            write_index += 1;
        }
        return try allocator.realloc(copy, write_index);
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

        // Deterministic ordering (brief VI.B #11): the same set of diagnostics
        // must render identically across runs regardless of insertion order
        // (parallel AstGen workers, hash-map iteration, etc. can vary it).
        // Sort a COPY by (source_id, line, col, code, message) and drop exact
        // duplicates so snapshots are stable.
        const ordered = try self.orderedDiagnostics(allocator);
        defer allocator.free(ordered);

        var errors_shown: usize = 0;
        var total_errors: usize = 0;

        for (ordered) |diag| {
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

        // ── Related spans (canonical IR; LSP relatedInformation) ──
        // Each labeled secondary location renders as its own `= note:` line
        // carrying the location, so a two-sided type error (4.b) reads as
        // "expected i64 from here (foo.zap:3)" etc. The tier strips the path.
        for (diag.related_spans) |related| {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            const related_c = color.severityStyle(.note);
            try writer.writeAll(related_c.start);
            try writer.writeAll("= note: ");
            try writer.writeAll(related_c.end);
            try writer.writeAll(related.message);
            const related_source = self.sourceForSpan(related.span);
            if (related_source) |rs| {
                const related_line = self.displaySpanLine(related.span);
                if (related_line > 0) {
                    try writer.writeAll(" (");
                    try writer.writeAll(error_format.applyPathPolicy(self.tier, rs.file_path));
                    try writer.print(":{d}:{d})", .{ related_line, related.span.col });
                }
            }
            try writer.writeByte('\n');
        }

        // ── Fixits (canonical IR; rustc suggestions / LSP CodeAction) ──
        // A fixit renders like the legacy suggestion: a `= help:` description
        // line followed by the replacement code block in the gutter. The
        // applicability tag is machine-only (JSON) — the human text stays
        // clean — except that a non-machine-applicable fixit is hedged with
        // "(may be incorrect)" so a reader does not paste a guess verbatim.
        for (diag.fixits) |fixit| {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            if (color.enabled) try writer.writeAll(Color.BOLD);
            try writer.writeAll("= help: ");
            if (color.enabled) try writer.writeAll(Color.RESET);
            try writer.writeAll(fixit.description);
            switch (fixit.applicability) {
                .machine_applicable => {},
                .maybe_incorrect => try writer.writeAll(" (may be incorrect)"),
                .has_placeholders => try writer.writeAll(" (contains placeholders)"),
                .unspecified => {},
            }
            try writer.writeByte('\n');
            if (fixit.replacement.len > 0) {
                if (has_source) {
                    try writeGutterEmpty(writer, gutter, color);
                }
                const gs = color.gutterStyle();
                var fixit_lines = std.mem.splitScalar(u8, fixit.replacement, '\n');
                while (fixit_lines.next()) |fixit_line| {
                    try writer.writeByteNTimes(' ', gutter + 1);
                    try writer.writeAll(gs.start);
                    try writer.writeAll(error_format.gutter_bar);
                    try writer.writeAll(gs.end);
                    try writer.writeByte(' ');
                    try writer.writeAll(fixit_line);
                    try writer.writeByte('\n');
                }
            }
        }

        // ── Cause chain (`caused by:` lines) ──
        // Each wrapped underlying cause renders as a `caused by: <code> message`
        // line, mirroring the `Error` protocol's `cause` field / Elixir-Go
        // error wrapping, so a user sees the full provenance of a re-raised
        // error.
        for (diag.cause_chain) |cause| {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            const cause_c = color.severityStyle(.note);
            try writer.writeAll(cause_c.start);
            try writer.writeAll(error_format.cause_prefix);
            try writer.writeAll(cause_c.end);
            if (cause.code) |cause_code| {
                try writer.print("[{s}] ", .{cause_code});
            }
            try writer.writeAll(cause.message);
            try writer.writeByte('\n');
        }

        // ── Macro-expansion backtrace (Phase 4.b) ──
        // When the diagnostic points at a node produced by a macro expansion,
        // render the expansion chain from the innermost frame out to user
        // source as a list of "in expansion of macro `X`" lines, each carrying
        // the call site's `file:line:col`. This is the Rust/Elixir macro
        // backtrace: the primary span points at the error inside the expanded
        // code, and the frame list tells the reader which macro call (that they
        // actually wrote) produced it. Reuses the shared `= note:` styling so it
        // reads as context, not a second error.
        if (diag.expansion) |innermost_frame| {
            var frame: ?*const ast.ExpansionInfo = innermost_frame;
            while (frame) |current| : (frame = current.parent) {
                if (has_source) {
                    try writeGutterEmpty(writer, gutter, color);
                }
                try writer.writeByteNTimes(' ', gutter + 1);
                const frame_c = color.severityStyle(.note);
                try writer.writeAll(frame_c.start);
                try writer.writeAll("= note: in expansion of macro `");
                if (self.interner) |interner| {
                    try writer.writeAll(interner.get(current.macro_name));
                } else {
                    try writer.writeAll("?");
                }
                try writer.writeAll("`");
                try writer.writeAll(frame_c.end);
                const call_source = self.sourceForSpan(current.call_site);
                if (call_source) |cs| {
                    const call_line = self.displaySpanLine(current.call_site);
                    if (call_line > 0) {
                        try writer.writeAll(" (");
                        try writer.writeAll(error_format.applyPathPolicy(self.tier, cs.file_path));
                        try writer.print(":{d}:{d})", .{ call_line, current.call_site.col });
                    }
                }
                try writer.writeByte('\n');
            }
        }

        // ── ICE footer (Phase 4.b) ──
        // An internal compiler error renders the canonical Rust-style "this is
        // a compiler bug" notice naming the failing pass, so nothing internal
        // ever reaches the user as a bare unexplained string and the user knows
        // to file a report (with this repro) rather than fix their own code.
        if (diag.domain == .ice) {
            if (has_source) {
                try writeGutterEmpty(writer, gutter, color);
            }
            try writer.writeByteNTimes(' ', gutter + 1);
            const ice_c = color.severityStyle(.note);
            try writer.writeAll(ice_c.start);
            try writer.writeAll("= note: ");
            try writer.writeAll(ice_c.end);
            if (diag.ice_pass) |pass| {
                try writer.print("internal compiler error in pass `{s}` \u{2014} this is a compiler bug, please report it", .{pass});
            } else {
                try writer.writeAll("internal compiler error \u{2014} this is a compiler bug, please report it");
            }
            try writer.writeByte('\n');
            if (diag.code) |code| {
                if (has_source) {
                    try writeGutterEmpty(writer, gutter, color);
                }
                try writer.writeByteNTimes(' ', gutter + 1);
                try writer.writeAll(ice_c.start);
                try writer.writeAll("= note: ");
                try writer.writeAll(ice_c.end);
                try writer.print("include this repro and the code `{s}` at https://github.com/trycog/cog-cli/issues", .{code});
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
                // Security tier (brief VI.B #9): release (`user_safe`) strips
                // absolute paths to basename so a shipped binary never leaks
                // filesystem layout; dev/CI keep the full path for navigation.
                try writer.writeAll(error_format.applyPathPolicy(self.tier, sf.file_path));
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

/// Canonical total order over diagnostics for deterministic rendering (brief
/// VI.B #11). Orders by, in priority: source file (`source_id`, null sorts
/// first as "the single implicit source"), then line, then column, then code
/// (lexicographic; absent code sorts after any present code so coded errors
/// lead), then message (final tiebreak). A stable, run-independent key so the
/// renderer's output is snapshot-stable across parallel-worker insertion
/// orders and hash-map iteration.
pub fn diagnosticOrderLess(_: void, a: Diagnostic, b: Diagnostic) bool {
    const a_src = a.span.source_id orelse 0;
    const b_src = b.span.source_id orelse 0;
    if (a_src != b_src) return a_src < b_src;
    if (a.span.line != b.span.line) return a.span.line < b.span.line;
    if (a.span.col != b.span.col) return a.span.col < b.span.col;

    // Coded diagnostics lead uncoded ones at the same position; among coded,
    // order by code text.
    const a_code = a.code orelse "";
    const b_code = b.code orelse "";
    const code_order = std.mem.order(u8, a_code, b_code);
    if (code_order != .eq) {
        // Empty (absent) code sorts LAST so a coded diagnostic precedes an
        // uncoded one sharing a position.
        if (a_code.len == 0) return false;
        if (b_code.len == 0) return true;
        return code_order == .lt;
    }

    return std.mem.order(u8, a.message, b.message) == .lt;
}

/// True when two diagnostics are exact duplicates for dedup purposes: same
/// position, same severity, same code, same message. Two passes reporting the
/// identical error collapse to one rendered diagnostic.
fn diagnosticsEqualForDedup(a: Diagnostic, b: Diagnostic) bool {
    if (a.severity != b.severity) return false;
    if ((a.span.source_id orelse 0) != (b.span.source_id orelse 0)) return false;
    if (a.span.line != b.span.line) return false;
    if (a.span.col != b.span.col) return false;
    if (!std.mem.eql(u8, a.code orelse "", b.code orelse "")) return false;
    return std.mem.eql(u8, a.message, b.message);
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
    try std.testing.expect(std.mem.find(u8, output, "undefined function `bar/0`") != null);
    try std.testing.expect(std.mem.find(u8, output, "test.zip") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "type mismatch: expected `i64`, got `String`") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "error: I cannot find a function named `bar/0`") != null);
    // Source line
    try std.testing.expect(std.mem.find(u8, output, "bar()") != null);
    // Caret underline
    try std.testing.expect(std.mem.find(u8, output, "^^^ not found in this scope") != null);
    // Footer
    try std.testing.expect(std.mem.find(u8, output, "test.zap:2:3") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "= help: add `do` after the function signature") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "error[Z0001]: missing `do` keyword") != null);
}

test "max error limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.max_errors = 3;

    // Add 5 DISTINCT errors (distinct positions). Distinctness matters: the
    // renderer now de-duplicates byte-identical diagnostics (brief VI.B #11),
    // so the cap must be exercised with genuinely different errors, not the
    // same error reported five times (which correctly collapses to one).
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const msg = try std.fmt.allocPrint(alloc, "error number {d}", .{i});
        try engine.err(msg, .{ .start = i, .end = i + 1, .line = i + 1, .col = 1 });
    }

    const output = try engine.format(alloc);
    // Should show overflow message
    try std.testing.expect(std.mem.find(u8, output, "... and 2 more errors") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "\u{2502}") != null);
    // Footer box drawing
    try std.testing.expect(std.mem.find(u8, output, "\u{2514}\u{2500}") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "^^^ not found in this scope") != null);
    try std.testing.expect(std.mem.find(u8, output, "~~~~ did you mean `name`?") != null);
    try std.testing.expect(std.mem.find(u8, output, "= help:") != null);
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
    try std.testing.expect(std.mem.find(u8, output, "second.zap:2:1") != null);
    try std.testing.expect(std.mem.find(u8, output, "third") != null);
}

// ============================================================
// Phase 4.a — canonical Error IR / unified renderer tests
// ============================================================

test "deterministic ordering: same diagnostics render identically across runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("a\nb\nc\nd\ne\n", "ord.zap");

    // Insert in a deliberately scrambled order.
    try engine.err("on line three", .{ .start = 4, .end = 5, .line = 3, .col = 1 });
    try engine.err("on line one", .{ .start = 0, .end = 1, .line = 1, .col = 1 });
    try engine.err("on line five", .{ .start = 8, .end = 9, .line = 5, .col = 1 });
    try engine.err("on line two", .{ .start = 2, .end = 3, .line = 2, .col = 1 });

    const first = try engine.format(alloc);
    const second = try engine.format(alloc);
    try std.testing.expectEqualStrings(first, second);

    // Canonical order is by line: one, two, three, five.
    const idx_one = std.mem.find(u8, first, "on line one").?;
    const idx_two = std.mem.find(u8, first, "on line two").?;
    const idx_three = std.mem.find(u8, first, "on line three").?;
    const idx_five = std.mem.find(u8, first, "on line five").?;
    try std.testing.expect(idx_one < idx_two);
    try std.testing.expect(idx_two < idx_three);
    try std.testing.expect(idx_three < idx_five);
}

test "deterministic dedup: byte-identical diagnostics collapse to one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("x = 1\n", "dup.zap");

    // The same error reported three times by three passes.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try engine.reportDiagnostic(.{
            .severity = .@"error",
            .message = "redefinition of `x`",
            .span = .{ .start = 0, .end = 1, .line = 1, .col = 1 },
            .code = "Z0101",
        });
    }

    const ordered = try engine.orderedDiagnostics(alloc);
    defer alloc.free(ordered);
    try std.testing.expectEqual(@as(usize, 1), ordered.len);

    // But two errors that DIFFER (different code) at the same spot are kept.
    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .message = "different error",
        .span = .{ .start = 0, .end = 1, .line = 1, .col = 1 },
        .code = "Z0102",
    });
    const ordered2 = try engine.orderedDiagnostics(alloc);
    defer alloc.free(ordered2);
    try std.testing.expectEqual(@as(usize, 2), ordered2.len);
}

test "security tier user_safe strips absolute path to basename" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("x = 1\n", "/Users/dev/project/src/secret_path.zap");

    try engine.err("boom", .{ .start = 0, .end = 1, .line = 1, .col = 1 });

    // dev_local: full path visible.
    engine.tier = .dev_local;
    const dev_output = try engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, dev_output, "/Users/dev/project/src/secret_path.zap") != null);

    // user_safe: only the basename, no leading directories.
    engine.tier = .user_safe;
    const safe_output = try engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, safe_output, "secret_path.zap") != null);
    try std.testing.expect(std.mem.find(u8, safe_output, "/Users/dev/project") == null);
}

test "cause chain renders caused-by lines with codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("call_thing()\n", "c.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .runtime,
        .message = "request failed",
        .span = .{ .start = 0, .end = 10, .line = 1, .col = 1 },
        .code = "Z1001",
        .cause_chain = &.{
            .{ .code = "Z1002", .message = "ArgumentError: invalid host" },
            .{ .message = "connection refused" },
        },
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, output, "caused by: [Z1002] ArgumentError: invalid host") != null);
    try std.testing.expect(std.mem.find(u8, output, "caused by: connection refused") != null);
}

test "fixit renders help line plus replacement block and hedges non-machine-applicable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("naem + 1\n", "fx.zap");

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .name,
        .message = "cannot find `naem`",
        .span = .{ .start = 0, .end = 4, .line = 1, .col = 1 },
        .fixits = &.{
            .{
                .span = .{ .start = 0, .end = 4, .line = 1, .col = 1 },
                .replacement = "name",
                .description = "did you mean `name`?",
                .applicability = .maybe_incorrect,
            },
        },
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, output, "= help: did you mean `name`? (may be incorrect)") != null);
    // Replacement appears in a gutter code block.
    try std.testing.expect(std.mem.find(u8, output, "name") != null);
}

test "unified renderer: a runtime panic uses the SAME visual language as a compile error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A compile error.
    var compile_engine = DiagnosticEngine.init(alloc);
    defer compile_engine.deinit();
    compile_engine.setSource("pub fn foo() {\n  bar()\n}\n", "app.zap");
    try compile_engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .name,
        .message = "undefined function `bar/0`",
        .span = .{ .start = 17, .end = 20, .line = 2, .col = 3 },
        .code = "Z0100",
        .label = "not found in this scope",
    });
    const compile_output = try compile_engine.format(alloc);

    // A runtime panic lowered into the SAME canonical IR + SAME renderer.
    var runtime_engine = DiagnosticEngine.init(alloc);
    defer runtime_engine.deinit();
    runtime_engine.setSource("def main() do\n  raise \"boom\"\nend\n", "app.zap");
    try runtime_engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .runtime,
        .message = "boom",
        .span = .{ .start = 16, .end = 21, .line = 2, .col = 3 },
        .code = "Z1001",
        .trace_policy = .full,
    });
    const runtime_output = try runtime_engine.format(alloc);

    // Both share the visual language: the `error[Zxxxx]:` header, the box
    // gutter glyph, and the footer corner.
    try std.testing.expect(std.mem.find(u8, compile_output, "error[Z0100]:") != null);
    try std.testing.expect(std.mem.find(u8, runtime_output, "error[Z1001]:") != null);
    for ([_][]const u8{ compile_output, runtime_output }) |out| {
        try std.testing.expect(std.mem.find(u8, out, "\u{2502}") != null); // gutter bar
        try std.testing.expect(std.mem.find(u8, out, "\u{2514}\u{2500}") != null); // footer corner
        try std.testing.expect(std.mem.find(u8, out, "app.zap:2:3") != null);
    }
}

test "unified renderer: a synthetic leak report uses the SAME visual language" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A leak report (Phase 4.c will populate `domain=leak`; the renderer must
    // already render it with the one visual language).
    var leak_engine = DiagnosticEngine.init(alloc);
    defer leak_engine.deinit();
    leak_engine.setSource("def build() do\n  alloc_thing()\nend\n", "leaky.zap");
    try leak_engine.reportDiagnostic(.{
        .severity = .warning,
        .domain = .leak,
        .message = "memory leak: 1 object (48 bytes) never released",
        .span = .{ .start = 17, .end = 28, .line = 2, .col = 3 },
        .label = "allocated here, never freed",
        .trace_policy = .allocation,
        .machine_data = &.{
            .{ .key = "bytes", .value = "48" },
            .{ .key = "count", .value = "1" },
        },
    });

    const leak_output = try leak_engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, leak_output, "warning: memory leak") != null);
    try std.testing.expect(std.mem.find(u8, leak_output, "\u{2502}") != null);
    try std.testing.expect(std.mem.find(u8, leak_output, "\u{2514}\u{2500}") != null);
    try std.testing.expect(std.mem.find(u8, leak_output, "allocated here, never freed") != null);
    try std.testing.expect(std.mem.find(u8, leak_output, "leaky.zap:2:3") != null);
}

test "related spans render as note lines with location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("let x: i64 = get()\nx = \"hello\"\n", "prov.zap");

    // Two-sided type error (the shape 4.b's TypeProvenance produces).
    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .typecheck,
        .message = "type mismatch: expected `i64`, got `String`",
        .span = .{ .start = 23, .end = 30, .line = 2, .col = 5 },
        .label = "this is a `String`",
        .related_spans = &.{
            .{ .span = .{ .start = 7, .end = 10, .line = 1, .col = 8 }, .message = "expected `i64` because of this annotation" },
        },
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, output, "= note: expected `i64` because of this annotation (prov.zap:1:8)") != null);
}

// ============================================================
// Phase 4.b — ICE class + macro-expansion backtrace rendering
// ============================================================

test "ICE diagnostic renders a compiler-bug footer with the failing pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();

    // An internal failure surfaced as a structured ICE — never a bare string.
    var diag = iceDiagnostic("zir_api.update", "Z9001", "ZIR lowering failed: OutOfMemory");
    diag.span = .{ .start = 0, .end = 1, .line = 0, .col = 0 };
    try engine.reportDiagnostic(diag);

    const output = try engine.format(alloc);
    // Header carries the message; footer carries the canonical ICE notice.
    try std.testing.expect(std.mem.find(u8, output, "ZIR lowering failed: OutOfMemory") != null);
    try std.testing.expect(std.mem.find(u8, output, "internal compiler error") != null);
    try std.testing.expect(std.mem.find(u8, output, "zir_api.update") != null);
    try std.testing.expect(std.mem.find(u8, output, "please report") != null);
}

test "macro-expansion backtrace renders the expansion chain as frame lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var engine = DiagnosticEngine.init(alloc);
    defer engine.deinit();
    engine.setSource("pub fn run() {\n  unless cond { go() }\n}\n", "m.zap");

    // Interned macro name id is opaque to the renderer; it resolves names via
    // the engine's interner. Build a one-level expansion frame.
    var interner = ast.StringInterner.init(alloc);
    defer interner.deinit();
    const unless_id = try interner.intern("unless");
    engine.setInterner(&interner);

    const frame = ast.ExpansionInfo{
        .call_site = .{ .start = 17, .end = 23, .line = 2, .col = 3 },
        .macro_name = unless_id,
    };

    try engine.reportDiagnostic(.{
        .severity = .@"error",
        .domain = .typecheck,
        .message = "undefined function `go/0`",
        .span = .{ .start = 30, .end = 34, .line = 2, .col = 16 },
        .expansion = &frame,
    });

    const output = try engine.format(alloc);
    try std.testing.expect(std.mem.find(u8, output, "in expansion of macro `unless`") != null);
    try std.testing.expect(std.mem.find(u8, output, "m.zap:2:3") != null);
}
