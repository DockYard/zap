//! Capability-not-OS-name audit (the Phase-4 lock-in for the language-level
//! target-capability model — `docs/target-capability-model-plan.md`).
//!
//! THE central principle of the whole campaign is: **a target gate names a
//! CAPABILITY, never an OS** (`@available_on(:processes)`, never
//! `@available_on(:wasi)`). A capability is portable — a new target gains it
//! automatically from its `std.Target` facts — whereas an OS name bakes a
//! per-OS assumption into the language surface, the exact bug this campaign
//! exists to kill. This audit ENFORCES that principle as standing CI, the
//! direct analog of `src/runtime_os_portability_gate.zig` (which confines raw
//! per-OS syscalls to the runtime_os seam).
//!
//! ## What it guards
//!
//!   1. **Every `@available_on(:atom, …)` in the stdlib (`lib/**/*.zap`) names
//!      a known CAPABILITY.** The set of known capabilities is read straight
//!      from `target_caps.capabilityFromAtomName` — the SAME single source of
//!      truth the compiler's gate consults — so the audit can never drift from
//!      the real vocabulary. An OS name (`:wasi`/`:windows`/`:linux`/`:macos`/
//!      `:darwin`/…) or a typo (`:terminl`) is NOT a capability, so it FAILS
//!      the audit with a precise `lib/<file>.zap:<line>` message. OS names get
//!      a sharper "that is an OS name, not a capability" diagnostic.
//!
//!   2. **The compiler's gate-DECISION path keys off the capability bitset,
//!      never an OS-name comparison.** `src/ctfe.zig`'s `gateAvailableOn`
//!      family decides availability solely via
//!      `TargetCapabilitySet.firstMissingFrom` (a bitset op). This audit scans
//!      that decision region and FAILS if an OS-name atom string literal
//!      (`"wasi"`, `"windows"`, …) appears there — OS names belong ONLY in
//!      `src/target_caps.zig`'s capability-DERIVATION layer (where reading
//!      `std.Target` os/arch facts to compute the bitset is correct and
//!      necessary), never in the gate decision itself.
//!
//! ## Why a standing scan and not just the per-compile check
//!
//! The compiler already rejects an unknown `@available_on` atom — but only
//! when that stdlib file is actually compiled for some target on some build.
//! A planted `@available_on(:wasi)` on a declaration that no test happens to
//! reference for a gating target could sit latent. This audit proactively
//! scans the ENTIRE stdlib tree on every `zig build test`, so an OS-name gate
//! is caught the instant it lands, centrally, with a precise message — making
//! capability-not-name ENFORCED architecture, not a convention.
//!
//! ## Zero manual maintenance
//!
//! The stdlib file set is enumerated from the source tree by `build.zig` and
//! embedded via a generated manifest (`stdlib_sources`), so a NEW `lib/*.zap`
//! is scanned automatically — there is no hand-maintained file list to forget
//! to update (which would silently create an audit hole).

const std = @import("std");
const target_caps = @import("target_caps.zig");

/// The generated manifest of every `lib/**/*.zap` stdlib source, enumerated at
/// build time by `build.zig` and embedded here. Each entry is the original
/// repo-relative path (for diagnostics) plus the file's full source bytes.
/// Generated, never hand-edited — a new stdlib file appears automatically.
const stdlib_sources = @import("stdlib_sources");

/// The gate-DECISION source region this audit scans for forbidden OS-name
/// literals. `src/ctfe.zig` holds `gateAvailableOn` and its helpers — the code
/// that decides, per declaration, whether the target satisfies the
/// `@available_on` requirement. That decision must be a pure bitset op; an OS
/// name appearing here would mean the gate smuggled OS-name branching where a
/// capability belongs.
const gate_decision_source = @embedFile("ctfe.zig");

/// OS-name atoms that must never appear in an `@available_on` gate nor in the
/// gate-decision region. These are `std.Target.Os.Tag` names (the spellings an
/// author might reach for instead of a capability). The list is the union of
/// the OS tags the campaign targets plus the common ones a mistake would use.
/// Membership here drives the sharper "that is an OS name" diagnostic; any
/// OTHER non-capability atom is still rejected as an unknown capability.
const os_name_atoms = [_][]const u8{
    "wasi",
    "windows",
    "linux",
    "macos",
    "darwin",
    "freestanding",
    "freebsd",
    "openbsd",
    "netbsd",
    "dragonfly",
    "ios",
    "tvos",
    "watchos",
    "wasm",
    "emscripten",
    "uefi",
    "haiku",
    "solaris",
    "fuchsia",
    "amdhsa",
    "ps4",
    "ps5",
    "elfiamcu",
    "other",
    "opencl",
    "vulkan",
};

