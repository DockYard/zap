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
    wasm,
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
    // WebAssembly object/module: the 4-byte magic `\0asm` (0x00 0x61
    // 0x73 0x6D) followed by a 4-byte version. `zig build-obj -target
    // wasm32-wasi` emits a wasm object with this header; custom sections
    // (the `.zapmem` metadata) live inside it.
    if (bytes[0] == 0x00 and bytes[1] == 0x61 and bytes[2] == 0x73 and bytes[3] == 0x6D) {
        return .wasm;
    }
    // COFF/PE: a PE *image* starts with the `MZ` DOS stub; a raw COFF
    // *object* (what `zig build-obj -target *-windows-*` emits, and what
    // the manager-object compile produces) has no `MZ` stub — it begins
    // directly with the 20-byte COFF file header whose first u16 is the
    // machine type. We recognise both: `MZ` for images, and a known
    // COFF machine word for raw objects. The machine match is gated by a
    // header-plausibility check (`size_of_optional_header == 0`, which is
    // mandatory for object files per PE/COFF §3.3) so arbitrary data that
    // merely happens to start with a machine-type word is not misread as
    // COFF.
    if (bytes[0] == 'M' and bytes[1] == 'Z') return .coff;
    if (looksLikeRawCoffObject(bytes)) return .coff;
    return .unknown;
}

/// Known COFF machine-type words (PE/COFF §3.3.1, `IMAGE_FILE_MACHINE_*`)
/// for the 64- and 32-bit targets Zig can emit Windows objects for.
const COFF_MACHINE_AMD64: u16 = 0x8664;
const COFF_MACHINE_ARM64: u16 = 0xaa64;
const COFF_MACHINE_I386: u16 = 0x14c;

