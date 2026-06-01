//! Compilation-target → comptime atom-name resolution.
//!
//! Maps a target triple string (`arch-os[-abi]`, e.g. `"aarch64-macos-none"`
//! or the two-component `"wasm32-wasi"`) — or the native sentinel
//! (`null` / `""` / `"default"`) — to the `{os, arch, abi}` atom NAMES the
//! Zap language surfaces through the comptime `@target` intrinsic and the
//! build-manifest `%Zap.Env` value.
//!
//! This is the single source of truth shared by:
//!   - the `@target` HIR fold (`src/hir.zig`), which resolves
//!     `@target.os`/`.arch`/`.abi` to comptime-known atom names so a
//!     `case`/`if` over them folds at compile time; and
//!   - the build-manifest env construction (`src/builder.zig`), which must
//!     report the *requested* compilation target (not the host) as atoms.
//!
//! The atom names are the `std.Target.{Cpu.Arch,Os.Tag,Abi}` `@tagName`
//! strings (`"macos"`, `"wasi"`, `"aarch64"`, `"x86_64"`, `"wasm32"`,
//! `"gnu"`, `"musl"`, `"none"`, …). They are comptime-static string
//! constants owned by the std enum, so the resolved struct holds borrowed
//! `[]const u8` slices with `'static`-equivalent lifetime — no allocation,
//! no ownership transfer.
//!
//! The os/arch tag-name lookup and the two-component default-ABI rule
//! deliberately mirror `src/memory/driver.zig`'s `parseTargetTriple` /
//! `defaultAbiForTriple` so the value `@target` surfaces is byte-identical
//! to the triple the manager-driver and fork-compile path resolve. The
//! one intentional difference: this module resolves the NATIVE sentinel to
//! the host triple (the driver leaves native implicit because the fork's
//! `ZAP_FORK_ARCH_NATIVE` sentinel handles it downstream), because
//! `@target` on a native build must still surface concrete host atoms.

const std = @import("std");
const builtin = @import("builtin");

/// The resolved compilation target as comptime atom NAMES. Each field is a
/// borrowed static `[]const u8` (a `std.Target.*` `@tagName` constant) —
/// the caller must NOT free it and may store it for the program lifetime.
pub const TargetAtoms = struct {
    /// OS tag name (`std.Target.Os.Tag` `@tagName`): `"macos"`, `"linux"`,
    /// `"windows"`, `"wasi"`, …
    os: []const u8,
    /// CPU arch tag name (`std.Target.Cpu.Arch` `@tagName`): `"aarch64"`,
    /// `"x86_64"`, `"wasm32"`, …
    arch: []const u8,
    /// ABI tag name (`std.Target.Abi` `@tagName`): `"gnu"`, `"musl"`,
    /// `"none"`, …
    abi: []const u8,
};

/// True when `triple` is the native sentinel — i.e. no explicit
/// `-Dtarget=` was passed. The frontend uses `"default"` (and historically
/// `""`) and `null` for "build for the host"; all three resolve to the
/// host triple's atoms.
pub fn isNativeSentinel(triple: ?[]const u8) bool {
    const t = triple orelse return true;
    return t.len == 0 or std.mem.eql(u8, t, "default") or std.mem.eql(u8, t, "native");
}

/// Resolve a target triple string (or the native sentinel) to its
/// `{os, arch, abi}` atom names. Returns `null` for a triple that is
/// malformed or names an unknown `std.Target.*` enum value (the caller
/// surfaces the bad triple through its own diagnostic path; this function
/// does not allocate or report).
///
/// Native (`null` / `""` / `"default"` / `"native"`) resolves to the host
/// triple via `builtin.target`, so `@target` on a native build surfaces
/// concrete host atoms (e.g. `:macos`/`:aarch64`/`:none`) rather than a
/// placeholder. A two-component `arch-os` triple (e.g. `"wasm32-wasi"`)
/// synthesizes the OS's default ABI via `defaultAbiName`, exactly as the
/// manager driver's `parseTargetTriple` does.
pub fn resolve(triple: ?[]const u8) ?TargetAtoms {
    if (isNativeSentinel(triple)) {
        return .{
            .os = @tagName(builtin.target.os.tag),
            .arch = @tagName(builtin.target.cpu.arch),
            .abi = @tagName(builtin.target.abi),
        };
    }

    const t = triple.?;
    var iter = std.mem.tokenizeAny(u8, t, "-");
    const arch_str = iter.next() orelse return null;
    const os_str = iter.next() orelse return null;
    const abi_str_opt = iter.next();
    if (iter.next() != null) return null; // at most three segments

    const arch_name = tagName(std.Target.Cpu.Arch, arch_str) orelse return null;
    const os_name = tagName(std.Target.Os.Tag, os_str) orelse return null;

    const abi_name: []const u8 = if (abi_str_opt) |abi_str|
        (tagName(std.Target.Abi, abi_str) orelse return null)
    else
        (defaultAbiName(os_name) orelse return null);

    return .{ .os = os_name, .arch = arch_name, .abi = abi_name };
}

