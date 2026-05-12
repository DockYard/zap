//! `.zapmem` section parser.
//!
//! Reads a memory manager's compiled object file and extracts the raw
//! bytes of the `.zapmem` metadata section. The bytes returned by
//! `extractSection` are guaranteed to be at least
//! `@sizeOf(ZapMemoryManagerMetaV1)` long on success; the caller is
//! responsible for downstream validation per the Memory Manager ABI
//! v1.0 spec (`docs/memory-manager-abi.md` section 3.5).
//!
//! Implementation notes:
//!   * ELF parsing uses `std.elf` directly. The section is `.zapmem`
//!     with the `SHF_ALLOC` flag, but the parser keys only on section
//!     name (the spec authorizes name-based lookup).
//!   * Mach-O parsing uses `std.macho`. Mach-O section names live
//!     inside segments — the spec writes `__DATA,__zapmem`. The parser
//!     iterates LC_SEGMENT_64 commands and matches `(segname, sectname)`.
//!   * COFF support is a TODO; the parser returns
//!     `error.UnsupportedFormat` for COFF object files for now. The
//!     interface is identical so adding COFF later is purely additive.
//!
//! This module is kept after the spike (it is the basis for the Phase
//! 2 runtime contract).

const std = @import("std");

/// `ZMEM` FourCC magic, little-endian read.
pub const ZMEM_MAGIC_LE: u32 = 0x4D454D5A;

/// `ZapMemoryManagerMetaV1`. Mirrors the spec's struct so callers can
/// reinterpret the parser's returned bytes without depending on a
/// secondary module.
pub const ZapMemoryManagerMetaV1 = extern struct {
    magic: u32,
    abi_major: u16,
    abi_minor: u16,
    size: u16,
    _reserved2: u16,
    desc_count: u32,
    declared_caps: u64,
    core_vtable_offset: u32,
    reserved: u32,
};

