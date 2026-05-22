//! Offline address symbolizer for Zap binaries — the engine behind the
//! `zap addr2line` subcommand.
//!
//! Given a (possibly stripped, possibly cross-compiled) Zap executable plus
//! captured machine addresses — typically the `0x<addr>` frames a release
//! crash report prints when the stripped binary can't symbolize itself — this
//! resolves each address to `Struct.local/arity at file.zap:line`, the same
//! rendering the in-process crash printer (`src/runtime.zig`) produces.
//!
//! It reuses the EXACT debug-info path the crash printer's symbolizer uses,
//! but against an arbitrary on-disk image instead of the running process:
//!
//!   1. The fork's `std.debug.MachOFile` / `std.debug.ElfFile` DWARF reader
//!      opens the binary's embedded DWARF (Debug / ReleaseSafe) OR — when the
//!      binary was stripped (ReleaseFast / ReleaseSmall, per the Phase 0
//!      per-mode policy) — its sibling split-debug artifact. On Mach-O the
//!      fork's `MachOFile.getDwarfForAddress` already discovers the
//!      `<exe>.dSYM/Contents/Resources/DWARF/<basename>` bundle on demand, so
//!      the stripped + sibling-dSYM case needs no extra plumbing here.
//!
//!   2. The Phase 0 `.zap-symbols` side-table (`src/zap_symbol_table.zig`
//!      `Reader`) maps the mangled linker symbol DWARF reports
//!      (`Demo.deeper__1`) back to the authoritative Zap name
//!      (`Demo.deeper/1`).
//!
//! Address space contract: addresses are STATIC image virtual addresses (the
//! file vmaddr space the symtab and DWARF use) — NOT the ASLR-slid runtime
//! addresses dyld assigns. The crash printer prints static addresses for its
//! `0x<addr>` fallback (it subtracts the image slide first; brief VI.B #9), so
//! a release-crash round-trip is direct. A caller holding raw runtime
//! addresses from another tool can pre-subtract the load bias, or pass it via
//! the CLI `--load-address` flag, which this module applies before lookup.
//!
//! This is tooling, not a runtime primitive: it allocates freely, opens
//! files, and does NOT need to be async-signal-safe (unlike the in-process
//! printer it complements).

const std = @import("std");
const builtin = @import("builtin");
const zap_symbol_table = @import("zap_symbol_table.zig");

/// The Zap-level identity of a symbol, recovered from the `.zap-symbols`
/// side-table: `struct + "." + local + "/" + arity` (or just `local/arity`
/// for the top-level entry point, whose `zap_struct` is null).
pub const ZapName = struct {
    zap_struct: ?[]const u8,
    zap_local: []const u8,
    zap_arity: u32,
};

/// A fully-resolved frame for one input address.
///
/// `mangled` is always the best linker/DWARF symbol name available (with the
/// platform's leading `_` stripped, matching the side-table keys). `zap` is
/// the side-table mapping back to the Zap name, or `null` when the sidecar is
/// absent or has no entry for this symbol (then the mangled name is the
/// authoritative answer — it is still the linker symbol). `source` is the
/// DWARF file:line, or `null` when DWARF is unavailable for the address.
pub const Frame = struct {
    /// The static virtual address that was looked up (after any load-bias
    /// adjustment). Echoed back so output lines are self-describing.
    address: u64,
    mangled: ?[]const u8,
    zap: ?ZapName,
    source: ?std.debug.SourceLocation,
};

pub const Error = error{
    /// The host toolchain has no `std.debug` DWARF reader for this target's
    /// object format (e.g. an unsupported cross-target). Symbolization is
    /// impossible; the caller should print raw addresses.
    UnsupportedObjectFormat,
} || std.mem.Allocator.Error;

/// Strip the platform's leading underscore from a linker symbol so it matches
/// the `.zap-symbols` side-table keys. Mach-O prefixes every symbol with `_`
/// (`_Demo.deeper__1`); the side-table stores the un-prefixed form. ELF has no
/// such prefix, and the Zap mangling never starts a name with `_`, so this is
/// a no-op there. Mirrors `runtime.stripSymbolUnderscore`.
pub fn stripSymbolUnderscore(name: []const u8) []const u8 {
    if (comptime builtin.object_format == .macho) {
        if (name.len > 0 and name[0] == '_') return name[1..];
    }
    return name;
}