/// Heuristic discriminator for a raw COFF *object* file (no `MZ` stub).
/// Reads the leading 20-byte COFF file header and requires:
///   * a recognised machine word, and
///   * `size_of_optional_header == 0` — objects never carry an optional
///     header (it is image-only), so a non-zero value here means the
///     buffer is not a raw COFF object.
/// This is a detection gate only; full structural validation (section
/// table bounds, etc.) happens in `extractFromCoff`.
fn looksLikeRawCoffObject(bytes: []const u8) bool {
    if (bytes.len < @sizeOf(std.coff.Header)) return false;
    const machine = std.mem.readInt(u16, bytes[0..2], .little);
    const is_known_machine = machine == COFF_MACHINE_AMD64 or
        machine == COFF_MACHINE_ARM64 or
        machine == COFF_MACHINE_I386;
    if (!is_known_machine) return false;
    // `size_of_optional_header` is the u16 at offset 16 of the header.
    const size_of_optional_header = std.mem.readInt(u16, bytes[16..18], .little);
    return size_of_optional_header == 0;
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
        .coff => extractFromCoff(bytes),
        .wasm => extractFromWasm(bytes),
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

/// Read an unsigned LEB128 integer from `bytes` starting at `cursor.*`,
/// advancing the cursor past the encoded bytes. Returns null on a
/// truncated or over-long encoding (a `usize`-bounded value cannot
/// exceed 10 groups). WebAssembly section sizes and name lengths are
/// ULEB128-encoded.
fn readUleb128(bytes: []const u8, cursor: *usize) ?usize {
    var result: usize = 0;
    var shift: u6 = 0;
    var produced: usize = 0;
    while (true) {
        if (cursor.* >= bytes.len) return null;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        produced += 1;
        if (produced > 10) return null; // beyond a 64-bit value
        const low: usize = byte & 0x7F;
        // Guard the shift against overflow before applying it.
        if (shift >= @bitSizeOf(usize) and low != 0) return null;
        if (shift < @bitSizeOf(usize)) {
            result |= low << shift;
        }
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}

/// Skip a LEB128-encoded integer (signed or unsigned — the
/// continuation-bit framing is identical) at `cursor.*`, advancing past
/// it. Returns null on truncation or an over-long (> 10-byte) encoding.
fn skipLeb(bytes: []const u8, cursor: *usize) ?void {
    var produced: usize = 0;
    while (true) {
        if (cursor.* >= bytes.len) return null;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        produced += 1;
        if (produced > 10) return null;
        if (byte & 0x80 == 0) break;
    }
    return {};
}

/// WebAssembly extraction. In a *relocatable* wasm object (what `zig
/// build-obj -target wasm32-*` emits, and what the manager compile
/// produces), the `.zapmem` data emitted via `linksection(".zapmem")` is
/// NOT a top-level custom section — it is a **data segment** in the DATA
/// section, and `.zapmem` appears only as that segment's NAME in the
/// `linking` custom section's `WASM_SEGMENT_INFO` subsection. So
/// extraction is a two-step join:
///
///   1. Parse the DATA section (id 11) into its ordered segments,
///      recording each segment's raw-bytes `[start, len)` in the buffer.
///   2. Parse the `linking` custom section's `WASM_SEGMENT_INFO`
///      subsection (id 5) — a parallel-ordered list of `(name, align,
///      flags)` — to find the index whose name is `.zapmem`.
///
/// The DATA-segment at that index is the `.zapmem` payload.
///
/// A wasm binary is an 8-byte header (`\0asm` + u32 version) followed by
/// sections `id:1byte, size:ULEB, payload`. Custom sections (id 0)
/// additionally begin with `name_len:ULEB, name`.
fn extractFromWasm(bytes: []const u8) ExtractError![]const u8 {
    const wasm_header_len: usize = 8;
    if (bytes.len < wasm_header_len) return error.InvalidObject;

    var data_section: ?[]const u8 = null;
    var linking_content: ?[]const u8 = null;

    var cursor: usize = wasm_header_len;
    while (cursor < bytes.len) {
        const section_id = bytes[cursor];
        cursor += 1;
        const section_size = readUleb128(bytes, &cursor) orelse return error.InvalidObject;
        if (section_size > bytes.len or cursor > bytes.len - section_size) {
            return error.InvalidObject;
        }
        const payload_start = cursor;
        const payload_end = cursor + section_size;
        cursor = payload_end;

        if (section_id == 11) {
            // DATA section.
            data_section = bytes[payload_start..payload_end];
        } else if (section_id == 0) {
            var name_cursor = payload_start;
            const name_len = readUleb128(bytes, &name_cursor) orelse return error.InvalidObject;
            if (name_len > section_size or name_cursor > payload_end - name_len) {
                return error.InvalidObject;
            }
            const name = bytes[name_cursor .. name_cursor + name_len];
            if (std.mem.eql(u8, name, "linking")) {
                linking_content = bytes[name_cursor + name_len .. payload_end];
            }
        }
    }

    const data = data_section orelse return error.SectionNotFound;
    const linking = linking_content orelse return error.SectionNotFound;

    // Find the `.zapmem` segment index in WASM_SEGMENT_INFO.
    const zapmem_index = wasmSegmentIndexByName(linking, ".zapmem") orelse
        return error.SectionNotFound;

    // Walk the DATA section to the segment at `zapmem_index` and return
    // its bytes.
    return wasmDataSegmentBytes(data, zapmem_index);
}

/// Scan the `linking` section content for the `WASM_SEGMENT_INFO`
/// subsection (id 5) and return the index of the segment named `want`,
/// or null. The subsection content is `count:ULEB` then `count` entries
/// of `name_len:ULEB, name, alignment:ULEB, flags:ULEB`.
fn wasmSegmentIndexByName(linking: []const u8, want: []const u8) ?usize {
    const WASM_SEGMENT_INFO: u8 = 5;
    var i: usize = 0;
    _ = readUleb128(linking, &i) orelse return null; // version
    while (i < linking.len) {
        const sub_id = linking[i];
        i += 1;
        const sub_size = readUleb128(linking, &i) orelse return null;
        if (sub_size > linking.len or i > linking.len - sub_size) return null;
        const sub_end = i + sub_size;
        if (sub_id == WASM_SEGMENT_INFO) {
            var p = i;
            const count = readUleb128(linking, &p) orelse return null;
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                const name_len = readUleb128(linking, &p) orelse return null;
                if (name_len > sub_end or p > sub_end - name_len) return null;
                const name = linking[p .. p + name_len];
                p += name_len;
                _ = readUleb128(linking, &p) orelse return null; // alignment
                _ = readUleb128(linking, &p) orelse return null; // flags
                if (std.mem.eql(u8, name, want)) return idx;
            }
            return null; // segment-info present but name absent
        }
        i = sub_end;
    }
    return null;
}

/// Walk the DATA section content to the segment at ordinal `target_index`
/// and return its raw byte payload. The DATA section is `count:ULEB`
/// then `count` segments. Each segment is:
///   flags:ULEB
///   (flags==2)            ⇒ memidx:ULEB
///   (flags==0 or flags==2) ⇒ offset init-expr (instrs ending in 0x0b)
///   size:ULEB
///   <size bytes>
/// Passive segments (flags==1) carry no memidx/offset.
fn wasmDataSegmentBytes(data: []const u8, target_index: usize) ExtractError![]const u8 {
    var i: usize = 0;
    const count = readUleb128(data, &i) orelse return error.InvalidObject;
    if (target_index >= count) return error.InvalidObject;

    var seg: usize = 0;
    while (seg < count) : (seg += 1) {
        const flags = readUleb128(data, &i) orelse return error.InvalidObject;
        if (flags == 2) {
            _ = readUleb128(data, &i) orelse return error.InvalidObject; // memidx
        }
        if (flags == 0 or flags == 2) {
            // Offset init-expr. Decode each instruction and skip its
            // immediate operand precisely, then expect the `end` opcode
            // (0x0b). Decoding (rather than scanning for a raw 0x0b)
            // avoids mistaking a LEB immediate byte that happens to
            // equal 0x0b (e.g. a constant offset of 11) for the
            // terminator. For relocatable objects the expression is
            // typically `i32.const <reloc> end`, but `global.get` and
            // 64-bit constants are handled too.
            while (true) {
                if (i >= data.len) return error.InvalidObject;
                const op = data[i];
                i += 1;
                switch (op) {
                    0x0b => break, // end
                    0x41, 0x42 => { // i32.const (SLEB32) / i64.const (SLEB64)
                        skipLeb(data, &i) orelse return error.InvalidObject;
                    },
                    0x23 => { // global.get (ULEB global index)
                        skipLeb(data, &i) orelse return error.InvalidObject;
                    },
                    0x43 => i += 4, // f32.const
                    0x44 => i += 8, // f64.const
                    else => return error.InvalidObject, // unexpected opcode in a data offset
                }
                if (i > data.len) return error.InvalidObject;
            }
        }
        const size = readUleb128(data, &i) orelse return error.InvalidObject;
        if (size > data.len or i > data.len - size) return error.InvalidObject;
        const seg_bytes = data[i .. i + size];
        i += size;
        if (seg == target_index) {
            if (seg_bytes.len < @sizeOf(ZapMemoryManagerMetaV1)) return error.SectionTooSmall;
            return seg_bytes;
        }
    }
    return error.SectionNotFound;
}

/// COFF extraction. The spec's section name on Windows is `.zapmem`
/// (mirrors the ELF name; see the manager-side `SECTION_NAME` switch in
/// `src/memory/<backend>/manager.zig`). Zig emits a raw COFF *object*
/// (no `MZ`/PE image wrapper), so the layout is:
///
///   [0]                COFF file header (20 bytes,`std.coff.Header`)
///   [20]               section table (`number_of_sections` ×
///                      `std.coff.SectionHeader`, 40 bytes each, because
///                      `size_of_optional_header` is 0 for objects)
///   [pointer_to_raw_data]  per-section raw bytes
///   [pointer_to_symbol_table]            symbol table (18 bytes/entry)
///   [pointer_to_symbol_table + nsyms*18] string table (4-byte size + names)
///
/// Section content is located by `pointer_to_raw_data` + `size_of_raw_data`.
/// We deliberately do NOT use `virtual_size`: for object files that field
/// is typically 0 (it is meaningful only in a linked image), so
/// `std.coff.Coff.getSectionData` — which keys on `virtual_size` — would
/// return an empty slice. `size_of_raw_data` is the on-disk section length.
///
/// Long section names (> 8 bytes) are stored as `/<decimal-offset>` into
/// the string table; `.zapmem` is 7 bytes so it is always inline, but the
/// parser resolves the string-table form too for robustness.
fn extractFromCoff(bytes: []const u8) ExtractError![]const u8 {
    if (bytes.len < @sizeOf(std.coff.Header)) return error.InvalidObject;

    var header: std.coff.Header = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(std.coff.Header)]);

    // Object files carry no optional header; reject a non-zero size as
    // malformed (the detector already gates on this, but `extractSection`
    // can be reached with the `MZ`-image path too — guard regardless).
    if (header.size_of_optional_header != 0) return error.UnsupportedFormat;

    const section_table_offset: usize =
        @as(usize, @sizeOf(std.coff.Header)) + header.size_of_optional_header;
    const section_header_size: usize = @sizeOf(std.coff.SectionHeader); // 40
    const section_count: usize = header.number_of_sections;

    // Bounds-check the whole section table up front (overflow-safe).
    const section_table_bytes = std.math.mul(usize, section_count, section_header_size) catch
        return error.InvalidObject;
    if (section_table_bytes > bytes.len or section_table_offset > bytes.len - section_table_bytes) {
        return error.InvalidObject;
    }

    // Resolve the string table lazily — only needed for long names.
    // Layout: `pointer_to_symbol_table + number_of_symbols*18`, first 4
    // bytes are the total size (inclusive of those 4 bytes).
    const string_table: ?[]const u8 = coffStringTable(bytes, header);

    var section_index: usize = 0;
    while (section_index < section_count) : (section_index += 1) {
        const sh_offset = section_table_offset + section_index * section_header_size;
        var sh: std.coff.SectionHeader = undefined;
        @memcpy(std.mem.asBytes(&sh), bytes[sh_offset..][0..section_header_size]);

        const name = coffSectionName(&sh, string_table) orelse continue;
        if (!std.mem.eql(u8, name, ".zapmem")) continue;

        const raw_offset: usize = sh.pointer_to_raw_data;
        const raw_size: usize = sh.size_of_raw_data;
        // A `.zapmem` section with no on-disk bytes cannot carry the
        // metadata header; treat as too-small rather than not-found so
        // the caller emits the right diagnostic.
        if (raw_size == 0) return error.SectionTooSmall;
        if (raw_size > bytes.len or raw_offset > bytes.len - raw_size) {
            return error.InvalidObject;
        }
        const section = bytes[raw_offset..][0..raw_size];
        if (section.len < @sizeOf(ZapMemoryManagerMetaV1)) return error.SectionTooSmall;
        return section;
    }
    return error.SectionNotFound;
}

