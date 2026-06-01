//! The unified target-capability vocabulary (Phase 2 of the language-level
//! target-capability model — `docs/target-capability-model-plan.md`).
//!
//! A Zap declaration may be annotated `@available_on(:cap, …)` to say "this
//! declaration exists only on targets that have ALL listed capabilities."
//! On a target lacking a required capability, *referencing* the declaration
//! is a clean compile error (the `target_capability` diagnostic), not a
//! runtime trap. This module is the single source of truth that maps a
//! resolved compilation target (`target_triple.TargetAtoms`, i.e. the
//! `@target` `{os, arch, abi}` atoms) to the set of capabilities that target
//! supports.
//!
//! ## The central principle: capability-not-OS-name
//!
//! The gate keys off *capabilities* (`:processes`, `:signals`, …), never OS
//! names (`os == :wasi`). A new target gains a capability automatically when
//! its `std.Target` facts say it has it; no OS-name allowlist is ever edited.
//! This mirrors the memory model's `declared_caps` bitmask exactly: a bitset
//! the compiler reads by bit, and the diagnostic names the missing capability.
//!
//! ## One vocabulary, two derivation tiers (derived, never duplicated)
//!
//! The capability set is split into two tiers by where its ground truth lives:
//!
//!   * **Runtime-primitive caps** — `:signals`, `:terminal`, `:backtrace`.
//!     These are DEFINED AS the corresponding `runtime_os` backend `caps`
//!     booleans for the resolved target. There is no second source of truth:
//!     this module imports the three `runtime_os/{posix,windows,wasi}.zig`
//!     backend modules and reads their `Backend.caps.supports_signals` /
//!     `.supports_termios` literals, selecting which backend applies with the
//!     SAME `os.tag` switch the codegen seam uses
//!     (`compiler.zig`'s `buildRuntimeOsSeam`: `.windows`→windows,
//!     `.wasi`→wasi, else→posix). `:backtrace` is `std.debug.SelfInfo != void`
//!     evaluated for the *requested* target's object format (the exact
//!     condition the backends' `supports_backtrace` const encodes), computed
//!     here per-target because the backend const would otherwise reflect the
//!     compiler host.
//!
//!   * **Language-domain caps** — `:filesystem`, `:processes`, `:network`,
//!     `:threads`. These are derived from `std.Target` os/arch facts (process
//!     model, socket layer, thread model) — the same facts the fork's
//!     `std.Target` already encodes. For the three runtime targets the table
//!     in the plan is authoritative; a new target's row is computed from its
//!     `std.Target` os/arch.
//!
//! The single-sourcing is asserted by a test below: the runtime-primitive
//! atoms equal the `runtime_os` backend `caps` booleans for each target.

const std = @import("std");
const builtin = @import("builtin");
const target_triple = @import("target_triple.zig");

// The three `runtime_os` backend modules. They import only `std`/`builtin`
// (see each file's "Embedding contract" header) and are compiled as ordinary
// Zig modules for `zig build test`, so importing them here for their pure
// `caps` booleans is sound. We read ONLY the literal boolean caps
// (`supports_signals`, `supports_termios`); their host-relative `caps`
// (`supports_backtrace`, `console_handle`) are NOT consumed — `:backtrace` is
// recomputed per requested target below so the value is target-correct rather
// than compiler-host-relative.
const runtime_os_posix = @import("runtime_os/posix.zig");
const runtime_os_windows = @import("runtime_os/windows.zig");
const runtime_os_wasi = @import("runtime_os/wasi.zig");

