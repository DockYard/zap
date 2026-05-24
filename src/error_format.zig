//! Phase 4.a — the shared visual-format specification.
//!
//! The brief mandates ONE visual language across every diagnostic surface
//! (compile errors, runtime panics, ERT traces, leak reports). But two of
//! those surfaces run under fundamentally different constraints:
//!
//!   * the **compile-time renderer** (`diagnostics.DiagnosticEngine`) runs in
//!     a normal context and may allocate freely; and
//!   * the **runtime crash printer** (`runtime.zig`) runs from an
//!     async-signal context after a hardware fault and MUST NOT allocate,
//!     lock, or call anything async-signal-unsafe (brief VI.B #5).
//!
//! Sharing one *renderer* across that boundary is impossible — the signal
//! path cannot depend on an allocating `ArrayList`. What they CAN and MUST
//! share is the **format spec**: the exact byte sequences that define the
//! visual language. This module is that single source of truth — the header
//! sigil, the frame prefix, the ` at ` source separator, the box-drawing
//! glyphs, and the SGR color escapes — referenced by BOTH paths so they can
//! never visually drift.
//!
//! The allocating renderer composes these constants into an `ArrayList`; the
//! signal-safe printer writes the SAME constants via `write(2)` (`posixWrite`).
//! Neither owns the strings. A change to the visual language is a one-line
//! edit here that both surfaces pick up — that is the mechanism by which a
//! crash report and a compile error look like the same tool.
//!
//! ## Severity-keyed crash kinds
//!
//! A runtime crash has a *kind* (`runtime_error`, `match_error`, …) rather
//! than a compile `Severity`; it always renders at error intensity. The
//! header sigil and color are therefore fixed (error red) on the crash path,
//! whereas the compile path varies color by severity. The constants below
//! cover both: `header_sigil_open`/`header_sigil_close` wrap the kind, and the
//! color table is the single SGR vocabulary the colored renderer draws from.

const std = @import("std");

/// The crash-report header sigil. A runtime crash renders as
/// `** (<kind>) <message>` — the `** (` opener, the kind, the `) ` closer,
/// then the message. This is the Elixir/BEAM `** (Error)` convention the
/// Phase 2 printer adopted; keeping it here lets the compile renderer reuse
/// the identical sigil when it renders a *runtime-domain* report (so a panic
/// shown at compile-explain time and a panic shown at crash time match
/// byte-for-byte).
pub const header_sigil_open = "** (";
pub const header_sigil_close = ") ";

/// The per-frame indent for a backtrace / ERT line: two spaces before the
/// symbol. Shared so a runtime backtrace frame and any compile-time frame
/// list (macro-expansion backtrace in 4.b, ERT chain) indent identically.
pub const frame_indent = "  ";

/// The ` at ` separator between a frame's symbol and its `file:line` source
/// location (`  Struct.fn/1 at file.zap:7`).
pub const frame_source_separator = " at ";

/// The `:` between file and line in a source location.
pub const source_line_separator = ":";

/// The trailing marker on a backtrace frame that was produced by DWARF
/// inline-frame expansion rather than a distinct physical return address
/// (`  Struct.fn/1 at file.zap:7 (inlined)`). The leak alloc-site backtrace
/// expands a fully-inlined leaf allocation's single PC into its inline chain;
/// this marks the inlined source frames so they read distinctly from the
/// physical frame, the conventional way DWARF inline frames are rendered.
pub const inlined_frame_suffix = " (inlined)";

/// Box-drawing glyphs for the gutter / footer. U+2502 BOX DRAWINGS LIGHT
/// VERTICAL is the gutter bar; U+2514 U+2500 (└─) is the footer corner that
/// introduces the `file:line:col` location line. Shared so the compile
/// renderer's gutter and any future runtime structured frame use one glyph
/// set.
pub const gutter_bar = "\u{2502}";
pub const footer_corner = "\u{2514}\u{2500}";

/// The caret and tilde underline glyphs (primary `^`, secondary `~`).
pub const caret_primary: u8 = '^';
pub const caret_secondary: u8 = '~';

/// The label that introduces the error-return-trace section in a crash
/// report — the c→b→a propagation chain that Phase 4.a's ERT display surfaces.
/// Distinct from the backtrace so the reader can tell "where it was raised and
/// how it propagated" (ERT) from "the call stack at the abort" (backtrace).
pub const ert_section_header = "error return trace:";

/// The line that introduces a wrapped underlying cause in the `cause_chain`.
pub const cause_prefix = "caused by: ";

/// SGR (Select Graphic Rendition) escape vocabulary — the SINGLE color
/// palette both renderers draw from. The compile renderer already used these
/// literals inline; centralizing them here means the runtime crash printer can
/// emit the IDENTICAL bytes for a colored header without re-declaring escapes,
/// and a future palette change is one edit.
pub const sgr = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const red = "\x1b[31m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";
    pub const bold_red = "\x1b[1;31m";
    pub const bold_yellow = "\x1b[1;33m";
    pub const bold_cyan = "\x1b[1;36m";
    pub const bold_blue = "\x1b[1;34m";
};