/// Locate the COFF string table (4-byte little-endian size prefix
/// followed by NUL-terminated names). Returns null when no symbol table
/// is present (then there is no string table) or when the declared size
/// overflows the buffer. The returned slice includes the 4-byte size
/// prefix, matching the offset convention used by section/symbol names
/// (offsets are measured from the start of the string table, and offsets
/// 0..3 alias the size field, which real names never use).
fn coffStringTable(bytes: []const u8, header: std.coff.Header) ?[]const u8 {
    if (header.pointer_to_symbol_table == 0) return null;
    const symbol_stride: usize = 18; // std.coff.Symbol.sizeOf()
    const symtab_offset: usize = header.pointer_to_symbol_table;
    const symtab_bytes = std.math.mul(usize, header.number_of_symbols, symbol_stride) catch
        return null;
    const strtab_offset = std.math.add(usize, symtab_offset, symtab_bytes) catch return null;
    if (strtab_offset + 4 > bytes.len) return null;
    const declared_size = std.mem.readInt(u32, bytes[strtab_offset..][0..4], .little);
    if (declared_size < 4) return null;
    if (@as(usize, declared_size) > bytes.len - strtab_offset) return null;
    return bytes[strtab_offset..][0..@as(usize, declared_size)];
}

/// Resolve a COFF section name: inline (8-byte field, NUL-padded) or, for
/// names longer than 8 bytes, `/<decimal-offset>` into the string table.
fn coffSectionName(
    section_header: *const std.coff.SectionHeader,
    string_table: ?[]const u8,
) ?[]const u8 {
    if (section_header.name[0] != '/') {
        const len = std.mem.indexOfScalar(u8, &section_header.name, 0) orelse section_header.name.len;
        return section_header.name[0..len];
    }
    // Long name: `/<decimal>` references an offset into the string table.
    const strtab = string_table orelse return null;
    const digits_len = std.mem.indexOfScalar(u8, section_header.name[1..], 0) orelse
        (section_header.name.len - 1);
    const offset = std.fmt.parseInt(u32, section_header.name[1 .. 1 + digits_len], 10) catch return null;
    return coffStringAt(strtab, offset);
}