/// Resolver over one on-disk Zap image plus its optional `.zap-symbols`
/// sidecar. Owns all loaded state; call `deinit` to release it.
///
/// Platform-branched on the host object format (the only formats the fork's
/// `std.debug` DWARF reader supports for offline images are Mach-O and ELF).
/// The `zap addr2line` subcommand only symbolizes natively-shaped images, so
/// the host's object format is the target's — a Mach-O host resolves Mach-O
/// binaries, an ELF host resolves ELF binaries. Cross-format offline
/// symbolization (an ELF crash dump on a Mach-O host) is a future extension
/// gated by the fork exposing a target-format-parameterized loader; today it
/// returns `UnsupportedObjectFormat`.
pub const Resolver = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    image: Image,
    /// Backing bytes for the loaded `.zap-symbols` sidecar, or `null` when
    /// absent. Kept alive for the reader's lifetime.
    sidecar_bytes: ?[]u8,
    /// Decoded side-table reader, or `null` (no sidecar / unparseable → the
    /// resolver falls back to the mangled DWARF symbol).
    symbols: ?zap_symbol_table.Reader,

    const native_endian = builtin.target.cpu.arch.endian();

    /// The fork's per-format debug-info container. Mach-O and ELF are the two
    /// the fork's `std.debug` reader can open for an arbitrary file.
    const Image = union(enum) {
        macho: std.debug.MachOFile,
        elf: ElfImage,
    };

    /// ELF carries its DWARF inline in `ElfFile`; addresses resolve directly
    /// against `ef.dwarf` (no per-symbol OSO/dSYM split like Mach-O), so we
    /// open and prepare the DWARF once at load time.
    const ElfImage = struct {
        file: std.debug.ElfFile,
    };

    /// Open `binary_path` and (best-effort) its sibling `<binary_path>.zap-symbols`.
    /// `binary_path` must name an existing image of the host's object format.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, binary_path: []const u8) (Error || OpenError)!Resolver {
        const image = try openImage(gpa, io, binary_path);
        errdefer freeImage(gpa, image);

        const sidecar = loadSidecar(gpa, io, binary_path);
        return .{
            .gpa = gpa,
            .io = io,
            .image = image,
            .sidecar_bytes = sidecar.bytes,
            .symbols = sidecar.reader,
        };
    }

    pub const OpenError = error{
        /// The binary could not be opened or is not a valid image of the
        /// host's object format.
        InvalidBinary,
    };

    pub fn deinit(self: *Resolver) void {
        freeImage(self.gpa, self.image);
        if (self.sidecar_bytes) |b| self.gpa.free(b);
        self.* = undefined;
    }

    /// True when a `.zap-symbols` sidecar was found and parsed. When false,
    /// resolution still works but reports mangled names (the CLI surfaces this
    /// so the user knows to supply the sidecar for full Zap names).
    pub fn hasSidecar(self: *const Resolver) bool {
        return self.symbols != null;
    }

    /// Resolve one STATIC virtual address. `text_arena` backs any
    /// DWARF-produced strings (the joined source path) for the returned
    /// frame; it must outlive the `Frame`. Never fails on a missing
    /// symbol/line — those become `null` fields so the caller can still print
    /// the raw address.
    pub fn resolve(self: *Resolver, text_arena: std.mem.Allocator, address: u64) Frame {
        const sym = self.symbolize(text_arena, address);

        const mangled = if (sym.name) |m| stripSymbolUnderscore(m) else null;
        const zap = if (mangled) |m| self.mapToZap(m) else null;

        return .{
            .address = address,
            .mangled = mangled,
            .zap = zap,
            .source = sym.source,
        };
    }

    /// Name + source for one address, resolved in a single debug-info pass —
    /// mirroring the fork's `std.debug.SelfInfo` `getSymbols` (Mach-O) and
    /// `std.debug.Info.resolveAddresses`, so the offline result matches what
    /// the in-process crash printer produces for the same frame. Crucially, a
    /// freshly-loaded OSO `.o` / dSYM `Dwarf` has its compile-unit ranges
    /// populated lazily; we force `populateRanges` (exactly as
    /// `Info.resolveAddresses` does) before `findCompileUnit`/`getLineNumberInfo`,
    /// otherwise the line lookup misses and only the symbol name comes back.
    fn symbolize(self: *Resolver, text_arena: std.mem.Allocator, address: u64) struct { name: ?[]const u8, source: ?std.debug.SourceLocation } {
        switch (self.image) {
            .macho => |*mf| {
                const dwarf, const ofile_vaddr = mf.getDwarfForAddress(self.gpa, self.io, address) catch {
                    // No DWARF for this address: best-effort symtab name only.
                    return .{ .name = mf.lookupSymbolName(address) catch null, .source = null };
                };
                if (dwarf.ranges.items.len == 0) {
                    dwarf.populateRanges(self.gpa, native_endian) catch {};
                }
                const name = dwarf.getSymbolName(ofile_vaddr) orelse (mf.lookupSymbolName(address) catch null);
                const source = src: {
                    const cu = dwarf.findCompileUnit(native_endian, ofile_vaddr) catch break :src null;
                    break :src dwarf.getLineNumberInfo(self.gpa, text_arena, native_endian, cu, ofile_vaddr) catch null;
                };
                return .{ .name = name, .source = source };
            },
            .elf => |*ei| {
                const dwarf = &(ei.file.dwarf orelse return .{ .name = null, .source = null });
                if (dwarf.ranges.items.len == 0) {
                    dwarf.populateRanges(self.gpa, ei.file.endian) catch {};
                }
                const name = dwarf.getSymbolName(address);
                const source = src: {
                    const cu = dwarf.findCompileUnit(ei.file.endian, address) catch break :src null;
                    break :src dwarf.getLineNumberInfo(self.gpa, text_arena, ei.file.endian, cu, address) catch null;
                };
                return .{ .name = name, .source = source };
            },
        }
    }

    /// Map a (underscore-stripped) mangled name to its Zap identity via the
    /// side-table, or `null` when there is no sidecar / no entry.
    fn mapToZap(self: *const Resolver, mangled: []const u8) ?ZapName {
        const reader = self.symbols orelse return null;
        const view = reader.findByMangled(mangled) orelse return null;
        return .{
            .zap_struct = view.zap_struct,
            .zap_local = view.zap_local,
            .zap_arity = view.zap_arity,
        };
    }

    fn openImage(gpa: std.mem.Allocator, io: std.Io, binary_path: []const u8) (Error || OpenError)!Image {
        switch (comptime builtin.object_format) {
            .macho => {
                const mf = std.debug.MachOFile.load(gpa, io, binary_path, builtin.target.cpu.arch) catch {
                    return error.InvalidBinary;
                };
                return .{ .macho = mf };
            },
            .elf => {
                var file = std.Io.Dir.cwd().openFile(io, binary_path, .{}) catch return error.InvalidBinary;
                defer file.close(io);
                var ef = std.debug.ElfFile.load(gpa, io, file, null, &.none) catch return error.InvalidBinary;
                errdefer ef.deinit(gpa);
                if (ef.dwarf == null) return error.InvalidBinary;
                ef.dwarf.?.open(gpa, ef.endian) catch return error.InvalidBinary;
                ef.dwarf.?.populateRanges(gpa, ef.endian) catch return error.InvalidBinary;
                return .{ .elf = .{ .file = ef } };
            },
            else => return error.UnsupportedObjectFormat,
        }
    }

    fn freeImage(gpa: std.mem.Allocator, image: Image) void {
        var img = image;
        switch (img) {
            .macho => |*mf| mf.deinit(gpa),
            .elf => |*ei| ei.file.deinit(gpa),
        }
    }

    const Sidecar = struct {
        bytes: ?[]u8,
        reader: ?zap_symbol_table.Reader,
    };

    /// Load `<binary_path>.zap-symbols` (the Phase 0 convention) if present and
    /// parseable. A missing or corrupt sidecar is not an error — the resolver
    /// degrades to mangled-name reporting, exactly like the in-process printer.
    fn loadSidecar(gpa: std.mem.Allocator, io: std.Io, binary_path: []const u8) Sidecar {
        const suffix = ".zap-symbols";
        const sidecar_path = std.fmt.allocPrint(gpa, "{s}{s}", .{ binary_path, suffix }) catch
            return .{ .bytes = null, .reader = null };
        defer gpa.free(sidecar_path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, sidecar_path, gpa, .limited(SIDECAR_MAX_BYTES)) catch
            return .{ .bytes = null, .reader = null };
        const reader = zap_symbol_table.Reader.init(bytes) catch {
            gpa.free(bytes);
            return .{ .bytes = null, .reader = null };
        };
        return .{ .bytes = bytes, .reader = reader };
    }

    /// Generous upper bound on a `.zap-symbols` blob; a table is a few dozen
    /// bytes per function, so megabytes is far beyond any real program.
    const SIDECAR_MAX_BYTES: usize = 64 * 1024 * 1024;
};

