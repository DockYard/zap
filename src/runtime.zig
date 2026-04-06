const std = @import("std");

// ============================================================
// Static Bump Allocator
// Avoids std.heap.page_allocator which uses cmpxchg_strong and
// other operations not supported by the Zig self-hosted backend.
// ============================================================

const BUMP_SIZE = 16 * 1024; // 16KB
var bump_buf: [BUMP_SIZE]u8 = undefined;
var bump_offset: usize = 0;

fn bumpAlloc(len: usize) []u8 {
    const aligned = (bump_offset + 7) & ~@as(usize, 7); // 8-byte align
    if (aligned + len > BUMP_SIZE) return &.{};
    const result = bump_buf[aligned .. aligned + len];
    bump_offset = aligned + len;
    return result;
}

fn bumpAllocSlice(comptime T: type, len: usize) []T {
    const byte_len = len * @sizeOf(T);
    const bytes = bumpAlloc(byte_len);
    if (bytes.len == 0) return &.{};
    const aligned: [*]T = @ptrCast(@alignCast(bytes.ptr));
    return aligned[0..len];
}

// ============================================================
// Zap Runtime Support Module (spec §21, §31.7)
//
// Provides runtime types for generated Zig code:
//   - Arc(T)       — generic ARC wrapper with atomic refcount
//   - Atom         — interned atom representation
//   - Closure      — fat pointer for function values
//   - ZapAllocator — allocator plumbing
//   - List(T)      — persistent list
//   - ZapMap(K,V)  — persistent map (HAMT-based)
//   - String       — owned string with length
// ============================================================

// ============================================================
// ARC — Atomic Reference Counting (spec §31.4)
// ============================================================

pub const ArcHeader = struct {
    ref_count: std.atomic.Value(u32),

    pub fn init() ArcHeader {
        return .{ .ref_count = std.atomic.Value(u32).init(1) };
    }

    pub fn retain(self: *ArcHeader) void {
        _ = self.ref_count.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *ArcHeader) bool {
        const prev = self.ref_count.fetchSub(1, .acq_rel);
        if (prev == 1) {
            return true; // caller should free
        }
        return false;
    }

    pub fn count(self: *const ArcHeader) u32 {
        return self.ref_count.load(.acquire);
    }

    /// Non-generic retain for use from ZIR — takes an opaque pointer to an ArcHeader.
    pub fn retainOpaque(ptr: *anyopaque) void {
        const header: *ArcHeader = @ptrCast(@alignCast(ptr));
        header.retain();
    }

    /// Non-generic release for use from ZIR — returns true if the caller should free.
    pub fn releaseOpaque(ptr: *anyopaque) bool {
        const header: *ArcHeader = @ptrCast(@alignCast(ptr));
        return header.release();
    }
};

pub fn Arc(comptime T: type) type {
    return struct {
        const Self = @This();

        const Inner = struct {
            header: ArcHeader,
            value: T,
        };

        ptr: *Inner,

        pub fn init(allocator: std.mem.Allocator, value: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .header = ArcHeader.init(),
                .value = value,
            };
            return .{ .ptr = inner };
        }

        pub fn retain(self: Self) Self {
            self.ptr.header.retain();
            return self;
        }

        pub fn release(self: Self, allocator: std.mem.Allocator) void {
            if (self.ptr.header.release()) {
                allocator.destroy(self.ptr);
            }
        }

        pub fn get(self: Self) *T {
            return &self.ptr.value;
        }

        pub fn getConst(self: Self) *const T {
            return &self.ptr.value;
        }

        pub fn refCount(self: Self) u32 {
            return self.ptr.header.count();
        }
    };
}

// ============================================================
// ArcRuntime — Non-generic ARC helpers for ZIR (spec §31.4)
//
// ZIR cannot express generic instantiation, so ArcRuntime
// provides concrete helper functions that take comptime T via
// @TypeOf, making them callable from generated ZIR code.
// ============================================================

pub const ArcRuntime = struct {
    /// Allocate and wrap a value in an Arc. Returns a pointer to the
    /// value field inside the Arc inner struct.
    pub fn allocAny(comptime T: type, allocator: std.mem.Allocator, value: T) *T {
        const Inner = Arc(T).Inner;
        const inner = allocator.create(Inner) catch @panic("ArcRuntime.allocAny: out of memory");
        inner.* = .{
            .header = ArcHeader.init(),
            .value = value,
        };
        return &inner.value;
    }

    /// Free an Arc-managed value given a pointer to the value field.
    /// Decrements the refcount and frees the inner allocation when it reaches zero.
    pub fn freeAny(comptime T: type, allocator: std.mem.Allocator, ptr: *T) void {
        const Inner = Arc(T).Inner;
        const inner: *Inner = @fieldParentPtr("value", ptr);
        if (inner.header.release()) {
            allocator.destroy(inner);
        }
    }

    /// Release (decrement refcount) an Arc-managed value given a pointer to the
    /// value field. Frees the inner allocation when the refcount reaches zero.
    pub fn releaseAny(comptime T: type, allocator: std.mem.Allocator, ptr: *T) void {
        freeAny(T, allocator, ptr);
    }

    /// Retain (increment refcount) an Arc-managed value given a pointer to the value field.
    pub fn retainAny(comptime T: type, ptr: *T) void {
        const Inner = Arc(T).Inner;
        const inner: *Inner = @fieldParentPtr("value", ptr);
        inner.header.retain();
    }

    /// Get the refcount of an Arc-managed value.
    pub fn refCountAny(comptime T: type, ptr: *T) u32 {
        const Inner = Arc(T).Inner;
        const inner: *Inner = @fieldParentPtr("value", ptr);
        return inner.header.count();
    }

    /// Reset a value for Perceus-style reuse. If the reference count is 1,
    /// return an opaque reuse token for the existing allocation. Otherwise,
    /// release the current value and return null.
    pub fn resetAny(comptime T: type, allocator: std.mem.Allocator, ptr: *T) ?*anyopaque {
        if (refCountAny(T, ptr) == 1) {
            return @ptrCast(ptr);
        }
        releaseAny(T, allocator, ptr);
        return null;
    }

    /// Convert a Perceus reuse token back into a typed allocation. If the token
    /// is present, reuse that storage; otherwise allocate a fresh value.
    pub fn reuseAllocByType(comptime T: type, allocator: std.mem.Allocator, token: ?*anyopaque) *T {
        if (token) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return allocator.create(T) catch @panic("ArcRuntime.reuseAllocByType: out of memory");
    }
};