/// Read a NUL-terminated name from the COFF string table at `offset`
/// (offset measured from the start of the table, including its 4-byte
/// size prefix).
fn coffStringAt(string_table: []const u8, offset: u32) ?[]const u8 {
    if (offset >= string_table.len) return null;
    const start: usize = offset;
    var end: usize = start;
    while (end < string_table.len and string_table[end] != 0) : (end += 1) {}
    return string_table[start..end];
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

test "extractSection: COFF MZ stub too short to be a COFF object" {
    // A bare `MZ` DOS stub with no following COFF header is detected as
    // `.coff` but is shorter than the 20-byte file header, so the COFF
    // reader rejects it as a malformed object.
    const bytes = [_]u8{ 'M', 'Z', 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidObject, extractSection(&bytes));
}

test "extractSection: garbage buffer returns InvalidObject" {
    const bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };
    try std.testing.expectError(error.InvalidObject, extractSection(&bytes));
}

test "detectFormat: raw COFF object recognised by machine word" {
    // A raw COFF object (no `MZ`) begins with the 20-byte file header
    // whose first u16 is the machine type. With a recognised machine
    // (AMD64) and `size_of_optional_header == 0`, the detector reports
    // `.coff`.
    var header_bytes = [_]u8{0} ** @sizeOf(std.coff.Header);
    std.mem.writeInt(u16, header_bytes[0..2], COFF_MACHINE_AMD64, .little);
    // size_of_optional_header (offset 16) already 0.
    try std.testing.expectEqual(ObjectFormat.coff, detectFormat(&header_bytes));
}