/// A single target capability. Each variant names a behavior a compilation
/// target either supports or does not; a declaration `@available_on(:cap)`
/// requires the matching variant, and a reference on a target lacking it is a
/// compile error. The vocabulary is intentionally small and capability-shaped
/// (not OS-shaped): the bitset has room for more atoms, and a custom target
/// gains a capability purely from its `std.Target` facts.
pub const TargetCapability = enum(u3) {
    /// open / read / write / stat paths. (`std.fs` works on the target; wasi
    /// gates behind preopens but the API is present.)
    filesystem = 0,
    /// spawn / fork / exec a child process. (A process model exists: POSIX
    /// fork+exec, Win32 CreateProcess; wasi preview1 has none.)
    processes = 1,
    /// hardware-fault / async signal handling. Single-sourced from
    /// `runtime_os` `caps.supports_signals` (posix sigaction, windows VEH,
    /// wasi none).
    signals = 2,
    /// sockets / TCP / UDP. (A socket layer exists: POSIX/Winsock; wasi
    /// preview1 has no sockets — preview2 differs.)
    network = 3,
    /// OS threads / shared-memory concurrency. (pthreads/Win32; wasm32 is
    /// single-threaded without the atomics+bulk-memory features / wasi-threads.)
    threads = 4,
    /// raw-mode TTY / termios. Single-sourced from `runtime_os`
    /// `caps.supports_termios` (posix termios; windows console-mode partial,
    /// reported unsupported; wasi none).
    terminal = 5,
    /// symbolized stack traces. Single-sourced from `runtime_os`
    /// `caps.supports_backtrace` (`std.debug.SelfInfo != void`), recomputed
    /// here for the requested target's object format.
    backtrace = 6,

    /// The capability's canonical atom name (without the leading `:`), the
    /// spelling an author writes in `@available_on(:name)` and the spelling
    /// the diagnostic prints. Stable: the gate and the diagnostic both key
    /// off these, so they are never renamed.
    pub fn atomName(self: TargetCapability) []const u8 {
        return @tagName(self);
    }
};

/// The number of distinct capabilities — the bit width of `TargetCapabilitySet`.
pub const capability_count = @typeInfo(TargetCapability).@"enum".fields.len;

/// A set of target capabilities, a `u8` bitset (mirroring the memory model's
/// `declared_caps` and CTFE's `CapabilitySet` shape). The compiler reads bits,
/// never names; `missing` / `isSubsetOf` drive the gate.
pub const TargetCapabilitySet = struct {
    flags: u8 = 0,

    /// True iff `cap` is present in the set.
    pub fn has(self: TargetCapabilitySet, cap: TargetCapability) bool {
        return (self.flags & bit(cap)) != 0;
    }

    /// The set with `cap` added (immutable; returns a new set).
    pub fn with(self: TargetCapabilitySet, cap: TargetCapability) TargetCapabilitySet {
        return .{ .flags = self.flags | bit(cap) };
    }

    /// True iff every capability in `self` is also in `other`. Used by the
    /// gate: a declaration is available when its required set is a subset of
    /// the target's set.
    pub fn isSubsetOf(self: TargetCapabilitySet, other: TargetCapabilitySet) bool {
        return (self.flags & ~other.flags) == 0;
    }

    /// The first capability in `self` that is absent from `other`, in
    /// `TargetCapability` declaration order, or null when `self` is a subset
    /// of `other`. The gate reports this single missing capability so the
    /// diagnostic names exactly one (`needs capability :processes`) — the
    /// first unmet requirement, deterministically.
    pub fn firstMissingFrom(self: TargetCapabilitySet, other: TargetCapabilitySet) ?TargetCapability {
        const missing_bits = self.flags & ~other.flags;
        if (missing_bits == 0) return null;
        inline for (@typeInfo(TargetCapability).@"enum".fields) |field| {
            const cap: TargetCapability = @enumFromInt(field.value);
            if ((missing_bits & bit(cap)) != 0) return cap;
        }
        unreachable;
    }

    fn bit(cap: TargetCapability) u8 {
        return @as(u8, 1) << @intFromEnum(cap);
    }
};