// ============================================================
// Atom — Interned atom values (spec §5.6)
// ============================================================

pub const Atom = struct {
    id: u32,

    pub const nil_id: u32 = 0;
    pub const true_id: u32 = 1;
    pub const false_id: u32 = 2;
    pub const ok_id: u32 = 3;
    pub const error_id: u32 = 4;

    pub const nil: Atom = .{ .id = nil_id };
    pub const @"true": Atom = .{ .id = true_id };
    pub const @"false": Atom = .{ .id = false_id };
    pub const ok: Atom = .{ .id = ok_id };
    pub const @"error": Atom = .{ .id = error_id };

    pub fn eql(a: Atom, b: Atom) bool {
        return a.id == b.id;
    }
};

pub const AtomTable = struct {
    allocator: std.mem.Allocator,
    strings: std.ArrayList([]const u8),
    lookup: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) AtomTable {
        var table = AtomTable{
            .allocator = allocator,
            .strings = .empty,
            .lookup = std.StringHashMap(u32).init(allocator),
        };
        // Register well-known atoms
        const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error" };
        for (builtins) |name| {
            table.strings.append(allocator, name) catch {};
            table.lookup.put(name, @intCast(table.strings.items.len - 1)) catch {};
        }
        return table;
    }

    pub fn deinit(self: *AtomTable) void {
        self.strings.deinit(self.allocator);
        self.lookup.deinit();
    }

    pub fn intern(self: *AtomTable, name: []const u8) !Atom {
        if (self.lookup.get(name)) |id| {
            return .{ .id = id };
        }
        const id: u32 = @intCast(self.strings.items.len);
        const duped = try self.allocator.dupe(u8, name);
        try self.strings.append(self.allocator, duped);
        try self.lookup.put(duped, id);
        return .{ .id = id };
    }

    pub fn getName(self: *const AtomTable, atom: Atom) []const u8 {
        if (atom.id < self.strings.items.len) {
            return self.strings.items[atom.id];
        }
        return "<unknown_atom>";
    }
};

// ============================================================
// Global Atom Table — process-wide interned atom registry
// ============================================================

// Simple atom table using fixed-size arrays to avoid std.HashMap/ArrayList
// which require operations not yet implemented in the Zig self-hosted backend.
const MAX_ATOMS = 256;
const MAX_ATOM_NAME_LEN = 64;

var atom_names: [MAX_ATOMS][MAX_ATOM_NAME_LEN]u8 = undefined;
var atom_lengths: [MAX_ATOMS]u32 = [_]u32{0} ** MAX_ATOMS;
var atom_count: u32 = 0;
var atom_table_initialized: bool = false;

fn initAtomTable() void {
    if (atom_table_initialized) return;
    // Register well-known atoms
    const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error" };
    for (builtins) |name| {
        const id = atom_count;
        const len: u32 = @intCast(name.len);
        @memcpy(atom_names[id][0..len], name);
        atom_lengths[id] = len;
        atom_count += 1;
    }
    atom_table_initialized = true;
}

/// Intern a string as an atom. Returns the atom's u32 ID.
pub fn atomIntern(name: [*]const u8, len: u32) u32 {
    initAtomTable();
    const name_slice = name[0..len];
    // Search existing atoms
    var i: u32 = 0;
    while (i < atom_count) : (i += 1) {
        if (atom_lengths[i] == len) {
            if (std.mem.eql(u8, atom_names[i][0..len], name_slice)) {
                return i;
            }
        }
    }
    // New atom
    if (atom_count >= MAX_ATOMS) return 0;
    const id = atom_count;
    @memcpy(atom_names[id][0..len], name_slice);
    atom_lengths[id] = len;
    atom_count += 1;
    return id;
}

/// Get the string name of an atom by its u32 ID.
pub fn atomToString(id: u32) []const u8 {
    initAtomTable();
    if (id < atom_count) {
        return atom_names[id][0..atom_lengths[id]];
    }
    return "<unknown_atom>";
}

/// Compare two atom IDs for equality.
pub fn atomEq(a: u32, b: u32) bool {
    return a == b;
}

// ============================================================
// Builder Runtime — entry point plumbing for build.zap builders
// ============================================================