/// True iff `name` is one of the known OS-name atoms.
fn isOsNameAtom(name: []const u8) bool {
    for (os_name_atoms) |os_name| {
        if (std.mem.eql(u8, name, os_name)) return true;
    }
    return false;
}

/// A `@available_on` capability-vocabulary violation in a stdlib file.
pub const Violation = struct {
    /// Repo-relative source path (e.g. `lib/io.zap`).
    file_path: []const u8,
    /// 1-based line of the offending `@available_on` attribute.
    line_number: usize,
    /// The offending atom name (without the leading `:`).
    atom: []const u8,
    /// Whether the atom is a recognized OS name (drives the sharper message).
    is_os_name: bool,
};

// ---------------------------------------------------------------------------
// Heredoc/comment-aware `@available_on` extraction
// ---------------------------------------------------------------------------
//
// A real `@available_on(:cap, …)` attribute occurs in CODE position: a line
// whose trimmed start is `@available_on(`. The string `@available_on` also
// appears in `@doc` heredocs (prose: "Available only on targets…", "like
// `@available_on`…") and could appear in comments; those are NOT attributes
// and must be ignored. The scanner therefore tracks `"""` heredoc state and
// strips `#` line comments, matching the attribute ONLY in code, only when it
// opens the (trimmed) line.

/// The attribute spelling, including the opening paren, as it appears at the
/// start of a trimmed code line for a real attribute declaration.
const attribute_open = "@available_on(";

/// Scan one stdlib source for `@available_on` attributes whose atom arguments
/// are not known capabilities. Appends each to `violations`. Heredoc- and
/// comment-aware so prose/`#`-comment mentions of `@available_on` are ignored.
fn scanStdlibSource(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    var in_heredoc = false;
    var line_number: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        line_number += 1;

        // Heredoc tracking: a line containing `"""` toggles heredoc state once
        // per occurrence. Zap heredocs open and close with `"""`; an open and
        // close on the SAME line (rare) nets to no state change, which the
        // per-occurrence toggle below handles correctly.
        const triple_quote_count = std.mem.count(u8, raw_line, "\"\"\"");
        const heredoc_was_open = in_heredoc;
        if (triple_quote_count % 2 == 1) in_heredoc = !in_heredoc;

        // A line that is inside a heredoc (either it was already open, or it is
        // the closing `"""` line) carries prose, never an attribute. Skip it.
        if (heredoc_was_open) continue;

        // Outside a heredoc: strip a `#` line comment (Zap comment syntax),
        // then look for the attribute at code-position (trimmed line start).
        const code = stripLineComment(raw_line);
        const trimmed = std.mem.trimStart(u8, code, " \t");
        if (!std.mem.startsWith(u8, trimmed, attribute_open)) continue;

        // Real `@available_on(...)` attribute — extract its atom arguments.
        try extractAtomViolations(allocator, file_path, line_number, trimmed, violations);
    }
}

/// Strip a `#` line comment from a Zap source line, returning the code portion.
/// Quote-aware: a `#` inside a string/char literal or interpolation is not a
/// comment introducer. (Zap uses `#` for line comments and `#{…}` for
/// interpolation inside strings; an attribute line carries neither, but the
/// quote tracking keeps the scanner correct regardless.)
fn stripLineComment(line: []const u8) []const u8 {
    var i: usize = 0;
    var in_string = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '#' => return line[0..i],
            else => {},
        }
    }
    return line;
}

