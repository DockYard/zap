//! Phase 4.a — the canonical Error IR.
//!
//! A SINGLE schema that every diagnostic surface lowers into: compile-time
//! errors (parse / typecheck / borrow), runtime panics, error-return traces,
//! and leak / cycle reports. The brief (Part IV §4) mandates one schema —
//!
//!   `domain, code, severity, message, primary_span, related_spans, notes,
//!    help, fixits, cause_chain, trace_policy, machine_data, visibility`
//!
//! — feeding the CLI text renderer, the `--error-format=json` output, and
//! (later) the LSP server. Consistency across surfaces *is* the production
//! feeling and the tooling-integration story; the schema is a deliberate
//! projection of the LSP `Diagnostic` shape plus rustc-style
//! `code`/`rendered`/`MachineApplicable` fields, not a parallel invention.
//!
//! ## Why a dedicated module (not just `diagnostics.Diagnostic`)
//!
//! `diagnostics.Diagnostic` is the *compile-time* shape the frontend has
//! always produced (severity + span + notes + secondary spans + suggestion).
//! The canonical IR is its superset: it adds the cross-surface fields a
//! runtime panic, an ERT chain, and a leak report need (`domain`,
//! `trace_policy`, `cause_chain`, `machine_data`, `visibility`, and
//! applicability-tagged `fixits`). Keeping the canonical enums and the
//! `Report` projection here — separate from the renderer — lets the JSON
//! serializer, the runtime crash printer's shared format spec, and the
//! frontend all depend on one vocabulary without a circular import through
//! the renderer.
//!
//! The frontend continues to *construct* `diagnostics.Diagnostic` values
//! (its ergonomic, span-centric shape); `Report.fromDiagnostic` lifts one
//! into the canonical IR for JSON / LSP projection, and the renderer reads
//! the shared enums (`Domain`, `Severity`) directly. Nothing is duplicated:
//! `diagnostics.Diagnostic` gains the new optional fields and *is* the
//! in-memory canonical record for the compile path; this module owns the
//! enums + the JSON-facing `Report` view + the cross-surface helpers.

const std = @import("std");
const ast = @import("ast.zig");

/// The diagnostic *domain* — which subsystem produced the report. Drives
/// JSON's `domain` field and lets a consumer (LSP / CI / `zap fix`) route or
/// filter by category. The renderer does not change its visual language per
/// domain (one visual language across all surfaces, per the brief); the
/// domain is metadata, surfaced in JSON and available for future grouping.
///
/// Phase 4.a populates `parse`, `typecheck`, `runtime`, `panic`, and the
/// abort-kind domains; 4.b adds `ice`; 4.c adds `leak`; 4.d adds `cycle`.
/// All variants exist now so the later phases only *populate* them — they do
/// not extend the schema (the brief's "support them" requirement for 4.b/4.c).
pub const Domain = enum {
    /// Lexer / parser syntax errors.
    parse,
    /// Name resolution / scope errors.
    name,
    /// Type-system / inference / contract errors.
    typecheck,
    /// Borrow / ownership / uniqueness errors.
    borrow,
    /// Effect-row / `raises` discharge errors (unhandled error effect).
    effect,
    /// A recoverable-model runtime abort surfaced as a crash (a `raise`
    /// that reached the top with no `rescue`).
    runtime,
    /// A language-level panic (safety check, `unreachable`, explicit panic).
    panic,
    /// Out-of-memory / allocation failure.
    oom,
    /// A memory leak report (Phase 4.c populates).
    leak,
    /// An ARC reference cycle report (Phase 4.d populates).
    cycle,
    /// Foreign-function-interface / `:zig.` boundary error.
    ffi,
    /// I/O failure surfaced as a diagnostic.
    io,
    /// Internal compiler error (Phase 4.b populates).
    ice,

    /// Stable lowercase wire name used in JSON's `domain` field. Stable
    /// public API: consumers key off these, so they are never renamed.
    pub fn wireName(self: Domain) []const u8 {
        return @tagName(self);
    }
};

/// rustc's suggestion-applicability taxonomy (brief Part V). Controls whether
/// a tool may apply a fix automatically. Projected into JSON as
/// `suggestions[].applicability`; LSP maps `machine_applicable` fixits to
/// auto-applicable `CodeAction`s and the rest to manual ones.
pub const Applicability = enum {
    /// The fix is definitely correct and complete — a tool may apply it
    /// without human review (LSP auto-fix, `zap fix`).
    machine_applicable,
    /// The fix is a reasonable guess but may be wrong; present it, do not
    /// auto-apply.
    maybe_incorrect,
    /// The fix contains placeholders the human must fill in (e.g. a `todo!`
    /// stub) — never auto-apply.
    has_placeholders,
    /// Applicability is unknown.
    unspecified,

    /// Stable lowercase wire name for JSON.
    pub fn wireName(self: Applicability) []const u8 {
        return @tagName(self);
    }
};

/// How much trace context this report carries — the brief's `trace_policy`.
/// A compile error has `none`; a recoverable cross-function raise carries the
/// `lightweight` error-return trace (the c→b→a propagation chain); a hard
/// panic / signal fault carries a `full` unwound backtrace; a leak report
/// carries the `allocation` trace (where the leaked object was born).
pub const TracePolicy = enum {
    /// No trace (compile-time diagnostics).
    none,
    /// A lightweight error-return trace: the chain of `return`-propagation
    /// frames between the `raise` site and the abort terminus (Phase 3.b /
    /// the ERT display this phase closes).
    lightweight,
    /// A full stack unwind from the faulting instruction (hard panic / signal).
    full,
    /// An allocation-site trace (where a leaked object was allocated — Phase
    /// 4.c).
    allocation,

    pub fn wireName(self: TracePolicy) []const u8 {
        return @tagName(self);
    }
};