pub const BuilderRuntime = struct {
    /// Construct Zap.Env from std.os.argv.
    /// argv[0] = binary, argv[1] = target, argv[2] = os, argv[3] = arch
    pub fn buildEnvFromArgv() struct { target: u32, os: u32, arch: u32 } {
        const argv = std.os.argv;
        return .{
            .target = if (argv.len > 1) atomIntern(argv[1], @intCast(std.mem.len(argv[1]))) else 0,
            .os = if (argv.len > 2) atomIntern(argv[2], @intCast(std.mem.len(argv[2]))) else 0,
            .arch = if (argv.len > 3) atomIntern(argv[3], @intCast(std.mem.len(argv[3]))) else 0,
        };
    }

    /// Serialize a manifest struct to stdout as key=value lines.
    pub fn serializeManifest(manifest: anytype) void {
        const T = @TypeOf(manifest);
        const info = @typeInfo(T);
        if (info != .@"struct") return; // void or non-struct — nothing to serialize
        const stdout = std.fs.File.stdout().deprecatedWriter();
        inline for (info.@"struct".fields) |field| {
            const value = @field(manifest, field.name);
            const FT = @TypeOf(value);
            if (FT == []const u8) {
                stdout.print("{s}={s}\n", .{ field.name, value }) catch {};
            } else if (FT == u32) {
                stdout.print("{s}={s}\n", .{ field.name, atomToString(value) }) catch {};
            } else if (@typeInfo(FT) == .int) {
                stdout.print("{s}={d}\n", .{ field.name, value }) catch {};
            } else if (FT == bool) {
                stdout.print("{s}={}\n", .{ field.name, value }) catch {};
            }
        }
    }
};

// ============================================================
// Closure — Fat pointer for function values (spec §20.2, §31.3)
// ============================================================

pub fn Closure(comptime Args: type, comptime Ret: type) type {
    return struct {
        const Self = @This();

        call_fn: *const fn (*anyopaque, Args) Ret,
        env: *anyopaque,

        pub fn invoke(self: Self, args: Args) Ret {
            return self.call_fn(self.env, args);
        }
    };
}

/// Type-erased closure for dynamic dispatch
pub const DynClosure = struct {
    call_fn: *const anyopaque,
    env: ?*anyopaque,
    env_release: ?*const fn (*anyopaque) void,

    pub fn release(self: DynClosure) void {
        if (self.env_release) |rel| {
            if (self.env) |e| {
                rel(e);
            }
        }
    }
};

pub fn invokeDynClosure(comptime Ret: type, closure: DynClosure, args: anytype) Ret {
    const Fn = *const fn (?*anyopaque, @TypeOf(args)) Ret;
    const fn_ptr: Fn = @ptrCast(@alignCast(closure.call_fn));
    return fn_ptr(closure.env, args);
}

// ============================================================
// Tagged Value — Runtime tagged union for dynamic values
// ============================================================

pub const TaggedValue = union(enum) {
    int: i64,
    float: f64,
    bool_val: bool,
    atom: Atom,
    string: []const u8,
    nil: void,
    tuple: []const TaggedValue,
    list: *const List(TaggedValue),
    closure: DynClosure,

    pub fn isNil(self: TaggedValue) bool {
        return self == .nil;
    }

    pub fn isTruthy(self: TaggedValue) bool {
        return switch (self) {
            .nil => false,
            .bool_val => |b| b,
            .atom => |a| !a.eql(Atom.nil) and !a.eql(Atom.false),
            else => true,
        };
    }

    pub fn eql(a: TaggedValue, b: TaggedValue) bool {
        const a_tag = std.meta.activeTag(a);
        const b_tag = std.meta.activeTag(b);
        if (a_tag != b_tag) return false;

        return switch (a) {
            .int => |v| v == b.int,
            .float => |v| v == b.float,
            .bool_val => |v| v == b.bool_val,
            .atom => |v| v.eql(b.atom),
            .string => |v| std.mem.eql(u8, v, b.string),
            .nil => true,
            .tuple => |v| {
                if (v.len != b.tuple.len) return false;
                for (v, b.tuple) |ea, eb| {
                    if (!ea.eql(eb)) return false;
                }
                return true;
            },
            .list, .closure => false, // structural equality not supported for these
        };
    }
};

// ============================================================
// List — Persistent singly-linked list (spec §30.3)
// ============================================================

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            value: T,
            next: ?*const Node,
        };

        head: ?*const Node,
        len: usize,

        pub const empty: Self = .{ .head = null, .len = 0 };

        /// Prepend a value. Nodes are arena-allocated; the caller's
        /// arena owns all memory.
        pub fn cons(self: Self, allocator: std.mem.Allocator, value: T) !Self {
            const node = try allocator.create(Node);
            node.* = .{
                .value = value,
                .next = self.head,
            };
            return .{ .head = node, .len = self.len + 1 };
        }

        pub fn hd(self: Self) ?T {
            if (self.head) |h| return h.value;
            return null;
        }

        pub fn tl(self: Self) Self {
            if (self.head) |h| {
                return .{
                    .head = h.next,
                    .len = self.len - 1,
                };
            }
            return .empty;
        }

        pub fn length(self: Self) usize {
            return self.len;
        }

        pub fn isEmpty(self: Self) bool {
            return self.head == null;
        }

        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]T {
            const slice = try allocator.alloc(T, self.len);
            var current = self.head;
            var i: usize = 0;
            while (current) |node| {
                slice[i] = node.value;
                current = node.next;
                i += 1;
            }
            return slice;
        }

        pub fn fromSlice(allocator: std.mem.Allocator, items: []const T) !Self {
            var list: Self = .empty;
            // Build in reverse so the list order matches the slice order
            var i = items.len;
            while (i > 0) {
                i -= 1;
                list = try list.cons(allocator, items[i]);
            }
            return list;
        }
    };
}

const testing = std.testing;