/// Extract every `:atom` argument inside the `@available_on(...)` call on
/// `trimmed` (a trimmed code line that starts with `@available_on(`) and
/// append a `Violation` for each atom that is not a known capability.
fn extractAtomViolations(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    line_number: usize,
    trimmed: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    // The argument list is between the first '(' and its matching ')'.
    const open_paren = std.mem.indexOfScalar(u8, trimmed, '(') orelse return;
    const close_paren = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse trimmed.len;
    if (close_paren <= open_paren) return;
    const args = trimmed[open_paren + 1 .. close_paren];

    // Each argument is a `:name` atom; split on ',' and parse each.
    var arg_it = std.mem.splitScalar(u8, args, ',');
    while (arg_it.next()) |raw_arg| {
        const arg = std.mem.trim(u8, raw_arg, " \t");
        if (arg.len == 0) continue;
        if (arg[0] != ':') continue; // not an atom literal; the compiler's
        // own `@available_on` parser reports non-atom forms — the audit only
        // judges atom NAMES against the capability vocabulary.
        const atom = arg[1..];
        if (atom.len == 0) continue;
        // The single source of truth: a known capability passes; anything else
        // (OS name or typo) is a violation.
        if (target_caps.capabilityFromAtomName(atom) != null) continue;
        try violations.append(allocator, .{
            .file_path = file_path,
            .line_number = line_number,
            .atom = atom,
            .is_os_name = isOsNameAtom(atom),
        });
    }
}

/// Scan the whole embedded stdlib manifest and return every capability-
/// vocabulary violation. Caller owns the returned slice.
fn scanAllStdlib(allocator: std.mem.Allocator) ![]Violation {
    var violations: std.ArrayList(Violation) = .empty;
    errdefer violations.deinit(allocator);
    for (stdlib_sources.files) |file| {
        try scanStdlibSource(allocator, file.path, file.source, &violations);
    }
    return violations.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Gate-decision OS-name-smuggling scan
// ---------------------------------------------------------------------------
//
// The decision region is delimited in `src/ctfe.zig` by sentinel comments
// `// ZAP_TARGET_GATE_DECISION_BEGIN` / `…_END`, wrapping `gateAvailableOn` and
// its helpers. Inside it, an OS-name atom string literal (`"wasi"`, …) would
// mean the gate decided availability by OS name rather than by capability bit.

const gate_region_begin = "// ZAP_TARGET_GATE_DECISION_BEGIN";
const gate_region_end = "// ZAP_TARGET_GATE_DECISION_END";

/// A forbidden OS-name string literal found inside the gate-decision region.
pub const GateSmuggle = struct {
    line_number: usize,
    os_name: []const u8,
    line_text: []const u8,
};

/// Scan `source` (ctfe.zig) between the gate-decision sentinels and return any
/// OS-name string literal found there. Comment lines are ignored (a comment
/// naming an OS for explanation is documentation, not a decision). Caller owns
/// the returned slice. Also returns whether the region was actually found, so
/// a renamed/removed sentinel cannot vacuously "pass".
const GateScanResult = struct {
    smuggles: []GateSmuggle,
    region_seen: bool,
};

fn scanGateDecision(allocator: std.mem.Allocator, source: []const u8) !GateScanResult {
    var smuggles: std.ArrayList(GateSmuggle) = .empty;
    errdefer smuggles.deinit(allocator);

    var region_seen = false;
    var in_region = false;
    var line_number: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |raw_line| {
        line_number += 1;
        const trimmed = std.mem.trimStart(u8, raw_line, " \t");
        if (!in_region) {
            if (std.mem.startsWith(u8, trimmed, gate_region_begin)) {
                in_region = true;
                region_seen = true;
            }
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, gate_region_end)) {
            in_region = false;
            continue;
        }
        // Inside the region. Ignore comment lines (documentation, not code).
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        // Look for any OS-name as a double-quoted string literal token. We
        // match the quoted form `"wasi"` specifically: that is how an os-name
        // comparison would be written (`std.mem.eql(u8, name, "wasi")`),
        // whereas a capability atom name like `"processes"` is allowed.
        for (os_name_atoms) |os_name| {
            const quoted_len = os_name.len + 2;
            var buf: [40]u8 = undefined;
            std.debug.assert(quoted_len <= buf.len);
            buf[0] = '"';
            @memcpy(buf[1 .. 1 + os_name.len], os_name);
            buf[1 + os_name.len] = '"';
            const needle = buf[0..quoted_len];
            if (std.mem.indexOf(u8, raw_line, needle) != null) {
                try smuggles.append(allocator, .{
                    .line_number = line_number,
                    .os_name = os_name,
                    .line_text = std.mem.trim(u8, raw_line, " \t\r"),
                });
            }
        }
    }
    return .{ .smuggles = try smuggles.toOwnedSlice(allocator), .region_seen = region_seen };
}

// ---------------------------------------------------------------------------
// The CI tests (run in the normal `zig build test` gate)
// ---------------------------------------------------------------------------