// ---------------------------------------------------------------------------
// Tests
//
// These exercise the platform-independent surface (name stripping, sidecar
// mapping, missing-sidecar fallback) directly with a hand-built sidecar, so
// they run on any host inside `zig build test` without needing a compiled
// fixture. The full DWARF round-trip against a real stripped binary + dSYM is
// covered by the CLI-spawn integration test (`tools/zap_addr2line_test.zig`),
// which the brief requires go through the `zap` CLI rather than `zir-test`.
// ---------------------------------------------------------------------------

test "stripSymbolUnderscore matches the side-table key convention" {
    if (builtin.object_format == .macho) {
        try std.testing.expectEqualStrings("Demo.deeper__1", stripSymbolUnderscore("_Demo.deeper__1"));
        // Already-stripped names pass through unchanged.
        try std.testing.expectEqualStrings("Demo.deeper__1", stripSymbolUnderscore("Demo.deeper__1"));
    } else {
        // No leading-underscore convention off Mach-O.
        try std.testing.expectEqualStrings("_x", stripSymbolUnderscore("_x"));
    }
}

test "mapToZap resolves a mangled name through a hand-built sidecar" {
    const gpa = std.testing.allocator;

    // Build a sidecar blob with one struct method and one top-level entry.
    var builder = zap_symbol_table.Builder.init(gpa);
    defer builder.deinit();
    try builder.record("Demo.deeper__1", "Demo", "deeper", 1);
    try builder.record("main__1", null, "main", 1);
    const blob = try builder.encode();
    defer gpa.free(blob);

    const reader = try zap_symbol_table.Reader.init(blob);

    // A resolver with only the sidecar populated (no image) is enough to
    // exercise the mapping; `mapToZap` touches only `self.symbols`.
    var resolver: Resolver = .{
        .gpa = gpa,
        .io = std.testing.io,
        .image = undefined,
        .sidecar_bytes = null,
        .symbols = reader,
    };

    const hit = resolver.mapToZap("Demo.deeper__1").?;
    try std.testing.expectEqualStrings("Demo", hit.zap_struct.?);
    try std.testing.expectEqualStrings("deeper", hit.zap_local);
    try std.testing.expectEqual(@as(u32, 1), hit.zap_arity);

    const entry = resolver.mapToZap("main__1").?;
    try std.testing.expect(entry.zap_struct == null);
    try std.testing.expectEqualStrings("main", entry.zap_local);

    // A symbol absent from the table maps to null (caller falls back to
    // mangled).
    try std.testing.expect(resolver.mapToZap("Nope.gone__0") == null);
}

test "mapToZap with no sidecar yields null (mangled fallback)" {
    var resolver: Resolver = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .image = undefined,
        .sidecar_bytes = null,
        .symbols = null,
    };
    try std.testing.expect(!resolver.hasSidecar());
    try std.testing.expect(resolver.mapToZap("Demo.deeper__1") == null);
}