test "ArcRuntime.resetAny returns token for unique value" {
    const allocator = testing.allocator;
    const ptr = ArcRuntime.allocAny(i64, allocator, 42);
    const token = ArcRuntime.resetAny(i64, allocator, ptr);
    try testing.expect(token != null);
    const reused = ArcRuntime.reuseAllocByType(i64, allocator, token);
    reused.* = 7;
    try testing.expectEqual(@as(i64, 7), reused.*);
    ArcRuntime.releaseAny(i64, allocator, reused);
}

test "ArcRuntime.resetAny releases shared value and yields null token" {
    const allocator = testing.allocator;
    const ptr = ArcRuntime.allocAny(i64, allocator, 10);
    ArcRuntime.retainAny(i64, ptr);
    const token = ArcRuntime.resetAny(i64, allocator, ptr);
    try testing.expect(token == null);
    ArcRuntime.releaseAny(i64, allocator, ptr);
}

// ============================================================
// ZapMap — Hash Array Mapped Trie (HAMT) for persistent maps
// (spec §30.3, §31.7)
//
// Simplified initial implementation using a sorted array.
// Full HAMT can be added later for performance.
// ============================================================

pub fn ZapMap(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            key: K,
            value: V,
        };

        entries: []const Entry,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entries = &.{},
                .allocator = allocator,
            };
        }

        pub fn size(self: Self) usize {
            return self.entries.len;
        }

        pub fn get(self: Self, key: K) ?V {
            for (self.entries) |entry| {
                if (keysEqual(entry.key, key)) return entry.value;
            }
            return null;
        }

        pub fn put(self: Self, key: K, value: V) !Self {
            // Check if key exists — update in place (immutably)
            for (self.entries, 0..) |entry, i| {
                if (keysEqual(entry.key, key)) {
                    const new_entries = try self.allocator.alloc(Entry, self.entries.len);
                    @memcpy(new_entries, self.entries);
                    new_entries[i] = .{ .key = key, .value = value };
                    return .{ .entries = new_entries, .allocator = self.allocator };
                }
            }

            // Key doesn't exist — append
            const new_entries = try self.allocator.alloc(Entry, self.entries.len + 1);
            @memcpy(new_entries[0..self.entries.len], self.entries);
            new_entries[self.entries.len] = .{ .key = key, .value = value };
            return .{ .entries = new_entries, .allocator = self.allocator };
        }

        pub fn delete(self: Self, key: K) !Self {
            for (self.entries, 0..) |entry, i| {
                if (keysEqual(entry.key, key)) {
                    const new_entries = try self.allocator.alloc(Entry, self.entries.len - 1);
                    @memcpy(new_entries[0..i], self.entries[0..i]);
                    @memcpy(new_entries[i..], self.entries[i + 1 ..]);
                    return .{ .entries = new_entries, .allocator = self.allocator };
                }
            }
            return self;
        }

        pub fn keys(self: Self, allocator: std.mem.Allocator) ![]K {
            const result = try allocator.alloc(K, self.entries.len);
            for (self.entries, 0..) |entry, i| {
                result[i] = entry.key;
            }
            return result;
        }

        pub fn values(self: Self, allocator: std.mem.Allocator) ![]V {
            const result = try allocator.alloc(V, self.entries.len);
            for (self.entries, 0..) |entry, i| {
                result[i] = entry.value;
            }
            return result;
        }

        fn keysEqual(a: K, b: K) bool {
            if (K == []const u8) return std.mem.eql(u8, a, b);
            return a == b;
        }
    };
}

// ============================================================
// ZapString — String utilities
// ============================================================

pub const ZapString = struct {
    /// Convert a string to an atom, creating it if it doesn't exist.
    pub fn to_atom(name: []const u8) u32 {
        return atomIntern(name.ptr, @intCast(name.len));
    }

    /// Convert a string to an existing atom. Returns null (0xFFFFFFFF)
    /// if the atom has not been previously interned.
    pub fn to_existing_atom(name: []const u8) u32 {
        initAtomTable();
        var i: u32 = 0;
        while (i < atom_count) : (i += 1) {
            if (atom_lengths[i] == name.len) {
                if (std.mem.eql(u8, atom_names[i][0..name.len], name)) {
                    return i;
                }
            }
        }
        return 0xFFFFFFFF;
    }

    pub fn concat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
        const result = try allocator.alloc(u8, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    /// Bump-allocated concat for ZIR-compiled code (avoids page_allocator).
    pub fn concatBump(a: []const u8, b: []const u8) []const u8 {
        const result = bumpAlloc(a.len + b.len);
        if (result.len == 0) return a; // fallback: return first string
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    pub fn length(s: []const u8) usize {
        return s.len;
    }

    pub fn slice(s: []const u8, start: usize, end: usize) []const u8 {
        const s_end = @min(end, s.len);
        const s_start = @min(start, s_end);
        return s[s_start..s_end];
    }

    pub fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }

    pub fn startsWith(s: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, s, prefix);
    }

    pub fn endsWith(s: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, s, suffix);
    }

    pub fn trim(s: []const u8) []const u8 {
        return std.mem.trim(u8, s, " \t\n\r");
    }
};

// ============================================================
// Prelude / Kernel functions (spec §30.2)
// ============================================================

pub fn panic(message: []const u8) noreturn {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("** (NilError) {s}\n", .{message}) catch {};
    std.process.exit(1);
}