/// Map an atom name (WITHOUT the leading `:`) to its capability, or null when
/// the name is not a known capability. The CTFE attribute evaluator calls this
/// on each `@available_on(:name)` value: a null return is a precise compile
/// error at the attribute value's span (an unknown capability atom), mirroring
/// CTFE's `CapabilitySet.capabilityFromAtomName`.
pub fn capabilityFromAtomName(name: []const u8) ?TargetCapability {
    inline for (@typeInfo(TargetCapability).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

/// Which `runtime_os` backend governs a target's runtime-primitive caps,
/// selected by `os.tag`. This MIRRORS the codegen seam's backend dispatch in
/// `src/compiler.zig`'s `buildRuntimeOsSeam`
/// (`switch (builtin.os.tag) { .windows => …, .wasi => …, else => posix }`),
/// so the Zap-level `:signals`/`:terminal` truth is the SAME selection the
/// emitted runtime makes. Adding a fourth backend means changing both this
/// switch and the seam — the single-source test below pins them together.
const RuntimeOsBackend = enum { posix, windows, wasi };

fn runtimeOsBackendForOs(os_tag: std.Target.Os.Tag) RuntimeOsBackend {
    return switch (os_tag) {
        .windows => .windows,
        .wasi => .wasi,
        else => .posix,
    };
}

/// `runtime_os` `caps.supports_signals` for the backend governing `os_tag`.
/// Read directly from the backend modules — the single source of truth shared
/// with the codegen seam.
fn runtimeSupportsSignals(os_tag: std.Target.Os.Tag) bool {
    return switch (runtimeOsBackendForOs(os_tag)) {
        .posix => runtime_os_posix.Backend.caps.supports_signals,
        .windows => runtime_os_windows.Backend.caps.supports_signals,
        .wasi => runtime_os_wasi.Backend.caps.supports_signals,
    };
}

/// `runtime_os` `caps.supports_termios` for the backend governing `os_tag`.
fn runtimeSupportsTermios(os_tag: std.Target.Os.Tag) bool {
    return switch (runtimeOsBackendForOs(os_tag)) {
        .posix => runtime_os_posix.Backend.caps.supports_termios,
        .windows => runtime_os_windows.Backend.caps.supports_termios,
        .wasi => runtime_os_wasi.Backend.caps.supports_termios,
    };
}

/// Whether the target supports symbolized stack traces — the per-target value
/// of the backends' `caps.supports_backtrace = std.debug.SelfInfo != void`.
/// `std.debug.SelfInfo` is `void` exactly when the target's default object
/// format has no unwinder (`.wasm`, `.plan9`, `.spirv`, freestanding/other
/// ELF). We reproduce that `std.Target.ObjectFormat.default`-driven condition
/// for the REQUESTED target (the backend const itself would reflect the
/// compiler host). This is the single source of truth: the condition is
/// byte-identical to `lib/std/debug.zig`'s `SelfInfo` selection.
fn targetSupportsBacktrace(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) bool {
    return switch (std.Target.ObjectFormat.default(os_tag, arch)) {
        .coff => os_tag == .windows, // COFF self-info only for Windows
        .elf => switch (os_tag) {
            .freestanding, .other => false,
            else => true,
        },
        .macho => true,
        .plan9, .spirv, .wasm => false,
        .c, .hex, .raw => false,
    };
}

/// Whether the target has a child-process model (fork/exec or CreateProcess).
/// A `std.Target` os fact: every hosted OS the fork supports has one EXCEPT
/// wasi preview1 (no process model) and the bare-metal/`other` os values.
fn targetSupportsProcesses(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .wasi, .freestanding, .other => false,
        else => true,
    };
}

/// Whether the target has a sockets/network layer. A `std.Target` os fact:
/// hosted OSes have BSD sockets / Winsock; wasi preview1 has no sockets and
/// bare-metal has none.
fn targetSupportsNetwork(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .wasi, .freestanding, .other => false,
        else => true,
    };
}

/// Whether the target has OS threads. A `std.Target` os/arch fact: hosted OSes
/// have pthreads/Win32 threads; wasm32 (wasi v1) is single-threaded without
/// the atomics+bulk-memory features / wasi-threads, and bare-metal has none.
fn targetSupportsThreads(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) bool {
    if (arch == .wasm32 or arch == .wasm64) return false; // single-threaded v1
    return switch (os_tag) {
        .wasi, .freestanding, .other => false,
        else => true,
    };
}

/// Whether the target has a usable filesystem. A `std.Target` os fact: hosted
/// OSes have `std.fs`; wasi exposes a preopen-gated filesystem (present);
/// bare-metal/`other` has none.
fn targetSupportsFilesystem(os_tag: std.Target.Os.Tag) bool {
    return switch (os_tag) {
        .freestanding, .other => false,
        else => true, // including .wasi (preopen-gated, but present)
    };
}