comptime {
    if (@sizeOf(ZapMemoryManagerMetaV1) != 32) @compileError(
        "section_parser: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
}

pub const ExtractError = error{
    /// Section was not found in the object file.
    SectionNotFound,
    /// Section is present but shorter than the v1.0 metadata header.
    SectionTooSmall,
    /// Object file is malformed or truncated.
    InvalidObject,
    /// Object file format is not supported by this parser (e.g., COFF).
    UnsupportedFormat,
    OutOfMemory,
    /// I/O error while reading the input buffer.
    ReadFailed,
};

/// Object file format detected from the first bytes of the buffer.
pub const ObjectFormat = enum {
    elf,
    macho,
    coff,
    unknown,
};

/// Detect the object format from the leading bytes of `bytes`.
pub fn detectFormat(bytes: []const u8) ObjectFormat {
    if (bytes.len < 4) return .unknown;
    // ELF: 0x7F 'E' 'L' 'F'
    if (bytes[0] == 0x7F and bytes[1] == 'E' and bytes[2] == 'L' and bytes[3] == 'F') {
        return .elf;
    }
    // Mach-O 64-bit LE: 0xFEEDFACF
    // Mach-O 64-bit BE: 0xCFFAEDFE
    // Mach-O 32-bit LE: 0xFEEDFACE
    // Mach-O 32-bit BE: 0xCEFAEDFE
    // Fat: 0xCAFEBABE (big-endian)
    const m0 = std.mem.readInt(u32, bytes[0..4], .little);
    if (m0 == 0xFEEDFACF or m0 == 0xCFFAEDFE or m0 == 0xFEEDFACE or m0 == 0xCEFAEDFE) {
        return .macho;
    }
    const m0_be = std.mem.readInt(u32, bytes[0..4], .big);
    if (m0_be == 0xCAFEBABE) return .macho; // fat
    // COFF/PE: MZ header for PE; raw COFF starts with machine bytes
    if (bytes[0] == 'M' and bytes[1] == 'Z') return .coff;
    return .unknown;
}

/// Extract the `.zapmem` section content from a complete object-file
/// byte buffer. Returns a slice into the original buffer (no allocation
/// is performed) on success.
///
/// On failure returns one of:
///   * `error.SectionNotFound` — the object exists and is parseable,
///     but contains no `.zapmem` section.
///   * `error.SectionTooSmall` — the section exists but is smaller
///     than `@sizeOf(ZapMemoryManagerMetaV1)` (32 bytes). The Zap
///     compiler must surface a `manager defect` diagnostic in this
///     case.
///   * `error.UnsupportedFormat` — the object file format is not yet
///     supported (currently: COFF).
///   * `error.InvalidObject` — the object header is malformed.
pub fn extractSection(bytes: []const u8) ExtractError![]const u8 {
    return switch (detectFormat(bytes)) {
        .elf => extractFromElf(bytes),
        .macho => extractFromMacho(bytes),
        .coff => error.UnsupportedFormat,
        .unknown => error.InvalidObject,
    };
}

/// ELF-specific extraction. Parses the section header table and locates
/// the section named `.zapmem`.
fn extractFromElf(bytes: []const u8) ExtractError![]const u8 {
    var hdr_reader = std.Io.Reader.fixed(bytes);
    const header = std.elf.Header.read(&hdr_reader) catch return error.InvalidObject;

    if (header.shnum == 0) return error.SectionNotFound;
    if (header.shstrndx >= header.shnum) return error.InvalidObject;

    // Walk the section table once to find the shstrtab header, then
    // again to find `.zapmem`. We could collect headers into an array
    // but the table is small enough that two passes is cheaper than the
    // allocation.
    const shstrtab = blk: {
        var it = header.iterateSectionHeadersBuffer(bytes);
        var idx: u32 = 0;
        while (true) {
            const maybe = it.next() catch return error.InvalidObject;
            const sh = maybe orelse return error.InvalidObject;
            if (idx == header.shstrndx) {
                if (sh.sh_offset + sh.sh_size > bytes.len) return error.InvalidObject;
                break :blk bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)];
            }
            idx += 1;
        }
    };

    var it = header.iterateSectionHeadersBuffer(bytes);
    while (true) {
        const maybe = it.next() catch return error.InvalidObject;
        const sh = maybe orelse break;
        const name = sectionName(shstrtab, sh.sh_name) orelse continue;
        if (std.mem.eql(u8, name, ".zapmem")) {
            if (sh.sh_offset + sh.sh_size > bytes.len) return error.InvalidObject;
            const section = bytes[@intCast(sh.sh_offset)..][0..@intCast(sh.sh_size)];
            if (section.len < @sizeOf(ZapMemoryManagerMetaV1)) return error.SectionTooSmall;
            return section;
        }
    }
    return error.SectionNotFound;
}

fn sectionName(shstrtab: []const u8, name_offset: u32) ?[]const u8 {
    if (name_offset >= shstrtab.len) return null;
    const start: usize = name_offset;
    var end: usize = start;
    while (end < shstrtab.len and shstrtab[end] != 0) : (end += 1) {}
    return shstrtab[start..end];
}