pub const Prelude = struct {
    pub fn println(value: anytype) void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdout.print("{s}\n", .{value}) catch {};
        } else if (info == .int or info == .comptime_int) {
            stdout.print("{d}\n", .{value}) catch {};
        } else if (info == .float or info == .comptime_float) {
            stdout.print("{d}\n", .{value}) catch {};
        } else if (T == bool) {
            stdout.print("{}\n", .{value}) catch {};
        } else if (info == .@"enum") {
            stdout.print(":{s}\n", .{@tagName(value)}) catch {};
        } else if (T == u32) {
            // Could be an atom ID — print as atom if it looks up
            const name = atomToString(value);
            if (!std.mem.eql(u8, name, "<unknown_atom>")) {
                stdout.print(":{s}\n", .{name}) catch {};
            } else {
                stdout.print("{d}\n", .{value}) catch {};
            }
        } else {
            // For tuples, structs, and other compound types, use inspect formatting
            inspectWrite(stdout, value);
            stdout.print("\n", .{}) catch {};
        }
    }

    pub fn inspect(value: anytype) InspectReturn(@TypeOf(value)) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        inspectWrite(stdout, value);
        stdout.print("\n", .{}) catch {};
        const RT = InspectReturn(@TypeOf(value));
        if (RT == void) return;
        return value;
    }

    /// Returns `void` for comptime-only types (enum literals, comptime_int, etc.)
    /// so that `inspect` can be called at runtime without forcing comptime evaluation.
    /// For all other types, returns the input type to support piping.
    fn InspectReturn(comptime T: type) type {
        return switch (@typeInfo(T)) {
            .enum_literal, .comptime_int, .comptime_float, .type, .null, .undefined => void,
            else => T,
        };
    }

    fn inspectWrite(writer: anytype, value: anytype) void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8) {
            writer.print("\"{s}\"", .{value}) catch {};
        } else if (info == .pointer) {
            const child_info = @typeInfo(info.pointer.child);
            if (child_info == .array) {
                if (child_info.array.child == u8) {
                    // *const [N]u8 — string
                    writer.print("\"{s}\"", .{value}) catch {};
                } else {
                    // *const [N]T — list
                    writer.print("[", .{}) catch {};
                    for (0..child_info.array.len) |i| {
                        if (i > 0) writer.print(", ", .{}) catch {};
                        inspectWrite(writer, value[i]);
                    }
                    writer.print("]", .{}) catch {};
                }
            } else {
                writer.print("{any}", .{value}) catch {};
            }
        } else if (info == .int or info == .comptime_int) {
            writer.print("{d}", .{value}) catch {};
        } else if (info == .float or info == .comptime_float) {
            const rounded: i64 = @intFromFloat(value);
            if (value == @as(@TypeOf(value), @floatFromInt(rounded))) {
                writer.print("{d}.0", .{rounded}) catch {};
            } else {
                writer.print("{d}", .{value}) catch {};
            }
        } else if (T == bool) {
            writer.print("{}", .{value}) catch {};
        } else if (info == .@"struct" and info.@"struct".is_tuple) {
            writer.print("{{", .{}) catch {};
            inline for (info.@"struct".fields, 0..) |field, i| {
                if (i > 0) writer.print(", ", .{}) catch {};
                inspectWrite(writer, @field(value, field.name));
            }
            writer.print("}}", .{}) catch {};
        } else if (info == .@"struct") {
            // Detect Zap map representation: struct of .{key, value} entry structs.
            // A map is an anonymous struct where every field is a 2-field struct with "key" and "value".
            const is_map = comptime blk: {
                if (info.@"struct".fields.len == 0) break :blk false;
                for (info.@"struct".fields) |f| {
                    const inner = @typeInfo(f.type);
                    if (inner != .@"struct") break :blk false;
                    if (inner.@"struct".fields.len != 2) break :blk false;
                    const has_key = for (inner.@"struct".fields) |ef| {
                        if (std.mem.eql(u8, ef.name, "key")) break true;
                    } else false;
                    const has_value = for (inner.@"struct".fields) |ef| {
                        if (std.mem.eql(u8, ef.name, "value")) break true;
                    } else false;
                    if (!has_key or !has_value) break :blk false;
                }
                break :blk true;
            };
            if (is_map) {
                // Print as %{key: value, ...}
                writer.print("%{{", .{}) catch {};
                inline for (info.@"struct".fields, 0..) |field, i| {
                    if (i > 0) writer.print(", ", .{}) catch {};
                    const entry = @field(value, field.name);
                    inspectWrite(writer, entry.key);
                    writer.print(": ", .{}) catch {};
                    inspectWrite(writer, entry.value);
                }
                writer.print("}}", .{}) catch {};
            } else {
                // Named struct — print as %{field: value, ...}
                writer.print("%{{", .{}) catch {};
                inline for (info.@"struct".fields, 0..) |field, i| {
                    if (i > 0) writer.print(", ", .{}) catch {};
                    writer.print("{s}: ", .{field.name}) catch {};
                    inspectWrite(writer, @field(value, field.name));
                }
                writer.print("}}", .{}) catch {};
            }
        } else if (info == .@"enum") {
            writer.print(":{s}", .{@tagName(value)}) catch {};
        } else {
            writer.print("{any}", .{value}) catch {};
        }
    }

    pub fn print_str(value: anytype) void {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdout.print("{s}", .{value}) catch {};
        } else {
            stdout.print("{any}", .{value}) catch {};
        }
    }

    pub fn i64_to_string(value: i64) []const u8 {
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn f64_to_string(value: f64) []const u8 {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
        const result = bumpAlloc(slice.len);
        if (result.len == 0) return "?";
        @memcpy(result, slice);
        return result;
    }

    pub fn bool_to_string(value: bool) []const u8 {
        return if (value) "true" else "false";
    }

    /// Generic to_string for string interpolation — handles all Zap types.
    /// Strings pass through; other types are formatted via bump allocator.
    pub fn to_string(value: anytype) []const u8 {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            return value;
        } else if (T == bool) {
            return if (value) "true" else "false";
        } else if (info == .int or info == .comptime_int) {
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
            const result = bumpAlloc(slice.len);
            if (result.len == 0) return "?";
            @memcpy(result, slice);
            return result;
        } else if (info == .float or info == .comptime_float) {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return "?";
            const result = bumpAlloc(slice.len);
            if (result.len == 0) return "?";
            @memcpy(result, slice);
            return result;
        } else if (info == .@"enum") {
            return @tagName(value);
        } else {
            return "<value>";
        }
    }

    pub fn string_to_i64(s: []const u8) ?i64 {
        return std.fmt.parseInt(i64, s, 10) catch null;
    }

    pub fn string_to_f64(s: []const u8) ?f64 {
        return std.fmt.parseFloat(f64, s) catch null;
    }

    pub fn abs_i64(x: i64) i64 {
        return if (x < 0) -x else x;
    }

    pub fn abs_f64(x: f64) f64 {
        return @abs(x);
    }

    pub fn max_i64(a: i64, b: i64) i64 {
        return @max(a, b);
    }

    pub fn min_i64(a: i64, b: i64) i64 {
        return @min(a, b);
    }

    pub fn max_f64(a: f64, b: f64) f64 {
        return @max(a, b);
    }

    pub fn min_f64(a: f64, b: f64) f64 {
        return @min(a, b);
    }

    pub fn atom_name(id: anytype) []const u8 {
        const T = @TypeOf(id);
        if (T == u32) return atomToString(id);
        if (@typeInfo(T) == .int) return atomToString(@intCast(id));
        return "<not_an_atom>";
    }

    pub fn get_env(name: []const u8) []const u8 {
        // Copy name to a null-terminated buffer, then use C getenv
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return "";
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const name_z: [*:0]const u8 = buf[0..name.len :0];
        const result = std.c.getenv(name_z);
        if (result) |ptr| {
            return std.mem.sliceTo(ptr, 0);
        }
        return "";
    }

    pub fn panic(msg: []const u8) noreturn {
        std.debug.print("panic: {s}\n", .{msg});
        std.process.exit(1);
    }

    // CLI argument access — use std.os.argv directly (no allocation)
    pub fn arg_count() i64 {
        const argv = std.os.argv;
        return if (argv.len > 0) @as(i64, @intCast(argv.len)) - 1 else 0;
    }

    pub fn arg_at(index: anytype) []const u8 {
        const argv = std.os.argv;
        const T = @TypeOf(index);
        const idx: usize = if (T == comptime_int or @typeInfo(T) == .int)
            @intCast(index)
        else
            0;
        // Index 0 = first user arg (skip program name)
        if (idx + 1 < argv.len) return std.mem.sliceTo(argv[idx + 1], 0);
        return "";
    }
};