/// The capability set a compilation target supports, given its resolved
/// `{os, arch, abi}` atoms (the `@target` value). This is the function the
/// gating pass intersects each declaration's `@available_on` requirement
/// against. Returns null only when an atom name does not parse to a
/// `std.Target` enum value — a target the compiler could not have accepted in
/// the first place (the caller then leaves declarations un-gated rather than
/// mis-gating an unknown target).
pub fn capabilitiesForTarget(atoms: target_triple.TargetAtoms) ?TargetCapabilitySet {
    const os_tag = osTagFromName(atoms.os) orelse return null;
    const arch = archFromName(atoms.arch) orelse return null;

    var set = TargetCapabilitySet{};
    // Language-domain caps (std.Target os/arch facts).
    if (targetSupportsFilesystem(os_tag)) set = set.with(.filesystem);
    if (targetSupportsProcesses(os_tag)) set = set.with(.processes);
    if (targetSupportsNetwork(os_tag)) set = set.with(.network);
    if (targetSupportsThreads(os_tag, arch)) set = set.with(.threads);
    // Runtime-primitive caps (single-sourced from runtime_os backends).
    if (runtimeSupportsSignals(os_tag)) set = set.with(.signals);
    if (runtimeSupportsTermios(os_tag)) set = set.with(.terminal);
    if (targetSupportsBacktrace(os_tag, arch)) set = set.with(.backtrace);
    return set;
}

/// Case-insensitively resolve an os atom name to its `std.Target.Os.Tag`.
/// The atom names this module receives are `std.Target.Os.Tag` `@tagName`s
/// (produced by `target_triple.resolve`), so a direct field match suffices.
fn osTagFromName(name: []const u8) ?std.Target.Os.Tag {
    return std.meta.stringToEnum(std.Target.Os.Tag, name);
}