test "detectFormat: raw COFF rejected when optional header size nonzero" {
    // A non-zero optional-header size is image-only; a raw object never
    // sets it, so a machine-word match with a non-zero value is NOT
    // treated as a COFF object (guards against false positives).
    var header_bytes = [_]u8{0} ** @sizeOf(std.coff.Header);
    std.mem.writeInt(u16, header_bytes[0..2], COFF_MACHINE_AMD64, .little);
    std.mem.writeInt(u16, header_bytes[16..18], 0xE0, .little); // PE32+ optional header
    try std.testing.expectEqual(ObjectFormat.unknown, detectFormat(&header_bytes));
}

test "detectFormat: short raw-COFF-looking buffer is unknown" {
    // Only the machine word, not a full header — cannot be a COFF object.
    const bytes = [_]u8{ 0x64, 0x86, 0x00, 0x00, 0x00, 0x00 }; // IMAGE_FILE_MACHINE_AMD64 LE
    try std.testing.expectEqual(ObjectFormat.unknown, detectFormat(&bytes));
}

// ---------------------------------------------------------------------------
// COFF synthesis helpers.
// ---------------------------------------------------------------------------

const CoffSynthOptions = struct {
    omit_zapmem: bool = false,
    /// Emit `.zapmem` with a 0-byte `size_of_raw_data`.
    zero_raw_size: bool = false,
    /// Make `pointer_to_raw_data` + `size_of_raw_data` overflow the buffer.
    raw_offset_overflow: bool = false,
    /// Store the section name via the `/<offset>` long-name form in the
    /// string table instead of inline (exercises `coffSectionName`'s
    /// string-table path even though `.zapmem` fits inline).
    long_name_form: bool = false,
};

