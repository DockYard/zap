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
//! Zero-allocation, zero-I/O design. The parser operates exclusively on
//! a caller-supplied byte slice; it never allocates and never reads from
//! the filesystem. As a consequence, the `ExtractError` set is small —
//! it contains only the structural failure modes the parser itself can
//! detect.
//!
//! This module is kept after the spike (it is the basis for the Phase
//! 2 runtime contract).

const std = @import("std");
const abi = @import("abi.zig");

pub const ZMEM_MAGIC_LE = abi.ZMEM_MAGIC_LE;
pub const ZapMemoryManagerMetaV1 = abi.ZapMemoryManagerMetaV1;

pub const ExtractError = error{
    /// Section was not found in the object file.
    SectionNotFound,
    /// Section is present but shorter than the v1.0 metadata header.
    SectionTooSmall,
    /// Object file is malformed or truncated.
    InvalidObject,
    /// Object file format is not supported by this parser (e.g., COFF).
    UnsupportedFormat,
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
///     supported (currently: COFF, 32-bit Mach-O, big-endian Mach-O).
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
                // Safe-rewrite of `sh_offset + sh_size > bytes.len`:
                // avoids u64 overflow when malformed input claims a
                // huge offset and/or size.
                if (sh.sh_size > bytes.len or sh.sh_offset > bytes.len - sh.sh_size) {
                    return error.InvalidObject;
                }
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
            if (sh.sh_size > bytes.len or sh.sh_offset > bytes.len - sh.sh_size) {
                return error.InvalidObject;
            }
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
        if (@sizeOf(std.macho.load_command) > bytes.len or
            cursor > bytes.len - @sizeOf(std.macho.load_command))
        {
            return error.InvalidObject;
        }
        var lc: std.macho.load_command = undefined;
        @memcpy(std.mem.asBytes(&lc), bytes[cursor..][0..@sizeOf(std.macho.load_command)]);
        const lc_cmd_raw: u32 = if (swap) @byteSwap(@intFromEnum(lc.cmd)) else @intFromEnum(lc.cmd);
        const lc_size: u32 = if (swap) @byteSwap(lc.cmdsize) else lc.cmdsize;
        if (lc_size < @sizeOf(std.macho.load_command)) return error.InvalidObject;
        if (lc_size > bytes.len or cursor > bytes.len - lc_size) return error.InvalidObject;

        if (lc_cmd_raw == @intFromEnum(std.macho.LC.SEGMENT_64)) {
            // Parse segment_command_64 + its sections.
            if (@sizeOf(std.macho.segment_command_64) > bytes.len or
                cursor > bytes.len - @sizeOf(std.macho.segment_command_64))
            {
                return error.InvalidObject;
            }
            var seg: std.macho.segment_command_64 = undefined;
            @memcpy(std.mem.asBytes(&seg), bytes[cursor..][0..@sizeOf(std.macho.segment_command_64)]);
            const nsects: u32 = if (swap) @byteSwap(seg.nsects) else seg.nsects;
            var sect_off: usize = cursor + @sizeOf(std.macho.segment_command_64);
            var s_i: u32 = 0;
            while (s_i < nsects) : (s_i += 1) {
                if (@sizeOf(std.macho.section_64) > bytes.len or
                    sect_off > bytes.len - @sizeOf(std.macho.section_64))
                {
                    return error.InvalidObject;
                }
                var sect: std.macho.section_64 = undefined;
                @memcpy(std.mem.asBytes(&sect), bytes[sect_off..][0..@sizeOf(std.macho.section_64)]);
                const segname = trimZeros(&sect.segname);
                const sectname = trimZeros(&sect.sectname);

                if (std.mem.eql(u8, segname, "__DATA") and
                    std.mem.eql(u8, sectname, "__zapmem"))
                {
                    const off: u32 = if (swap) @byteSwap(sect.offset) else sect.offset;
                    const sz: u64 = if (swap) @byteSwap(sect.size) else sect.size;
                    if (sz > bytes.len or @as(u64, off) > bytes.len - sz) {
                        return error.InvalidObject;
                    }
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

test "detectFormat: Mach-O 64 BE" {
    const bytes = [_]u8{ 0xFE, 0xED, 0xFA, 0xCF, 0, 0, 0, 0 };
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

test "detectFormat: buffer too small" {
    const bytes = [_]u8{ 0x7F, 'E', 'L' };
    try std.testing.expectEqual(ObjectFormat.unknown, detectFormat(&bytes));
}

// ---------------------------------------------------------------------------
// ELF synthesis helpers.
// ---------------------------------------------------------------------------

/// Layout of the synthesized ELF objects used by the parser tests.
///
/// We pack section headers immediately after the ELF header. The order
/// is fixed:
///
///   index 0 — null section (required by ELF; sh_size = 0)
///   index 1 — `.shstrtab` (string table)
///   index 2 — `.zapmem`   (the section the parser locates)
const elf_strtab = "\x00.shstrtab\x00.zapmem\x00";
const elf_strtab_name_shstrtab: u32 = 1; // offset of ".shstrtab" in strtab
const elf_strtab_name_zapmem: u32 = 11; // offset of ".zapmem"

/// Build a minimal ELF64 LE object file in `buf`. Returns the number of
/// bytes written. The caller is responsible for providing a buffer that
/// is large enough for the requested payload size.
fn synthesizeElf(
    buf: []u8,
    payload: []const u8,
    options: struct {
        omit_zapmem: bool = false,
        truncate_shdr_table: bool = false,
        zapmem_offset_overflow: bool = false,
        shstrndx_overrun: bool = false,
    },
) usize {
    const ehdr_size: u64 = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size: u64 = @sizeOf(std.elf.Elf64_Shdr);
    const shdr_count: u16 = if (options.omit_zapmem) 2 else 3;
    const shdr_table_offset = ehdr_size;
    const strtab_offset = shdr_table_offset + shdr_size * @as(u64, shdr_count);
    const strtab_len: u64 = elf_strtab.len;
    const zapmem_offset = strtab_offset + strtab_len;
    const zapmem_size: u64 = payload.len;
    const total_size = zapmem_offset + zapmem_size;

    // Construct the ELF header.
    var ehdr: std.elf.Elf64_Ehdr = .{
        .e_ident = [_]u8{0} ** 16,
        .e_type = .REL,
        .e_machine = .X86_64,
        .e_version = 1,
        .e_entry = 0,
        .e_phoff = 0,
        .e_shoff = shdr_table_offset,
        .e_flags = 0,
        .e_ehsize = @intCast(ehdr_size),
        .e_phentsize = 0,
        .e_phnum = 0,
        .e_shentsize = @intCast(shdr_size),
        .e_shnum = shdr_count,
        .e_shstrndx = if (options.shstrndx_overrun) 99 else 1,
    };
    ehdr.e_ident[0] = 0x7F;
    ehdr.e_ident[1] = 'E';
    ehdr.e_ident[2] = 'L';
    ehdr.e_ident[3] = 'F';
    ehdr.e_ident[std.elf.EI.CLASS] = std.elf.ELFCLASS64;
    ehdr.e_ident[std.elf.EI.DATA] = std.elf.ELFDATA2LSB;
    ehdr.e_ident[std.elf.EI.VERSION] = 1;
    @memcpy(buf[0..@sizeOf(std.elf.Elf64_Ehdr)], std.mem.asBytes(&ehdr));

    // Section header 0 — null section.
    var sh_null: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    @memcpy(
        buf[shdr_table_offset..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_null),
    );

    // Section header 1 — `.shstrtab`.
    var sh_strtab: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
    sh_strtab.sh_name = elf_strtab_name_shstrtab;
    sh_strtab.sh_type = @intFromEnum(std.elf.SHT.STRTAB);
    sh_strtab.sh_offset = strtab_offset;
    sh_strtab.sh_size = strtab_len;
    @memcpy(
        buf[shdr_table_offset + shdr_size ..][0..@sizeOf(std.elf.Elf64_Shdr)],
        std.mem.asBytes(&sh_strtab),
    );

    if (!options.omit_zapmem) {
        // Section header 2 — `.zapmem`.
        var sh_zap: std.elf.Elf64_Shdr = std.mem.zeroes(std.elf.Elf64_Shdr);
        sh_zap.sh_name = elf_strtab_name_zapmem;
        sh_zap.sh_type = @intFromEnum(std.elf.SHT.PROGBITS);
        sh_zap.sh_flags = std.elf.SHF_ALLOC;
        sh_zap.sh_offset = if (options.zapmem_offset_overflow)
            0xFFFFFFFFFFFFFFFF
        else
            zapmem_offset;
        sh_zap.sh_size = zapmem_size;
        @memcpy(
            buf[shdr_table_offset + shdr_size * 2 ..][0..@sizeOf(std.elf.Elf64_Shdr)],
            std.mem.asBytes(&sh_zap),
        );
    }

    // String table.
    @memcpy(buf[strtab_offset..][0..elf_strtab.len], elf_strtab);

    // Payload.
    if (payload.len > 0) {
        @memcpy(buf[zapmem_offset..][0..payload.len], payload);
    }

    if (options.truncate_shdr_table) {
        // Drop the last few bytes by reporting a shorter total length.
        return @intCast(shdr_table_offset + shdr_size + shdr_size / 2);
    }

    return @intCast(total_size);
}

fn validZapmemPayload() [32]u8 {
    var payload: [32]u8 = undefined;
    var meta: ZapMemoryManagerMetaV1 = .{
        .magic = ZMEM_MAGIC_LE,
        .abi_major = 1,
        .abi_minor = 0,
        .size = 32,
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0,
        .core_vtable_offset = 0,
        .reserved = 0,
    };
    @memcpy(payload[0..], std.mem.asBytes(&meta));
    return payload;
}

test "extractFromElf: round-trips valid section" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeElf(&buf, &payload, .{});
    const result = try extractSection(buf[0..written]);
    try std.testing.expectEqual(@as(usize, payload.len), result.len);
    try std.testing.expectEqualSlices(u8, &payload, result);
}

test "extractFromElf: SectionNotFound when .zapmem absent" {
    var buf: [4096]u8 = undefined;
    const written = synthesizeElf(&buf, &.{}, .{ .omit_zapmem = true });
    try std.testing.expectError(error.SectionNotFound, extractSection(buf[0..written]));
}

test "extractFromElf: SectionTooSmall when payload < 32 bytes" {
    const short_payload = [_]u8{ 1, 2, 3, 4, 5 };
    var buf: [4096]u8 = undefined;
    const written = synthesizeElf(&buf, &short_payload, .{});
    try std.testing.expectError(error.SectionTooSmall, extractSection(buf[0..written]));
}

test "extractFromElf: InvalidObject when zapmem offset+size overflows buffer" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeElf(&buf, &payload, .{ .zapmem_offset_overflow = true });
    try std.testing.expectError(error.InvalidObject, extractSection(buf[0..written]));
}

test "extractFromElf: InvalidObject when shstrndx >= shnum" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeElf(&buf, &payload, .{ .shstrndx_overrun = true });
    try std.testing.expectError(error.InvalidObject, extractSection(buf[0..written]));
}

test "extractFromElf: InvalidObject when section header table truncated" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeElf(&buf, &payload, .{ .truncate_shdr_table = true });
    try std.testing.expectError(error.InvalidObject, extractSection(buf[0..written]));
}

// ---------------------------------------------------------------------------
// Mach-O synthesis helpers.
// ---------------------------------------------------------------------------

const MachoSynthOptions = struct {
    omit_zapmem: bool = false,
    bad_lc_size: bool = false,
    zapmem_offset_overflow: bool = false,
    use_32bit_magic: bool = false,
};

/// Build a minimal Mach-O 64 LE object with one `__DATA` segment that
/// contains the `__zapmem` section.
fn synthesizeMacho(
    buf: []u8,
    payload: []const u8,
    options: MachoSynthOptions,
) usize {
    const mh_size: u32 = @sizeOf(std.macho.mach_header_64);
    const seg_size: u32 = @sizeOf(std.macho.segment_command_64);
    const sect_size: u32 = @sizeOf(std.macho.section_64);
    const nsects: u32 = if (options.omit_zapmem) 0 else 1;
    const total_lc_size: u32 = seg_size + sect_size * nsects;
    const payload_offset: u32 = mh_size + total_lc_size;

    var header: std.macho.mach_header_64 = .{
        .magic = if (options.use_32bit_magic) 0xFEEDFACE else std.macho.MH_MAGIC_64,
        .cputype = 0,
        .cpusubtype = 0,
        .filetype = 1, // OBJECT
        .ncmds = 1,
        .sizeofcmds = total_lc_size,
        .flags = 0,
        .reserved = 0,
    };
    @memcpy(buf[0..mh_size], std.mem.asBytes(&header));

    var seg: std.macho.segment_command_64 = std.mem.zeroes(std.macho.segment_command_64);
    seg.cmd = .SEGMENT_64;
    seg.cmdsize = if (options.bad_lc_size) 4 else total_lc_size;
    @memcpy(seg.segname[0.."__DATA".len], "__DATA");
    seg.nsects = nsects;
    @memcpy(buf[mh_size..][0..seg_size], std.mem.asBytes(&seg));

    if (!options.omit_zapmem) {
        var sect: std.macho.section_64 = std.mem.zeroes(std.macho.section_64);
        @memcpy(sect.sectname[0.."__zapmem".len], "__zapmem");
        @memcpy(sect.segname[0.."__DATA".len], "__DATA");
        sect.offset = if (options.zapmem_offset_overflow) 0xFFFFFFFF else payload_offset;
        sect.size = payload.len;
        @memcpy(buf[mh_size + seg_size ..][0..sect_size], std.mem.asBytes(&sect));
    }

    if (payload.len > 0) {
        @memcpy(buf[payload_offset..][0..payload.len], payload);
    }

    return @intCast(payload_offset + payload.len);
}

test "extractFromMacho: round-trips valid section" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeMacho(&buf, &payload, .{});
    const result = try extractSection(buf[0..written]);
    try std.testing.expectEqual(@as(usize, payload.len), result.len);
    try std.testing.expectEqualSlices(u8, &payload, result);
}