// ============================================================
// BinaryHelpers — concrete binary pattern matching operations
// for ZIR builder (no generics, no comptime type params)
// ============================================================

pub const BinaryHelpers = struct {
    // --- Integer reads (byte-aligned) ---
    // Each function reads N bytes from data at the given byte offset
    // using big-endian byte order, returning a u64/i64.
    // The ZIR builder calls these because ZIR cannot express generic
    // std.mem.readInt calls with comptime type parameters.

    pub fn readIntU8(data: []const u8, offset: usize) u64 {
        if (offset >= data.len) return 0;
        return @intCast(data[offset]);
    }

    pub fn readIntU16Big(data: []const u8, offset: usize) u64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .big));
    }

    pub fn readIntU16Little(data: []const u8, offset: usize) u64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .little));
    }

    pub fn readIntU32Big(data: []const u8, offset: usize) u64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .big));
    }

    pub fn readIntU32Little(data: []const u8, offset: usize) u64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .little));
    }

    pub fn readIntU64Big(data: []const u8, offset: usize) u64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(u64, data[offset..][0..8], .big);
    }

    pub fn readIntU64Little(data: []const u8, offset: usize) u64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(u64, data[offset..][0..8], .little);
    }

    pub fn readIntI8(data: []const u8, offset: usize) i64 {
        if (offset >= data.len) return 0;
        return @intCast(@as(i8, @bitCast(data[offset])));
    }

    pub fn readIntI16Big(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(i16, data[offset..][0..2], .big));
    }

    pub fn readIntI16Little(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(i16, data[offset..][0..2], .little));
    }

    pub fn readIntI32Big(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(i32, data[offset..][0..4], .big));
    }

    pub fn readIntI32Little(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(i32, data[offset..][0..4], .little));
    }

    pub fn readIntI64Big(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(i64, data[offset..][0..8], .big);
    }

    pub fn readIntI64Little(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return std.mem.readInt(i64, data[offset..][0..8], .little);
    }

    // Sub-byte read: extract `bits` bits from data[offset] >> bit_offset
    pub fn readBitsU(data: []const u8, offset: usize, bit_offset: u3, bits: u8) u64 {
        if (offset >= data.len) return 0;
        const shifted: u8 = data[offset] >> bit_offset;
        if (bits == 0 or bits >= 8) return @intCast(shifted);
        const mask: u8 = (@as(u8, 1) << @intCast(bits)) - 1;
        return @intCast(shifted & mask);
    }

    // --- Float reads ---
    pub fn readF32Big(data: []const u8, offset: usize) f64 {
        if (offset + 4 > data.len) return 0.0;
        const int_val = std.mem.readInt(u32, data[offset..][0..4], .big);
        return @floatCast(@as(f32, @bitCast(int_val)));
    }

    pub fn readF32Little(data: []const u8, offset: usize) f64 {
        if (offset + 4 > data.len) return 0.0;
        const int_val = std.mem.readInt(u32, data[offset..][0..4], .little);
        return @floatCast(@as(f32, @bitCast(int_val)));
    }

    pub fn readF64Big(data: []const u8, offset: usize) f64 {
        if (offset + 8 > data.len) return 0.0;
        const int_val = std.mem.readInt(u64, data[offset..][0..8], .big);
        return @bitCast(int_val);
    }

    pub fn readF64Little(data: []const u8, offset: usize) f64 {
        if (offset + 8 > data.len) return 0.0;
        const int_val = std.mem.readInt(u64, data[offset..][0..8], .little);
        return @bitCast(int_val);
    }

    // --- Slice ---
    // Returns data[offset..offset+length], or data[offset..] if length == 0 (sentinel for "rest")
    pub fn slice(data: []const u8, offset: usize, length: usize) []const u8 {
        const start = @min(offset, data.len);
        if (length == 0) return data[start..];
        const end = @min(std.math.add(usize, start, length) catch data.len, data.len);
        return data[start..end];
    }

    // --- UTF-8 reads ---
    // Returns the byte sequence length for the UTF-8 character at data[offset]
    pub fn utf8ByteLen(data: []const u8, offset: usize) u64 {
        if (offset >= data.len) return 1;
        return @intCast(std.unicode.utf8ByteSequenceLength(data[offset]) catch 1);
    }

    // Returns the decoded codepoint for the UTF-8 character at data[offset..offset+len]
    pub fn utf8Decode(data: []const u8, offset: usize, len: usize) u64 {
        if (offset + len > data.len or len == 0 or len > 4) return 0xFFFD;
        const end = offset + len;
        const byte_slice = data[offset..end];
        // utf8Decode expects a fixed-size array per length
        return switch (len) {
            1 => @intCast(byte_slice[0]),
            2 => @intCast(std.unicode.utf8Decode(byte_slice[0..2].*) catch 0xFFFD),
            3 => @intCast(std.unicode.utf8Decode(byte_slice[0..3].*) catch 0xFFFD),
            4 => @intCast(std.unicode.utf8Decode(byte_slice[0..4].*) catch 0xFFFD),
            else => 0xFFFD,
        };
    }

    // --- Prefix matching ---
    // Returns true if data starts with the expected prefix
    pub fn matchPrefix(data: []const u8, expected: []const u8) bool {
        if (data.len < expected.len) return false;
        return std.mem.eql(u8, data[0..expected.len], expected);
    }
};

