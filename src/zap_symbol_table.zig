//! Reversible mangled-symbol ↔ Zap-symbol side table.
//!
//! Phase 0 deliverable of the Zap error-system roadmap
//! (`docs/error-system-research-brief.md` §VIII Phase 0). Maps every
//! Zig-mangled symbol emitted by the ZIR backend back to its
//! authoritative Zap struct + function + arity. Consumed by the
//! Phase-2 crash printer (so the async-signal-safe stack walker can
//! print `IO.puts/1` instead of `IO.puts__1`) and by external tooling
//! (`zap-addr2line`, debugger pretty-printers, profiler post-mortems).
//!
//! Two reversibility requirements drive the design:
//!
//! 1. **Symbolize.** Given a mangled name produced by the linker
//!    (typically `<Struct>.<local_name>` for nested functions or
//!    `main` for the entry point), the consumer must recover the
//!    Zap-qualified name. The table is built keyed by mangled
//!    string, so lookup is O(1) after one hashmap construction.
//!
//! 2. **De-symbolize.** Given a Zap-qualified name (e.g. for a
//!    `where breakpoint` request from a debugger plugin), the
//!    consumer must recover the mangled name. We persist the
//!    Zap → mangled direction in the same table so a single load
//!    serves both queries — there is no second source of truth to
//!    drift.
//!
//! The persisted format is a small, fixed-layout binary blob so it
//! can be (a) written to a sidecar file alongside the artifact and
//! (b) embedded as a `linksection("__DATA,__zap_symbols")` byte
//! array by a future phase without re-encoding.
//!
//! Format (little-endian throughout; integers are `u32` unless
//! stated):
//!
//! ```
//! offset 0:   magic   = "ZSYM"        (4 bytes)
//! offset 4:   version = 1u32          (4 bytes)
//! offset 8:   entry_count: u32        (4 bytes)
//! offset 12:  blob_size:   u32        (4 bytes)
//! offset 16:  string_blob: [blob_size]u8  (NUL-separated strings;
//!                                          a single shared blob keeps
//!                                          duplicate struct names
//!                                          de-duplicated)
//! offset 16 + blob_size:
//!             entries: [entry_count] PackedEntry
//!
//! PackedEntry (24 bytes, fixed):
//!   mangled_offset:    u32  // byte offset into string_blob
//!   mangled_length:    u32
//!   zap_struct_offset: u32  // 0xFFFFFFFF if no struct prefix
//!   zap_struct_length: u32  // 0 if no struct prefix
//!   zap_local_offset:  u32  // function name without arity suffix
//!   zap_local_length:  u32
//!   zap_arity:         u32
//! ```
//!
//! Entries are sorted by mangled name (deterministic across builds
//! given identical inputs — required for content-addressed caching
//! and golden tests). Duplicate mangled names are an error caught
//! at table-finalize time.

const std = @import("std");

/// Magic bytes written at the start of every encoded table. Used by
/// readers to validate they have the right blob and not, say, a
/// truncated DWARF section.
pub const magic: [4]u8 = .{ 'Z', 'S', 'Y', 'M' };

/// Bumped on any backwards-incompatible layout change. Readers must
/// reject blobs whose version differs from the one they were
/// compiled against — there is no on-disk forward-compat policy yet.
pub const format_version: u32 = 1;

/// One entry in the in-memory builder. Built up incrementally during
/// ZIR emission, sorted and serialized to the persistent format by
/// `Builder.encode`.
pub const Entry = struct {
    /// The Zig-mangled symbol name as it appears in the produced
    /// binary (the linker symbol the OS loader / DWARF resolver
    /// returns from a `dladdr` / `addr2line` call). For top-level
    /// non-namespaced functions this is the bare function name
    /// (`main`); for namespaced functions it is
    /// `<struct_path>.<local_name>` (e.g. `IO.puts__1`,
    /// `Zest_Runtime.run__0`). Always non-empty.
    mangled: []const u8,
    /// The Zap struct that owns the function, or `null` for the
    /// top-level entry point (`main/1`). Multi-segment struct
    /// paths use `.` separators (e.g. `Foo.Bar.Baz`).
    zap_struct: ?[]const u8,
    /// The Zap function name **with** Zap's `__N` arity suffix
    /// stripped. `IO.puts__1` -> `"puts"`. The arity travels in
    /// its own field so consumers can format
    /// `Struct.name/arity` without re-parsing.
    zap_local: []const u8,
    /// The Zap function's declared arity. Required so the printer
    /// can disambiguate overloaded clauses (`Foo.bar/0` vs
    /// `Foo.bar/2`) that mangle to distinct Zig names.
    zap_arity: u32,
};