test "extractFromMacho: SectionNotFound when __zapmem absent" {
    var buf: [4096]u8 = undefined;
    const written = synthesizeMacho(&buf, &.{}, .{ .omit_zapmem = true });
    try std.testing.expectError(error.SectionNotFound, extractSection(buf[0..written]));
}

test "extractFromMacho: SectionTooSmall when payload < 32 bytes" {
    const short_payload = [_]u8{ 1, 2, 3, 4 };
    var buf: [4096]u8 = undefined;
    const written = synthesizeMacho(&buf, &short_payload, .{});
    try std.testing.expectError(error.SectionTooSmall, extractSection(buf[0..written]));
}

test "extractFromMacho: InvalidObject when load command size malformed" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeMacho(&buf, &payload, .{ .bad_lc_size = true });
    try std.testing.expectError(error.InvalidObject, extractSection(buf[0..written]));
}

test "extractFromMacho: InvalidObject when section offset overflows" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeMacho(&buf, &payload, .{ .zapmem_offset_overflow = true });
    try std.testing.expectError(error.InvalidObject, extractSection(buf[0..written]));
}

test "extractFromMacho: UnsupportedFormat for 32-bit Mach-O" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeMacho(&buf, &payload, .{ .use_32bit_magic = true });
    try std.testing.expectError(error.UnsupportedFormat, extractSection(buf[0..written]));
}