/// Resolve an arch atom name to its `std.Target.Cpu.Arch`.
fn archFromName(name: []const u8) ?std.Target.Cpu.Arch {
    return std.meta.stringToEnum(std.Target.Cpu.Arch, name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "capabilityFromAtomName: known and unknown atoms" {
    try std.testing.expectEqual(TargetCapability.filesystem, capabilityFromAtomName("filesystem").?);
    try std.testing.expectEqual(TargetCapability.processes, capabilityFromAtomName("processes").?);
    try std.testing.expectEqual(TargetCapability.signals, capabilityFromAtomName("signals").?);
    try std.testing.expectEqual(TargetCapability.network, capabilityFromAtomName("network").?);
    try std.testing.expectEqual(TargetCapability.threads, capabilityFromAtomName("threads").?);
    try std.testing.expectEqual(TargetCapability.terminal, capabilityFromAtomName("terminal").?);
    try std.testing.expectEqual(TargetCapability.backtrace, capabilityFromAtomName("backtrace").?);
    // Unknown / CTFE-capability names / OS names are NOT target capabilities.
    try std.testing.expectEqual(@as(?TargetCapability, null), capabilityFromAtomName("processex"));
    try std.testing.expectEqual(@as(?TargetCapability, null), capabilityFromAtomName("pure"));
    try std.testing.expectEqual(@as(?TargetCapability, null), capabilityFromAtomName("wasi"));
    try std.testing.expectEqual(@as(?TargetCapability, null), capabilityFromAtomName(""));
}

test "atomName round-trips capabilityFromAtomName" {
    inline for (@typeInfo(TargetCapability).@"enum".fields) |field| {
        const cap: TargetCapability = @enumFromInt(field.value);
        try std.testing.expectEqual(cap, capabilityFromAtomName(cap.atomName()).?);
    }
}

test "TargetCapabilitySet: has/with/isSubsetOf/firstMissingFrom" {
    const empty = TargetCapabilitySet{};
    try std.testing.expect(!empty.has(.processes));

    const fs = empty.with(.filesystem);
    try std.testing.expect(fs.has(.filesystem));
    try std.testing.expect(!fs.has(.processes));

    const fs_proc = fs.with(.processes);
    try std.testing.expect(fs.isSubsetOf(fs_proc));
    try std.testing.expect(!fs_proc.isSubsetOf(fs));

    // firstMissingFrom returns the first absent cap in declaration order.
    try std.testing.expectEqual(@as(?TargetCapability, null), fs.firstMissingFrom(fs_proc));
    try std.testing.expectEqual(TargetCapability.processes, fs_proc.firstMissingFrom(fs).?);

    // Requiring filesystem+processes against a filesystem-only target: the
    // first missing (declaration order) is processes.
    const req = empty.with(.filesystem).with(.processes);
    try std.testing.expectEqual(TargetCapability.processes, req.firstMissingFrom(fs).?);
}

test "capabilitiesForTarget: native (posix) has every capability" {
    // Native posix (darwin/linux) is the regression anchor: all caps present,
    // so no decl is ever gated out and behavior is unchanged.
    const native = target_triple.resolve(null).?;
    const caps = capabilitiesForTarget(native).?;
    // posix backends report signals+termios true; macho/elf have backtrace.
    try std.testing.expect(caps.has(.filesystem));
    try std.testing.expect(caps.has(.processes));
    try std.testing.expect(caps.has(.network));
    try std.testing.expect(caps.has(.threads));
    try std.testing.expect(caps.has(.signals));
    try std.testing.expect(caps.has(.terminal));
    try std.testing.expect(caps.has(.backtrace));
}

test "capabilitiesForTarget: wasm32-wasi has :filesystem but not the rest" {
    const wasi = target_triple.resolve("wasm32-wasi").?;
    const caps = capabilitiesForTarget(wasi).?;
    try std.testing.expect(caps.has(.filesystem)); // preopen-gated, present
    try std.testing.expect(!caps.has(.processes)); // no process model
    try std.testing.expect(!caps.has(.signals)); // wasi caps.supports_signals=false
    try std.testing.expect(!caps.has(.network)); // preview1 has no sockets
    try std.testing.expect(!caps.has(.threads)); // wasm32 single-threaded v1
    try std.testing.expect(!caps.has(.terminal)); // wasi caps.supports_termios=false
    try std.testing.expect(!caps.has(.backtrace)); // wasm object format = void SelfInfo
}

test "capabilitiesForTarget: x86_64-windows-gnu has :signals(VEH) but not :terminal" {
    const win = target_triple.resolve("x86_64-windows-gnu").?;
    const caps = capabilitiesForTarget(win).?;
    try std.testing.expect(caps.has(.filesystem));
    try std.testing.expect(caps.has(.processes)); // CreateProcess
    try std.testing.expect(caps.has(.network)); // Winsock
    try std.testing.expect(caps.has(.threads)); // Win32 threads
    try std.testing.expect(caps.has(.signals)); // VEH → windows caps.supports_signals=true
    try std.testing.expect(!caps.has(.terminal)); // windows caps.supports_termios=false
    try std.testing.expect(caps.has(.backtrace)); // COFF/Windows SelfInfo
}

test "single-source: runtime-primitive caps equal the runtime_os backend caps for each target" {
    // The DEEP invariant of the unified vocabulary (the plan's Phase-4 lock-in,
    // asserted here at the source): the Zap-level :signals/:terminal atoms are
    // DEFINED AS the runtime_os backend `caps` booleans for the resolved
    // target — there is no second source of truth. This test pins
    // `capabilitiesForTarget`'s runtime-primitive bits to the exact backend
    // constants, so any drift between the language gate and the codegen seam
    // is a compile-time test failure.
    const Case = struct {
        triple: []const u8,
        backend_signals: bool,
        backend_termios: bool,
    };
    const cases = [_]Case{
        .{ .triple = "x86_64-linux-gnu", .backend_signals = runtime_os_posix.Backend.caps.supports_signals, .backend_termios = runtime_os_posix.Backend.caps.supports_termios },
        .{ .triple = "aarch64-macos-none", .backend_signals = runtime_os_posix.Backend.caps.supports_signals, .backend_termios = runtime_os_posix.Backend.caps.supports_termios },
        .{ .triple = "x86_64-windows-gnu", .backend_signals = runtime_os_windows.Backend.caps.supports_signals, .backend_termios = runtime_os_windows.Backend.caps.supports_termios },
        .{ .triple = "wasm32-wasi", .backend_signals = runtime_os_wasi.Backend.caps.supports_signals, .backend_termios = runtime_os_wasi.Backend.caps.supports_termios },
    };
    for (cases) |c| {
        const atoms = target_triple.resolve(c.triple).?;
        const caps = capabilitiesForTarget(atoms).?;
        try std.testing.expectEqual(c.backend_signals, caps.has(.signals));
        try std.testing.expectEqual(c.backend_termios, caps.has(.terminal));
    }
}

test "capabilitiesForTarget: unknown target atoms return null" {
    // A target whose os/arch atom does not resolve to a std.Target enum value
    // yields null so the caller leaves decls un-gated rather than mis-gating.
    const bogus = target_triple.TargetAtoms{ .os = "notanos", .arch = "x86_64", .abi = "gnu" };
    try std.testing.expectEqual(@as(?TargetCapabilitySet, null), capabilitiesForTarget(bogus));
}