/// Mach-O extraction. The spec's section name is `__DATA,__zapmem`:
/// segment `__DATA`, section `__zapmem`. The Mach-O `Section64` struct
/// fixes both names to 16-byte zero-padded fields.
fn extractFromMacho(bytes: []const u8) ExtractError![]const u8 {
    if (bytes.len < @sizeOf(std.macho.mach_header_64)) return error.InvalidObject;
    var header: std.macho.mach_header_64 = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(std.macho.mach_header_64)]);
    if (header.magic != std.macho.MH_MAGIC_64 and header.magic != std.macho.MH_CIGAM_64) {
        // 32-bit Mach-O is out of scope for the v1.0 supported targets
        // (all 64-bit per ABI Appendix C). Defer until a 32-bit target
        // is added.
        return error.UnsupportedFormat;
    }
    const swap = header.magic == std.macho.MH_CIGAM_64;
    var ncmds: u32 = if (swap) @byteSwap(header.ncmds) else header.ncmds;

    var cursor: usize = @sizeOf(std.macho.mach_header_64);
    while (ncmds > 0) : (ncmds -= 1) {
        if (cursor + @sizeOf(std.macho.load_command) > bytes.len) return error.InvalidObject;
        var lc: std.macho.load_command = undefined;
        @memcpy(std.mem.asBytes(&lc), bytes[cursor..][0..@sizeOf(std.macho.load_command)]);
        const lc_cmd_raw: u32 = if (swap) @byteSwap(@intFromEnum(lc.cmd)) else @intFromEnum(lc.cmd);
        const lc_size: u32 = if (swap) @byteSwap(lc.cmdsize) else lc.cmdsize;
        if (lc_size < @sizeOf(std.macho.load_command)) return error.InvalidObject;
        if (cursor + lc_size > bytes.len) return error.InvalidObject;

        if (lc_cmd_raw == @intFromEnum(std.macho.LC.SEGMENT_64)) {
            // Parse segment_command_64 + its sections.
            if (cursor + @sizeOf(std.macho.segment_command_64) > bytes.len) return error.InvalidObject;
            var seg: std.macho.segment_command_64 = undefined;
            @memcpy(std.mem.asBytes(&seg), bytes[cursor..][0..@sizeOf(std.macho.segment_command_64)]);
            const nsects: u32 = if (swap) @byteSwap(seg.nsects) else seg.nsects;
            var sect_off: usize = cursor + @sizeOf(std.macho.segment_command_64);
            var s_i: u32 = 0;
            while (s_i < nsects) : (s_i += 1) {
                if (sect_off + @sizeOf(std.macho.section_64) > bytes.len) return error.InvalidObject;
                var sect: std.macho.section_64 = undefined;
                @memcpy(std.mem.asBytes(&sect), bytes[sect_off..][0..@sizeOf(std.macho.section_64)]);
                const segname = trimZeros(&sect.segname);
                const sectname = trimZeros(&sect.sectname);

                if (std.mem.eql(u8, segname, "__DATA") and
                    std.mem.eql(u8, sectname, "__zapmem"))
                {
                    const off: u32 = if (swap) @byteSwap(sect.offset) else sect.offset;
                    const sz: u64 = if (swap) @byteSwap(sect.size) else sect.size;
                    if (@as(u64, off) + sz > bytes.len) return error.InvalidObject;
                    const section = bytes[off..][0..@as(usize, @intCast(sz))];
                    if (section.len < @sizeOf(ZapMemoryManagerMetaV1)) return error.SectionTooSmall;
                    return section;
                }
                sect_off += @sizeOf(std.macho.section_64);
            }
        }

        cursor += lc_size;
    }
    return error.SectionNotFound;
}

fn trimZeros(name: []const u8) []const u8 {
    var end: usize = name.len;
    while (end > 0 and name[end - 1] == 0) : (end -= 1) {}
    return name[0..end];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "detectFormat: ELF magic" {
    const bytes = [_]u8{ 0x7F, 'E', 'L', 'F', 0, 0, 0, 0 };
    try std.testing.expectEqual(ObjectFormat.elf, detectFormat(&bytes));
}

test "detectFormat: Mach-O 64 LE" {
    const bytes = [_]u8{ 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 };
    try std.testing.expectEqual(ObjectFormat.macho, detectFormat(&bytes));
}

test "detectFormat: COFF MZ" {
    const bytes = [_]u8{ 'M', 'Z', 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(ObjectFormat.coff, detectFormat(&bytes));
}

test "detectFormat: garbage" {
    const bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    try std.testing.expectEqual(ObjectFormat.unknown, detectFormat(&bytes));
}