/// The diagnostic security tier (brief VI.B #9). Determines how much detail a
/// rendered diagnostic may expose. Cached at startup on the runtime path
/// (resolving it touches the environment / build mode, which is not
/// async-signal-safe) and consulted by both renderers.
///
/// The three tiers map onto the brief's dev-local / CI-internal / user-safe:
///
///   * `dev_local`   — full detail: absolute paths, internal-visibility notes,
///     full traces. The developer is on their own machine.
///   * `ci_internal` — paths kept (CI logs are internal) but the build is a
///     release-style build; reserved so CI can opt into more than a shipped
///     binary without leaking to an end user.
///   * `user_safe`   — a shipped release binary in front of an end user: strip
///     absolute paths to basename, never emit heap contents, prefer
///     ASLR-relative offsets when symbolication is unavailable, and suppress
///     internal-visibility detail beyond a stable code.
pub const SecurityTier = enum {
    dev_local,
    ci_internal,
    user_safe,

    /// True when absolute filesystem paths must be reduced to their basename.
    /// Only the user-facing tier strips; dev and CI keep full paths for
    /// navigability.
    pub fn stripsAbsolutePaths(self: SecurityTier) bool {
        return self == .user_safe;
    }

    /// True when internal-visibility detail (compiler-internal notes, private
    /// type names) must be suppressed in favor of a stable code only. Only the
    /// user-facing tier suppresses.
    pub fn suppressesInternalDetail(self: SecurityTier) bool {
        return self == .user_safe;
    }

    /// Stable lowercase wire name (JSON `security_tier`).
    pub fn wireName(self: SecurityTier) []const u8 {
        return @tagName(self);
    }
};

/// Resolve the default security tier from the Zig build mode. Debug /
/// ReleaseSafe are developer-facing (`dev_local`); ReleaseFast / ReleaseSmall
/// are shipped binaries (`user_safe`). The `ci_internal` tier is opt-in (a
/// future `--diagnostic-tier=ci` / env override) and never the default, so a
/// shipped binary defaults to the safest tier. This is a comptime fold of the
/// build mode — the same policy `runtime.crash_report_strip_paths` encoded,
/// now expressed once as a tier both surfaces share.
pub fn defaultTierForMode(mode: std.builtin.OptimizeMode) SecurityTier {
    return switch (mode) {
        .Debug, .ReleaseSafe => .dev_local,
        .ReleaseFast, .ReleaseSmall => .user_safe,
    };
}

/// Return the basename of `path` (segment after the last `/`). The
/// path-stripping primitive both renderers use under `user_safe`. No
/// allocation — returns a sub-slice — so it is usable on the signal path.
pub fn pathBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[idx + 1 ..];
    return path;
}

/// Apply the tier's path policy to a file path: basename under `user_safe`,
/// unchanged otherwise. The single chokepoint both renderers route file paths
/// through, so the security policy can never be applied inconsistently.
pub fn applyPathPolicy(tier: SecurityTier, path: []const u8) []const u8 {
    return if (tier.stripsAbsolutePaths()) pathBasename(path) else path;
}

test "SecurityTier path/detail policy" {
    try std.testing.expect(!SecurityTier.dev_local.stripsAbsolutePaths());
    try std.testing.expect(!SecurityTier.ci_internal.stripsAbsolutePaths());
    try std.testing.expect(SecurityTier.user_safe.stripsAbsolutePaths());

    try std.testing.expect(!SecurityTier.dev_local.suppressesInternalDetail());
    try std.testing.expect(SecurityTier.user_safe.suppressesInternalDetail());
}

test "defaultTierForMode folds build mode to a tier" {
    try std.testing.expectEqual(SecurityTier.dev_local, defaultTierForMode(.Debug));
    try std.testing.expectEqual(SecurityTier.dev_local, defaultTierForMode(.ReleaseSafe));
    try std.testing.expectEqual(SecurityTier.user_safe, defaultTierForMode(.ReleaseFast));
    try std.testing.expectEqual(SecurityTier.user_safe, defaultTierForMode(.ReleaseSmall));
}

test "applyPathPolicy strips only under user_safe" {
    const p = "/Users/dev/project/src/main.zap";
    try std.testing.expectEqualStrings(p, applyPathPolicy(.dev_local, p));
    try std.testing.expectEqualStrings(p, applyPathPolicy(.ci_internal, p));
    try std.testing.expectEqualStrings("main.zap", applyPathPolicy(.user_safe, p));
}

test "pathBasename" {
    try std.testing.expectEqualStrings("main.zap", pathBasename("/a/b/main.zap"));
    try std.testing.expectEqualStrings("main.zap", pathBasename("main.zap"));
    try std.testing.expectEqualStrings("", pathBasename("/a/b/"));
}

test "shared format constants are the expected bytes" {
    try std.testing.expectEqualStrings("** (", header_sigil_open);
    try std.testing.expectEqualStrings(") ", header_sigil_close);
    try std.testing.expectEqualStrings("  ", frame_indent);
    try std.testing.expectEqualStrings(" at ", frame_source_separator);
    try std.testing.expectEqualStrings("\u{2502}", gutter_bar);
    try std.testing.expectEqualStrings("\u{2514}\u{2500}", footer_corner);
}