/// Incrementally constructs a `SymbolTable` during ZIR emission.
/// `Builder.record` is called once per emitted function; `encode`
/// writes the final binary blob.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Builder) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.mangled);
            if (entry.zap_struct) |s| self.allocator.free(s);
            self.allocator.free(entry.zap_local);
        }
        self.entries.deinit(self.allocator);
    }

    /// Record one symbol mapping. The builder takes a copy of every
    /// string slice — callers may pass transient memory (typically
    /// `ir.Function` fields which the IR allocator owns) and free
    /// them as soon as the call returns.
    pub fn record(
        self: *Builder,
        mangled: []const u8,
        zap_struct: ?[]const u8,
        zap_local: []const u8,
        zap_arity: u32,
    ) !void {
        std.debug.assert(mangled.len > 0);
        std.debug.assert(zap_local.len > 0);
        const mangled_copy = try self.allocator.dupe(u8, mangled);
        errdefer self.allocator.free(mangled_copy);
        const struct_copy: ?[]const u8 = if (zap_struct) |s|
            try self.allocator.dupe(u8, s)
        else
            null;
        errdefer if (struct_copy) |s| self.allocator.free(s);
        const local_copy = try self.allocator.dupe(u8, zap_local);
        errdefer self.allocator.free(local_copy);
        try self.entries.append(self.allocator, .{
            .mangled = mangled_copy,
            .zap_struct = struct_copy,
            .zap_local = local_copy,
            .zap_arity = zap_arity,
        });
    }

    /// Strip Zap's `__<arity>` suffix from `local_name`. Convenience
    /// for IR callers which carry the suffixed form. Returns the
    /// original slice if no suffix is present.
    pub fn stripAritySuffix(local_name: []const u8) struct {
        base: []const u8,
        arity: ?u32,
    } {
        if (std.mem.lastIndexOf(u8, local_name, "__")) |pos| {
            const suffix = local_name[pos + 2 ..];
            if (suffix.len == 0) return .{ .base = local_name, .arity = null };
            const parsed = std.fmt.parseUnsigned(u32, suffix, 10) catch {
                return .{ .base = local_name, .arity = null };
            };
            return .{ .base = local_name[0..pos], .arity = parsed };
        }
        return .{ .base = local_name, .arity = null };
    }

    /// Sort entries by mangled name and serialize to the persistent
    /// binary format. Returns an owned `[]u8` containing the full
    /// blob (magic + header + string blob + packed entries). Caller
    /// is responsible for freeing.
    ///
    /// Detects duplicate mangled names and returns
    /// `error.DuplicateMangledName`; that condition indicates the
    /// monomorphization pass produced two specializations that
    /// collide at the linker level — a bug worth surfacing rather
    /// than silently overwriting.
    pub fn encode(self: *Builder) ![]u8 {
        const gpa = self.allocator;

        // Sort entries lexicographically by mangled name so the
        // serialized blob is deterministic across builds.
        std.sort.pdq(Entry, self.entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.mangled, b.mangled) == .lt;
            }
        }.lessThan);

        // Detect collisions in the sorted list.
        for (self.entries.items, 0..) |entry, idx| {
            if (idx == 0) continue;
            if (std.mem.eql(u8, entry.mangled, self.entries.items[idx - 1].mangled)) {
                return error.DuplicateMangledName;
            }
        }

        // Build the string blob. De-duplicate strings so each unique
        // byte sequence is stored once — the struct path "Zest_Runtime"
        // is shared by dozens of test entries in a typical build.
        var blob: std.ArrayListUnmanaged(u8) = .empty;
        defer blob.deinit(gpa);
        var offsets = std.StringHashMap(u32).init(gpa);
        defer offsets.deinit();

        const internString = struct {
            fn call(
                blob_ref: *std.ArrayListUnmanaged(u8),
                offsets_ref: *std.StringHashMap(u32),
                allocator: std.mem.Allocator,
                s: []const u8,
            ) !u32 {
                if (offsets_ref.get(s)) |existing| return existing;
                const off: u32 = @intCast(blob_ref.items.len);
                try blob_ref.appendSlice(allocator, s);
                try offsets_ref.put(s, off);
                return off;
            }
        }.call;

        const PackedEntry = extern struct {
            mangled_offset: u32,
            mangled_length: u32,
            zap_struct_offset: u32,
            zap_struct_length: u32,
            zap_local_offset: u32,
            zap_local_length: u32,
            zap_arity: u32,
        };

        var packed_entries = try gpa.alloc(PackedEntry, self.entries.items.len);
        defer gpa.free(packed_entries);

        for (self.entries.items, 0..) |entry, idx| {
            const m_off = try internString(&blob, &offsets, gpa, entry.mangled);
            const s_off: u32 = if (entry.zap_struct) |s|
                try internString(&blob, &offsets, gpa, s)
            else
                std.math.maxInt(u32);
            const s_len: u32 = if (entry.zap_struct) |s| @intCast(s.len) else 0;
            const l_off = try internString(&blob, &offsets, gpa, entry.zap_local);
            packed_entries[idx] = .{
                .mangled_offset = m_off,
                .mangled_length = @intCast(entry.mangled.len),
                .zap_struct_offset = s_off,
                .zap_struct_length = s_len,
                .zap_local_offset = l_off,
                .zap_local_length = @intCast(entry.zap_local.len),
                .zap_arity = entry.zap_arity,
            };
        }

        const entries_bytes: usize = packed_entries.len * @sizeOf(PackedEntry);
        const header_size: usize = magic.len + @sizeOf(u32) * 3;
        const total: usize = header_size + blob.items.len + entries_bytes;
        const out = try gpa.alloc(u8, total);
        errdefer gpa.free(out);
        @memcpy(out[0..magic.len], &magic);
        std.mem.writeInt(u32, out[magic.len..][0..4], format_version, .little);
        std.mem.writeInt(u32, out[magic.len + 4 ..][0..4], @intCast(self.entries.items.len), .little);
        std.mem.writeInt(u32, out[magic.len + 8 ..][0..4], @intCast(blob.items.len), .little);
        @memcpy(out[header_size..][0..blob.items.len], blob.items);
        const entries_dst = out[header_size + blob.items.len ..][0..entries_bytes];
        @memcpy(entries_dst, std.mem.sliceAsBytes(packed_entries));
        return out;
    }
};