/// Build a minimal raw COFF (no `MZ` stub) AMD64 object with a single
/// `.zapmem` section. Layout matches what `zig build-obj -target
/// x86_64-windows-gnu` emits: 20-byte header, 40-byte section header(s),
/// raw section bytes, then (for the long-name case) a symbol table +
/// string table. Returns the number of bytes written.
fn synthesizeCoff(
    buf: []u8,
    payload: []const u8,
    options: CoffSynthOptions,
) usize {
    const header_size: usize = @sizeOf(std.coff.Header); // 20
    const section_header_size: usize = @sizeOf(std.coff.SectionHeader); // 40
    const section_count: usize = if (options.omit_zapmem) 0 else 1;

    const section_table_offset = header_size;
    const raw_offset = section_table_offset + section_header_size * section_count;
    const raw_size: usize = if (options.zero_raw_size) 0 else payload.len;
    const after_raw = raw_offset + raw_size;

    // Long-name form needs a symbol table (we emit zero symbols) followed
    // by a string table that contains the `.zapmem` name.
    const symtab_offset = after_raw;
    const string_table_name = ".zapmem\x00";
    const string_table_total: usize = 4 + string_table_name.len; // size prefix + name
    const string_name_offset: u32 = 4; // first byte after the 4-byte size

    var total: usize = after_raw;

    // ---- COFF file header ----
    @memset(buf[0..header_size], 0);
    std.mem.writeInt(u16, buf[0..2], COFF_MACHINE_AMD64, .little); // machine
    std.mem.writeInt(u16, buf[2..4], @intCast(section_count), .little); // number_of_sections
    // size_of_optional_header (offset 16) = 0 already.
    if (options.long_name_form) {
        std.mem.writeInt(u32, buf[8..12], @intCast(symtab_offset), .little); // pointer_to_symbol_table
        std.mem.writeInt(u32, buf[12..16], 0, .little); // number_of_symbols = 0
        total = symtab_offset + string_table_total;
    }

    // ---- section header(s) ----
    if (!options.omit_zapmem) {
        const sh_off = section_table_offset;
        @memset(buf[sh_off..][0..section_header_size], 0);
        if (options.long_name_form) {
            // `/<decimal offset>` into the string table.
            const long = std.fmt.bufPrint(buf[sh_off..][0..8], "/{d}", .{string_name_offset}) catch unreachable;
            // bufPrint wrote the digits; zero-pad the rest of the 8-byte field.
            for (buf[sh_off + long.len .. sh_off + 8]) |*b| b.* = 0;
        } else {
            @memcpy(buf[sh_off..][0..".zapmem".len], ".zapmem");
        }
        // virtual_size (offset 8) intentionally 0 — objects leave it 0.
        std.mem.writeInt(u32, buf[sh_off + 16 ..][0..4], @intCast(raw_size), .little); // size_of_raw_data
        const stored_raw_offset: u32 = if (options.raw_offset_overflow) 0xFFFFFFFF else @intCast(raw_offset);
        std.mem.writeInt(u32, buf[sh_off + 20 ..][0..4], stored_raw_offset, .little); // pointer_to_raw_data
    }

    // ---- raw section bytes ----
    if (raw_size > 0) {
        @memcpy(buf[raw_offset..][0..payload.len], payload);
    }

    // ---- string table (long-name form only) ----
    if (options.long_name_form) {
        std.mem.writeInt(u32, buf[symtab_offset..][0..4], @intCast(string_table_total), .little);
        @memcpy(buf[symtab_offset + 4 ..][0..string_table_name.len], string_table_name);
    }

    return total;
}

test "extractFromCoff: round-trips valid section (inline name)" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeCoff(&buf, &payload, .{});
    const result = try extractSection(buf[0..written]);
    try std.testing.expectEqual(@as(usize, payload.len), result.len);
    try std.testing.expectEqualSlices(u8, &payload, result);
}

test "extractFromCoff: round-trips valid section (long name via string table)" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeCoff(&buf, &payload, .{ .long_name_form = true });
    const result = try extractSection(buf[0..written]);
    try std.testing.expectEqual(@as(usize, payload.len), result.len);
    try std.testing.expectEqualSlices(u8, &payload, result);
}

test "extractFromCoff: SectionNotFound when .zapmem absent" {
    var buf: [4096]u8 = undefined;
    const written = synthesizeCoff(&buf, &.{}, .{ .omit_zapmem = true });
    try std.testing.expectError(error.SectionNotFound, extractSection(buf[0..written]));
}

test "extractFromCoff: SectionTooSmall when payload < 32 bytes" {
    const short_payload = [_]u8{ 1, 2, 3, 4, 5 };
    var buf: [4096]u8 = undefined;
    const written = synthesizeCoff(&buf, &short_payload, .{});
    try std.testing.expectError(error.SectionTooSmall, extractSection(buf[0..written]));
}

test "extractFromCoff: SectionTooSmall when size_of_raw_data is zero" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeCoff(&buf, &payload, .{ .zero_raw_size = true });
    try std.testing.expectError(error.SectionTooSmall, extractSection(buf[0..written]));
}

test "extractFromCoff: InvalidObject when raw offset+size overflows buffer" {
    const payload = validZapmemPayload();
    var buf: [4096]u8 = undefined;
    const written = synthesizeCoff(&buf, &payload, .{ .raw_offset_overflow = true });
    try std.testing.expectError(error.InvalidObject, extractSection(buf[0..written]));
}

test "extractFromCoff: InvalidObject when section count overruns buffer" {
    // A header that claims many sections but a tiny buffer must be
    // rejected by the up-front section-table bounds check.
    var buf = [_]u8{0} ** @sizeOf(std.coff.Header);
    std.mem.writeInt(u16, buf[0..2], COFF_MACHINE_AMD64, .little);
    std.mem.writeInt(u16, buf[2..4], 100, .little); // 100 sections, no room
    try std.testing.expectError(error.InvalidObject, extractSection(&buf));
}