test "stdlib @available_on gates name capabilities, never OS names (lib/**/*.zap audit)" {
    const allocator = std.testing.allocator;
    const violations = try scanAllStdlib(allocator);
    defer allocator.free(violations);

    if (violations.len != 0) {
        std.debug.print(
            \\
            \\========================================================================
            \\target-capability audit FAILED: {d} `@available_on` gate(s) in the Zap
            \\stdlib (lib/**/*.zap) name something that is NOT a capability.
            \\
            \\THE central principle of the target-capability model: a gate names a
            \\CAPABILITY (:filesystem, :processes, :signals, :network, :threads,
            \\:terminal, :backtrace), NEVER an OS name. A capability is portable — a
            \\new target gains it automatically from its std.Target facts — whereas
            \\an OS name bakes a per-OS assumption into the language surface.
            \\------------------------------------------------------------------------
            \\
        , .{violations.len});
        for (violations) |v| {
            if (v.is_os_name) {
                std.debug.print(
                    "  {s}:{d}: `@available_on(:{s})` names an OS, not a capability.\n" ++
                        "    Gate on the CAPABILITY the OS provides instead — e.g. `:processes`,\n" ++
                        "    `:signals`, `:terminal`. A new target then gains the gate automatically.\n",
                    .{ v.file_path, v.line_number, v.atom },
                );
            } else {
                std.debug.print(
                    "  {s}:{d}: `@available_on(:{s})` is not a known capability (typo?).\n" ++
                        "    Valid capabilities: :filesystem, :processes, :signals, :network,\n" ++
                        "    :threads, :terminal, :backtrace.\n",
                    .{ v.file_path, v.line_number, v.atom },
                );
            }
        }
        std.debug.print(
            \\========================================================================
            \\
        , .{});
        return error.AvailableOnNamesNonCapability;
    }

    // Sanity: the audit MUST have scanned a non-empty stdlib set, and that set
    // MUST include the known-gated file (lib/io.zap), or a build-wiring change
    // silently emptied the manifest and a "PASS" would be vacuous.
    try std.testing.expect(stdlib_sources.files.len > 0);
    var saw_io = false;
    for (stdlib_sources.files) |file| {
        if (std.mem.endsWith(u8, file.path, "io.zap")) saw_io = true;
    }
    try std.testing.expect(saw_io);
}

test "compiler gate-decision region (ctfe.zig) contains no OS-name string literal" {
    const allocator = std.testing.allocator;
    const result = try scanGateDecision(allocator, gate_decision_source);
    defer allocator.free(result.smuggles);

    // The sentinel-delimited region must exist, or the scan is vacuous.
    try std.testing.expect(result.region_seen);

    if (result.smuggles.len != 0) {
        std.debug.print(
            \\
            \\========================================================================
            \\target-capability audit FAILED: {d} OS-name string literal(s) found in
            \\the gate-DECISION region of src/ctfe.zig (between
            \\`// ZAP_TARGET_GATE_DECISION_BEGIN`/`END`).
            \\
            \\The gate must decide availability from the capability BITSET
            \\(`TargetCapabilitySet.firstMissingFrom`), never by comparing an OS name.
            \\OS-name facts belong ONLY in src/target_caps.zig's capability-derivation
            \\layer (where reading std.Target os/arch to compute the bitset is correct).
            \\------------------------------------------------------------------------
            \\
        , .{result.smuggles.len});
        for (result.smuggles) |s| {
            std.debug.print("  src/ctfe.zig:{d}: OS-name `\"{s}\"` in the gate decision\n    {s}\n", .{
                s.line_number, s.os_name, s.line_text,
            });
        }
        std.debug.print(
            \\========================================================================
            \\
        , .{});
        return error.OsNameInGateDecision;
    }
}

// --- Self-tests: prove the scanners actually fire (planted fixtures) --------