// ============================================================
// MapHelpers — Operations on map values (anonymous structs of {key, value} entries)
//
// Maps in ZIR are represented as anonymous structs with numeric field names:
//   .{ .@"0" = .{ .key = k0, .value = v0 }, .@"1" = .{ .key = k1, .value = v1 }, ... }
//
// These helpers use @typeInfo + inline for to iterate entries at compile time,
// producing efficient code with no runtime overhead for small maps.
// ============================================================

pub const MapHelpers = struct {
    /// Get a value from a map by key. Returns the value if found, or a default.
    /// Usage: MapHelpers.get(map, key, default)
    pub fn get(map: anytype, key: anytype, default: anytype) @TypeOf(default) {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return default;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                // Check if this entry has key and value fields
                const is_kv_entry = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_kv_entry) {
                    if (keysEqual(entry.key, key)) return entry.value;
                }
            }
        }
        return default;
    }

    /// Check if a map contains a key.
    pub fn has_key(map: anytype, key: anytype) bool {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                const is_entry = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_entry) {
                    if (keysEqual(entry.key, key)) return true;
                }
            }
        }
        return false;
    }

    /// Get the number of entries in a map.
    pub fn size(map: anytype) i64 {
        const T = @TypeOf(map);
        const info = @typeInfo(T);
        if (info != .@"struct") return 0;
        return @intCast(info.@"struct".fields.len);
    }

    /// Compare two keys, handling atom IDs (u32), strings, and integers.
    fn keysEqual(a: anytype, b: anytype) bool {
        const A = @TypeOf(a);
        const B = @TypeOf(b);
        if (A == B) {
            if (A == []const u8) return std.mem.eql(u8, a, b);
            return a == b;
        }
        // Cross-type comparison for atom IDs
        if ((@typeInfo(A) == .int or @typeInfo(A) == .comptime_int) and
            (@typeInfo(B) == .int or @typeInfo(B) == .comptime_int))
        {
            return a == b;
        }
        return false;
    }
};

// ============================================================
// Tests
// ============================================================

test "Arc basic reference counting" {
    const alloc = std.testing.allocator;
    const arc = try Arc(i64).init(alloc, 42);
    try std.testing.expectEqual(@as(u32, 1), arc.refCount());
    try std.testing.expectEqual(@as(i64, 42), arc.get().*);

    const arc2 = arc.retain();
    try std.testing.expectEqual(@as(u32, 2), arc.refCount());

    arc2.release(alloc);
    try std.testing.expectEqual(@as(u32, 1), arc.refCount());

    arc.release(alloc);
}

test "ArcRuntime.allocAny creates arc-managed value" {
    const val = ArcRuntime.allocAny(i64, std.testing.allocator, 42);
    defer ArcRuntime.freeAny(i64, std.testing.allocator, val);
    try std.testing.expectEqual(@as(i64, 42), val.*);
}