/// Reader for the persistent format. Owns its backing bytes by
/// reference only — does not allocate. Lookup operations return
/// slices into the caller-owned blob.
pub const Reader = struct {
    bytes: []const u8,
    entry_count: u32,
    string_blob: []const u8,
    /// Pointer-cast view of the packed entries. Length = entry_count.
    /// The on-disk layout is little-endian; this reader assumes the
    /// host matches (every Zap target so far is little-endian).
    entries_raw: []const PackedEntry,

    pub const PackedEntry = extern struct {
        mangled_offset: u32,
        mangled_length: u32,
        zap_struct_offset: u32,
        zap_struct_length: u32,
        zap_local_offset: u32,
        zap_local_length: u32,
        zap_arity: u32,
    };

    pub const ParseError = error{
        BadMagic,
        UnsupportedVersion,
        TruncatedBlob,
        UnalignedEntries,
    };

    /// Decode the header and validate the blob's structure. Returns
    /// a `Reader` whose lifetime is tied to `bytes` — the caller
    /// must keep the backing buffer alive for the reader's lifetime.
    pub fn init(bytes: []const u8) ParseError!Reader {
        const header_size: usize = magic.len + @sizeOf(u32) * 3;
        if (bytes.len < header_size) return error.TruncatedBlob;
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.BadMagic;
        const version = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
        if (version != format_version) return error.UnsupportedVersion;
        const entry_count = std.mem.readInt(u32, bytes[magic.len + 4 ..][0..4], .little);
        const blob_size = std.mem.readInt(u32, bytes[magic.len + 8 ..][0..4], .little);
        const entries_offset = header_size + blob_size;
        const entries_bytes: usize = @as(usize, entry_count) * @sizeOf(PackedEntry);
        if (bytes.len < entries_offset + entries_bytes) return error.TruncatedBlob;
        // The pointer cast below requires natural alignment for
        // PackedEntry, which a u32-aligned blob satisfies trivially
        // (the magic is 4 bytes, header is u32-aligned, blob is
        // byte-aligned but we land on a 4-byte-aligned offset only
        // when blob_size is a multiple of 4).
        if ((entries_offset % @alignOf(PackedEntry)) != 0) return error.UnalignedEntries;
        const entries_raw = std.mem.bytesAsSlice(
            PackedEntry,
            bytes[entries_offset .. entries_offset + entries_bytes],
        );
        return .{
            .bytes = bytes,
            .entry_count = entry_count,
            .string_blob = bytes[header_size..entries_offset],
            .entries_raw = entries_raw,
        };
    }

    /// Resolve a packed string reference into a slice of the blob.
    fn stringAt(self: Reader, offset: u32, length: u32) []const u8 {
        if (length == 0) return "";
        return self.string_blob[offset .. offset + length];
    }

    /// One decoded entry. All slices reference `Reader.string_blob`.
    pub const View = struct {
        mangled: []const u8,
        zap_struct: ?[]const u8,
        zap_local: []const u8,
        zap_arity: u32,
    };

    /// Decode entry at `index`. Indices are 0-based and dense in
    /// the range `[0, entry_count)`.
    pub fn entry(self: Reader, index: u32) View {
        const raw = self.entries_raw[index];
        const zap_struct: ?[]const u8 = if (raw.zap_struct_length == 0)
            null
        else
            self.stringAt(raw.zap_struct_offset, raw.zap_struct_length);
        return .{
            .mangled = self.stringAt(raw.mangled_offset, raw.mangled_length),
            .zap_struct = zap_struct,
            .zap_local = self.stringAt(raw.zap_local_offset, raw.zap_local_length),
            .zap_arity = raw.zap_arity,
        };
    }

    /// Find an entry by its mangled name. O(log n) — the on-disk
    /// table is sorted by `mangled`. Returns `null` when not found.
    pub fn findByMangled(self: Reader, mangled: []const u8) ?View {
        var lo: u32 = 0;
        var hi: u32 = self.entry_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = self.entry(mid);
            switch (std.mem.order(u8, v.mangled, mangled)) {
                .eq => return v,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Find an entry by Zap-qualified name `struct + "." + local + "/" + arity`.
    /// Linear scan — used by tooling, not by the hot crash printer.
    /// Returns the first matching entry.
    pub fn findByZap(
        self: Reader,
        zap_struct: ?[]const u8,
        zap_local: []const u8,
        zap_arity: u32,
    ) ?View {
        var i: u32 = 0;
        while (i < self.entry_count) : (i += 1) {
            const v = self.entry(i);
            if (v.zap_arity != zap_arity) continue;
            if (!std.mem.eql(u8, v.zap_local, zap_local)) continue;
            switch (matchOptional(v.zap_struct, zap_struct)) {
                true => return v,
                false => {},
            }
        }
        return null;
    }

    fn matchOptional(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "Builder.stripAritySuffix recognises Zap's __N convention" {
    const stripped = Builder.stripAritySuffix("puts__1");
    try std.testing.expectEqualStrings("puts", stripped.base);
    try std.testing.expectEqual(@as(?u32, 1), stripped.arity);

    const noSuffix = Builder.stripAritySuffix("plain");
    try std.testing.expectEqualStrings("plain", noSuffix.base);
    try std.testing.expectEqual(@as(?u32, null), noSuffix.arity);

    // A trailing `__` with no digits is not a valid arity suffix —
    // keep the original name so the caller can decide what to do.
    const trailingUnderscores = Builder.stripAritySuffix("weird__");
    try std.testing.expectEqualStrings("weird__", trailingUnderscores.base);
    try std.testing.expectEqual(@as(?u32, null), trailingUnderscores.arity);
}

test "Builder.encode + Reader.init round-trip a small table" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.record("main", null, "main", 1);
    try builder.record("IO.puts__1", "IO", "puts", 1);
    try builder.record("Zest_Runtime.run__0", "Zest_Runtime", "run", 0);

    const blob = try builder.encode();
    defer std.testing.allocator.free(blob);

    const reader = try Reader.init(blob);
    try std.testing.expectEqual(@as(u32, 3), reader.entry_count);

    // Mangled-name lookup recovers the Zap-qualified name.
    const io = reader.findByMangled("IO.puts__1") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("IO", io.zap_struct.?);
    try std.testing.expectEqualStrings("puts", io.zap_local);
    try std.testing.expectEqual(@as(u32, 1), io.zap_arity);

    // Reverse lookup: Zap-qualified -> mangled.
    const reverse = reader.findByZap("Zest_Runtime", "run", 0) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Zest_Runtime.run__0", reverse.mangled);

    // The entry-point case carries no struct prefix.
    const main_entry = reader.findByMangled("main") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(main_entry.zap_struct == null);
    try std.testing.expectEqualStrings("main", main_entry.zap_local);
    try std.testing.expectEqual(@as(u32, 1), main_entry.zap_arity);

    // Missing entry returns null.
    try std.testing.expect(reader.findByMangled("does_not_exist") == null);
    try std.testing.expect(reader.findByZap("Missing", "fn", 0) == null);
}

test "Builder.encode emits entries sorted by mangled name" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    // Insert in a deliberately non-sorted order to exercise the
    // pdq-sort path in encode.
    try builder.record("Z.last__0", "Z", "last", 0);
    try builder.record("A.first__1", "A", "first", 1);
    try builder.record("M.middle__2", "M", "middle", 2);

    const blob = try builder.encode();
    defer std.testing.allocator.free(blob);

    const reader = try Reader.init(blob);
    try std.testing.expectEqual(@as(u32, 3), reader.entry_count);
    try std.testing.expectEqualStrings("A.first__1", reader.entry(0).mangled);
    try std.testing.expectEqualStrings("M.middle__2", reader.entry(1).mangled);
    try std.testing.expectEqualStrings("Z.last__0", reader.entry(2).mangled);
}

test "Builder.encode detects duplicate mangled names" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.record("Foo.bar__1", "Foo", "bar", 1);
    try builder.record("Foo.bar__1", "Foo", "bar", 1);

    try std.testing.expectError(error.DuplicateMangledName, builder.encode());
}

test "Reader.init rejects truncated blob, bad magic, wrong version" {
    try std.testing.expectError(error.TruncatedBlob, Reader.init(""));
    try std.testing.expectError(error.TruncatedBlob, Reader.init("ZSYM"));

    const fake_bad_magic = [_]u8{ 'X', 'X', 'X', 'X', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectError(error.BadMagic, Reader.init(&fake_bad_magic));

    var fake_bad_version: [16]u8 = undefined;
    @memcpy(fake_bad_version[0..4], &magic);
    std.mem.writeInt(u32, fake_bad_version[4..][0..4], 999, .little);
    std.mem.writeInt(u32, fake_bad_version[8..][0..4], 0, .little);
    std.mem.writeInt(u32, fake_bad_version[12..][0..4], 0, .little);
    try std.testing.expectError(error.UnsupportedVersion, Reader.init(&fake_bad_version));
}