test "extractFromMacho: buffer too small for mach header" {
    const bytes = [_]u8{ 0xCF, 0xFA, 0xED, 0xFE, 0x00, 0x00 };
    try std.testing.expectError(error.InvalidObject, extractSection(&bytes));
}

test "extractSection: buffer too small to detect format" {
    const bytes = [_]u8{ 0x7F, 'E', 'L' };
    try std.testing.expectError(error.InvalidObject, extractSection(&bytes));
}

test "extractSection: COFF MZ returns UnsupportedFormat" {
    const bytes = [_]u8{ 'M', 'Z', 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnsupportedFormat, extractSection(&bytes));
}

test "extractSection: garbage buffer returns InvalidObject" {
    const bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    try std.testing.expectError(error.InvalidObject, extractSection(&bytes));
}

test "extractSection: COFF without MZ prefix is treated as unknown" {
    // Raw COFF starts with a 16-bit machine type rather than `MZ`. The
    // current detector does not pattern-match those values; it returns
    // `.unknown`, which `extractSection` surfaces as InvalidObject.
    //
    // Document this in a test so a future contributor adding COFF
    // detection updates it deliberately rather than silently changing
    // the observable behavior.
    const bytes = [_]u8{ 0x64, 0x86, 0x00, 0x00, 0x00, 0x00 }; // IMAGE_FILE_MACHINE_AMD64 LE
    try std.testing.expectError(error.InvalidObject, extractSection(&bytes));
}