/// Public-vs-internal surface of the diagnostic — the brief's `visibility`,
/// reusing Zap's `pub` convention (item 10 / the `pub error` mechanism). A
/// `public` diagnostic refers to API surface a user can `rescue`/match; an
/// `internal` one refers to private/compiler-internal detail. The security
/// tiers (VI.B #9) consult this together with the build tier: a release build
/// must never leak `internal` detail beyond a stable code.
pub const Visibility = enum {
    /// Refers to public API surface (a `pub error`, a user-facing type).
    public,
    /// Refers to private or compiler-internal detail.
    internal,

    pub fn wireName(self: Visibility) []const u8 {
        return @tagName(self);
    }
};

/// One labeled secondary location — the brief's `related_spans`, a direct
/// projection of LSP `DiagnosticRelatedInformation` (`{ location, message }`).
/// 4.b's two-sided `TypeProvenance` populates pairs of these ("expected i64
/// from here", "got String from this literal").
pub const RelatedSpan = struct {
    span: ast.SourceSpan,
    message: []const u8,
};

/// A machine-applicable code edit — the brief's `fixits`. Projected into JSON
/// as a rustc `suggestion` (`{ span, replacement, applicability }`) and into
/// LSP as a `CodeAction`/`WorkspaceEdit`. The `span` is the range to replace;
/// `replacement` is the new text; `applicability` gates auto-application.
pub const FixIt = struct {
    span: ast.SourceSpan,
    replacement: []const u8,
    /// Human-facing description of the fix (the `= help:` line / CodeAction
    /// title).
    description: []const u8,
    applicability: Applicability = .unspecified,
};

/// One link in the `cause_chain` — a wrapped/underlying cause, mirroring the
/// `Error` protocol's `cause` field and Elixir/Go error wrapping. Rendered as
/// a `caused by:` line; projected into JSON as a `cause_chain[]` entry. Each
/// link carries its own code/message and an optional originating span.
pub const Cause = struct {
    /// Stable `Zxxxx` code of the underlying error, when it has one.
    code: ?[]const u8 = null,
    /// Human-facing message of the underlying cause.
    message: []const u8,
    /// Where the underlying cause originated, when known.
    span: ?ast.SourceSpan = null,
};

/// One key/value pair of `machine_data` — structured, machine-only payload
/// that never appears in the human-rendered text but rides along in JSON for
/// tools (e.g. `expected_type`/`got_type` for a type error, `bytes`/`count`
/// for a leak). Keeping it out of the prose keeps the human report clean while
/// still giving CI/LSP structured access (the brief's `machine_data`).
pub const MachineDatum = struct {
    key: []const u8,
    value: []const u8,
};

/// The severity ladder. Kept in sync with `diagnostics.Severity` (the renderer
/// owns the canonical enum to avoid a cycle); this alias documents that the
/// canonical IR uses exactly that ladder. LSP maps these to its numeric
/// severities (error=1, warning=2, information=3, hint=4).
pub const Severity = @import("diagnostics.zig").Severity;

/// Map a `Severity` to the LSP numeric `DiagnosticSeverity` (1=Error,
/// 2=Warning, 3=Information, 4=Hint). Used by the JSON projection so the
/// output drops straight into an LSP `Diagnostic`.
pub fn lspSeverity(severity: Severity) u8 {
    return switch (severity) {
        .@"error" => 1,
        .warning => 2,
        .note => 3,
        .help => 4,
    };
}

test "Domain wire names are stable lowercase identifiers" {
    try std.testing.expectEqualStrings("parse", Domain.parse.wireName());
    try std.testing.expectEqualStrings("typecheck", Domain.typecheck.wireName());
    try std.testing.expectEqualStrings("leak", Domain.leak.wireName());
    try std.testing.expectEqualStrings("ice", Domain.ice.wireName());
    try std.testing.expectEqualStrings("cycle", Domain.cycle.wireName());
}

test "Applicability wire names match rustc taxonomy" {
    try std.testing.expectEqualStrings("machine_applicable", Applicability.machine_applicable.wireName());
    try std.testing.expectEqualStrings("maybe_incorrect", Applicability.maybe_incorrect.wireName());
    try std.testing.expectEqualStrings("has_placeholders", Applicability.has_placeholders.wireName());
    try std.testing.expectEqualStrings("unspecified", Applicability.unspecified.wireName());
}

test "TracePolicy and Visibility wire names" {
    try std.testing.expectEqualStrings("none", TracePolicy.none.wireName());
    try std.testing.expectEqualStrings("lightweight", TracePolicy.lightweight.wireName());
    try std.testing.expectEqualStrings("full", TracePolicy.full.wireName());
    try std.testing.expectEqualStrings("allocation", TracePolicy.allocation.wireName());
    try std.testing.expectEqualStrings("public", Visibility.public.wireName());
    try std.testing.expectEqualStrings("internal", Visibility.internal.wireName());
}

test "lspSeverity maps the severity ladder to LSP numbers" {
    try std.testing.expectEqual(@as(u8, 1), lspSeverity(.@"error"));
    try std.testing.expectEqual(@as(u8, 2), lspSeverity(.warning));
    try std.testing.expectEqual(@as(u8, 3), lspSeverity(.note));
    try std.testing.expectEqual(@as(u8, 4), lspSeverity(.help));
}