/// The default ABI atom name for an `arch-os` triple whose ABI segment was
/// omitted. Mirrors `src/memory/driver.zig`'s `defaultAbiForTriple`:
/// `wasi → musl` (wasi-libc), `macos → none` (Mach-O native),
/// `windows → gnu` (mingw, Zap's bundled Windows toolchain). Returns null
/// for an OS with no unambiguous default so the caller rejects the
/// under-specified triple rather than guessing.
fn defaultAbiName(os_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, os_name, "wasi")) return @tagName(std.Target.Abi.musl);
    if (std.mem.eql(u8, os_name, "macos")) return @tagName(std.Target.Abi.none);
    if (std.mem.eql(u8, os_name, "windows")) return @tagName(std.Target.Abi.gnu);
    return null;
}

/// Case-insensitively match `name` against an enum's field names and
/// return the matched field's canonical `@tagName` (a comptime-static
/// string), or null when no field matches. Returning the canonical tag
/// name (rather than echoing the input) normalizes case so the surfaced
/// atom is always the std-canonical spelling.
fn tagName(comptime E: type, name: []const u8) ?[]const u8 {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(field.name, name)) {
            return field.name;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolve: three-component triples map to canonical atom names" {
    const r = resolve("aarch64-macos-none").?;
    try std.testing.expectEqualStrings("macos", r.os);
    try std.testing.expectEqualStrings("aarch64", r.arch);
    try std.testing.expectEqualStrings("none", r.abi);

    const w = resolve("x86_64-windows-gnu").?;
    try std.testing.expectEqualStrings("windows", w.os);
    try std.testing.expectEqualStrings("x86_64", w.arch);
    try std.testing.expectEqualStrings("gnu", w.abi);

    const l = resolve("x86_64-linux-musl").?;
    try std.testing.expectEqualStrings("linux", l.os);
    try std.testing.expectEqualStrings("x86_64", l.arch);
    try std.testing.expectEqualStrings("musl", l.abi);
}

test "resolve: two-component triple synthesizes the OS default ABI" {
    // wasm32-wasi → abi musl (wasi-libc), matching driver.parseTargetTriple.
    const r = resolve("wasm32-wasi").?;
    try std.testing.expectEqualStrings("wasi", r.os);
    try std.testing.expectEqualStrings("wasm32", r.arch);
    try std.testing.expectEqualStrings("musl", r.abi);

    // *-macos → none; *-windows → gnu.
    try std.testing.expectEqualStrings("none", resolve("aarch64-macos").?.abi);
    try std.testing.expectEqualStrings("gnu", resolve("x86_64-windows").?.abi);
}

test "resolve: case-insensitive input normalizes to canonical tag name" {
    const r = resolve("AArch64-MacOS-None").?;
    try std.testing.expectEqualStrings("macos", r.os);
    try std.testing.expectEqualStrings("aarch64", r.arch);
    try std.testing.expectEqualStrings("none", r.abi);
}

test "resolve: native sentinels resolve to the host triple" {
    const expected_os = @tagName(builtin.target.os.tag);
    const expected_arch = @tagName(builtin.target.cpu.arch);
    const expected_abi = @tagName(builtin.target.abi);

    for ([_]?[]const u8{ null, "", "default", "native" }) |sentinel| {
        const r = resolve(sentinel).?;
        try std.testing.expectEqualStrings(expected_os, r.os);
        try std.testing.expectEqualStrings(expected_arch, r.arch);
        try std.testing.expectEqualStrings(expected_abi, r.abi);
    }
}

test "isNativeSentinel: recognizes all native spellings and rejects real triples" {
    try std.testing.expect(isNativeSentinel(null));
    try std.testing.expect(isNativeSentinel(""));
    try std.testing.expect(isNativeSentinel("default"));
    try std.testing.expect(isNativeSentinel("native"));
    try std.testing.expect(!isNativeSentinel("wasm32-wasi"));
    try std.testing.expect(!isNativeSentinel("aarch64-macos-none"));
}

test "resolve: malformed or unknown triples return null" {
    try std.testing.expectEqual(@as(?TargetAtoms, null), resolve("wasm32")); // one component
    try std.testing.expectEqual(@as(?TargetAtoms, null), resolve("aarch64-macos-none-extra")); // four components
    try std.testing.expectEqual(@as(?TargetAtoms, null), resolve("not-a-real-arch-gnu")); // bad arch
    try std.testing.expectEqual(@as(?TargetAtoms, null), resolve("aarch64-not-an-os-gnu")); // bad os
    try std.testing.expectEqual(@as(?TargetAtoms, null), resolve("aarch64-macos-not-an-abi")); // bad abi
    // Two-component with no default-ABI OS is rejected (under-specified).
    try std.testing.expectEqual(@as(?TargetAtoms, null), resolve("aarch64-linux"));
}