test "ArcRuntime.retainAny and refCountAny" {
    const val = ArcRuntime.allocAny(i64, std.testing.allocator, 99);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(i64, val));

    ArcRuntime.retainAny(i64, val);
    try std.testing.expectEqual(@as(u32, 2), ArcRuntime.refCountAny(i64, val));

    // First free decrements but doesn't deallocate
    ArcRuntime.freeAny(i64, std.testing.allocator, val);
    try std.testing.expectEqual(@as(u32, 1), ArcRuntime.refCountAny(i64, val));

    // Second free deallocates
    ArcRuntime.freeAny(i64, std.testing.allocator, val);
}

test "Arc struct value" {
    const alloc = std.testing.allocator;
    const Point = struct { x: f64, y: f64 };
    const arc = try Arc(Point).init(alloc, .{ .x = 1.0, .y = 2.0 });
    try std.testing.expectEqual(@as(f64, 1.0), arc.getConst().x);
    try std.testing.expectEqual(@as(f64, 2.0), arc.getConst().y);
    arc.release(alloc);
}

test "Atom well-known values" {
    try std.testing.expectEqual(@as(u32, 0), Atom.nil.id);
    try std.testing.expectEqual(@as(u32, 1), Atom.true.id);
    try std.testing.expect(Atom.nil.eql(Atom.nil));
    try std.testing.expect(!Atom.nil.eql(Atom.true));
}

test "AtomTable intern and retrieve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var table = AtomTable.init(alloc);
    defer table.deinit();

    const hello = try table.intern("hello");
    const world = try table.intern("world");
    const hello2 = try table.intern("hello");

    try std.testing.expect(hello.eql(hello2));
    try std.testing.expect(!hello.eql(world));
    try std.testing.expectEqualStrings("hello", table.getName(hello));
    try std.testing.expectEqualStrings("world", table.getName(world));

    // Well-known atoms should exist
    try std.testing.expectEqualStrings("nil", table.getName(Atom.nil));
    try std.testing.expectEqualStrings("true", table.getName(Atom.true));
}

test "List cons and hd/tl" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var list = List(i64).empty;
    list = try list.cons(alloc, 3);
    list = try list.cons(alloc, 2);
    list = try list.cons(alloc, 1);

    try std.testing.expectEqual(@as(usize, 3), list.length());
    try std.testing.expectEqual(@as(i64, 1), list.hd().?);
    try std.testing.expectEqual(@as(i64, 2), list.tl().hd().?);
    try std.testing.expectEqual(@as(i64, 3), list.tl().tl().hd().?);
    try std.testing.expect(list.tl().tl().tl().isEmpty());
}

test "List fromSlice and toSlice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = [_]i64{ 10, 20, 30 };
    const list = try List(i64).fromSlice(alloc, &items);

    const slice = try list.toSlice(alloc);

    try std.testing.expectEqual(@as(usize, 3), slice.len);
    try std.testing.expectEqual(@as(i64, 10), slice[0]);
    try std.testing.expectEqual(@as(i64, 20), slice[1]);
    try std.testing.expectEqual(@as(i64, 30), slice[2]);
}

test "ZapMap put and get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = ZapMap(i64, i64).init(alloc);
    map = try map.put(1, 100);
    map = try map.put(2, 200);

    try std.testing.expectEqual(@as(usize, 2), map.size());
    try std.testing.expectEqual(@as(i64, 100), map.get(1).?);
    try std.testing.expectEqual(@as(i64, 200), map.get(2).?);
    try std.testing.expect(map.get(3) == null);
}

test "ZapMap update existing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = ZapMap(i64, i64).init(alloc);
    map = try map.put(1, 100);
    const map2 = try map.put(1, 999);

    try std.testing.expectEqual(@as(usize, 1), map2.size());
    try std.testing.expectEqual(@as(i64, 999), map2.get(1).?);
    // Original is unchanged
    try std.testing.expectEqual(@as(i64, 100), map.get(1).?);
}

test "ZapMap delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = ZapMap(i64, i64).init(alloc);
    map = try map.put(1, 100);
    map = try map.put(2, 200);
    const map2 = try map.delete(1);

    try std.testing.expectEqual(@as(usize, 1), map2.size());
    try std.testing.expect(map2.get(1) == null);
    try std.testing.expectEqual(@as(i64, 200), map2.get(2).?);
}

test "ZapString operations" {
    try std.testing.expect(ZapString.contains("hello world", "world"));
    try std.testing.expect(!ZapString.contains("hello world", "xyz"));
    try std.testing.expect(ZapString.startsWith("hello", "hel"));
    try std.testing.expect(ZapString.endsWith("hello", "llo"));
    try std.testing.expectEqualStrings("llo", ZapString.slice("hello", 2, 5));
    try std.testing.expectEqualStrings("hello", ZapString.trim("  hello  "));
}

test "ZapString concat" {
    const alloc = std.testing.allocator;
    const result = try ZapString.concat(alloc, "hello", " world");
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "TaggedValue equality" {
    const a: TaggedValue = .{ .int = 42 };
    const b: TaggedValue = .{ .int = 42 };
    const c: TaggedValue = .{ .int = 99 };
    const d: TaggedValue = .{ .string = "hello" };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
}

test "TaggedValue truthiness" {
    try std.testing.expect(!(TaggedValue{ .nil = {} }).isTruthy());
    try std.testing.expect(!(TaggedValue{ .bool_val = false }).isTruthy());
    try std.testing.expect((TaggedValue{ .bool_val = true }).isTruthy());
    try std.testing.expect((TaggedValue{ .int = 0 }).isTruthy());
    try std.testing.expect((TaggedValue{ .string = "" }).isTruthy());
}