test "scanner FLAGS an OS-name @available_on and PASSES a capability one" {
    const allocator = std.testing.allocator;

    // A capability gate passes clean.
    {
        var violations: std.ArrayList(Violation) = .empty;
        defer violations.deinit(allocator);
        const ok_source =
            \\pub struct System {
            \\  @available_on(:processes)
            \\  pub fn spawn() -> i64 { 0 }
            \\}
        ;
        try scanStdlibSource(allocator, "lib/fake.zap", ok_source, &violations);
        try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    }

    // An OS-name gate is flagged, with is_os_name set and the right line.
    {
        var violations: std.ArrayList(Violation) = .empty;
        defer violations.deinit(allocator);
        const bad_source =
            \\pub struct System {
            \\  @available_on(:wasi)
            \\  pub fn spawn() -> i64 { 0 }
            \\}
        ;
        try scanStdlibSource(allocator, "lib/fake.zap", bad_source, &violations);
        try std.testing.expectEqual(@as(usize, 1), violations.items.len);
        try std.testing.expectEqualStrings("wasi", violations.items[0].atom);
        try std.testing.expectEqual(@as(usize, 2), violations.items[0].line_number);
        try std.testing.expect(violations.items[0].is_os_name);
    }

    // A typo'd capability is flagged as a non-OS unknown.
    {
        var violations: std.ArrayList(Violation) = .empty;
        defer violations.deinit(allocator);
        const typo_source =
            \\  @available_on(:termnal)
        ;
        try scanStdlibSource(allocator, "lib/fake.zap", typo_source, &violations);
        try std.testing.expectEqual(@as(usize, 1), violations.items.len);
        try std.testing.expectEqualStrings("termnal", violations.items[0].atom);
        try std.testing.expect(!violations.items[0].is_os_name);
    }
}

test "scanner IGNORES @available_on mentioned in a doc heredoc or comment" {
    const allocator = std.testing.allocator;
    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(allocator);

    // The string `@available_on(:wasi)` appears INSIDE a `@doc` heredoc (prose)
    // and in a `#` comment — neither is a real attribute, so neither is a
    // violation. Only the real `@available_on(:terminal)` attribute is scanned
    // (and it is a valid capability), so zero violations.
    const source =
        \\pub struct IO {
        \\  @doc = """
        \\    Gate it with @available_on(:wasi) — NO, that names an OS; this prose
        \\    only explains the concept and must be ignored by the audit.
        \\    """
        \\  # historical note: once tried @available_on(:windows) here
        \\  @available_on(:terminal)
        \\  pub fn get_char() -> String { "" }
        \\}
    ;
    try scanStdlibSource(allocator, "lib/io.zap", source, &violations);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

test "scanner handles multi-capability @available_on and flags only the bad atom" {
    const allocator = std.testing.allocator;
    var violations: std.ArrayList(Violation) = .empty;
    defer violations.deinit(allocator);
    // A multi-arg gate: :filesystem (valid) + :linux (OS name) — only :linux
    // is a violation, proving per-atom judgement inside one attribute.
    const source =
        \\  @available_on(:filesystem, :linux)
    ;
    try scanStdlibSource(allocator, "lib/fake.zap", source, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expectEqualStrings("linux", violations.items[0].atom);
    try std.testing.expect(violations.items[0].is_os_name);
}

test "gate-decision scanner flags a planted OS-name literal in the region" {
    const allocator = std.testing.allocator;
    const planted =
        \\fn before() void {}
        \\// ZAP_TARGET_GATE_DECISION_BEGIN
        \\fn gate(name: []const u8) bool {
        \\    return std.mem.eql(u8, name, "wasi"); // smuggled OS-name decision
        \\}
        \\// ZAP_TARGET_GATE_DECISION_END
        \\fn after() void {}
    ;
    const result = try scanGateDecision(allocator, planted);
    defer allocator.free(result.smuggles);
    try std.testing.expect(result.region_seen);
    try std.testing.expectEqual(@as(usize, 1), result.smuggles.len);
    try std.testing.expectEqualStrings("wasi", result.smuggles[0].os_name);
    try std.testing.expectEqual(@as(usize, 4), result.smuggles[0].line_number);
}

test "gate-decision scanner ignores OS names in comments and outside the region" {
    const allocator = std.testing.allocator;
    const source =
        \\fn outside() bool { return std.mem.eql(u8, x, "wasi"); }
        \\// ZAP_TARGET_GATE_DECISION_BEGIN
        \\fn gate() bool {
        \\    // this comment mentions "windows" for documentation only
        \\    return caps.firstMissingFrom(target) == null;
        \\}
        \\// ZAP_TARGET_GATE_DECISION_END
    ;
    const result = try scanGateDecision(allocator, source);
    defer allocator.free(result.smuggles);
    try std.testing.expect(result.region_seen);
    try std.testing.expectEqual(@as(usize, 0), result.smuggles.len);
}
