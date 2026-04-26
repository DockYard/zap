const std = @import("std");
const builtin = @import("builtin");
const env = @import("env.zig");

const STDOUT_FD = std.posix.STDOUT_FILENO;
const STDERR_FD = std.posix.STDERR_FILENO;
const STDIN_FD = std.posix.STDIN_FILENO;

// Well-known atom IDs — must match the registration order in initGlobalAtomTable
// and AtomTable.init: nil=0, true=1, false=2, ok=3, error=4, cont=5, halt=6, done=7
pub const ATOM_CONT: u32 = 5;
pub const ATOM_HALT: u32 = 6;
pub const ATOM_DONE: u32 = 7;

fn posixWrite(fd: std.posix.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes[written..].len);
        if (rc <= 0) break;
        written += @intCast(rc);
    }
}

fn posixRead(fd: std.posix.fd_t, buf: []u8) usize {
    return std.posix.read(fd, buf) catch 0;
}

/// Platform-portable access to process argv (replacement for removed getArgv() in 0.16).
pub fn getArgv() []const [*:0]const u8 {
    if (comptime builtin.os.tag == .macos) {
        const c = struct {
            extern "c" fn _NSGetArgc() *c_int;
            extern "c" fn _NSGetArgv() *[*]const [*:0]const u8;
        };
        const argc: usize = @intCast(c._NSGetArgc().*);
        const argv = c._NSGetArgv().*;
        return argv[0..argc];
    } else if (comptime builtin.os.tag == .linux) {
        // On Linux, use /proc/self/cmdline as fallback or linker-provided __libc_argv.
        const c = struct {
            extern "c" var __libc_argc: c_int;
            extern "c" var __libc_argv: [*]const [*:0]const u8;
        };
        const argc: usize = @intCast(c.__libc_argc);
        return c.__libc_argv[0..argc];
    } else {
        return &.{};
    }
}

/// Write formatted output to stdout using POSIX write.
fn stdoutPrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    posixWrite(STDOUT_FD, msg);
}

/// Write raw bytes to stdout.
fn stdoutWrite(bytes: []const u8) void {
    posixWrite(STDOUT_FD, bytes);
}

// ============================================================
// Arena Allocator
// Uses std.heap.ArenaAllocator backed by page_allocator.
// Thread-safe and lock-free in Zig 0.16. Init is cheap (no
// allocation until first use), so no lazy initialization needed.
// ============================================================

var runtime_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

// Terminal mode state for raw/normal switching
var original_termios: std.posix.termios = undefined;
var raw_mode_saved: bool = false;

fn bumpAlloc(len: usize) []u8 {
    // Use alignedAlloc with pointer alignment (8 on 64-bit) so that bump-allocated
    // memory can safely be cast to pointer types via @ptrCast(@alignCast(...)).
    const aligned = runtime_arena.allocator().alignedAlloc(u8, .@"8", len) catch return &.{};
    return @alignCast(aligned);
}

fn bumpAllocSlice(comptime T: type, len: usize) []T {
    return runtime_arena.allocator().alloc(T, len) catch return &.{};
}

pub fn resetAllocator() void {
    runtime_arena.reset(.retain_capacity);
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
//   - Map(K, V)    — persistent map (HAMT-based)
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
        const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error", "cont", "halt", "done" };
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
    const builtins = [_][]const u8{ "nil", "true", "false", "ok", "error", "cont", "halt", "done" };
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
    /// Construct Zap.Env from getArgv().
    /// argv[0] = binary, argv[1] = target, argv[2] = os, argv[3] = arch
    pub fn buildEnvFromArgv() struct { target: u32, os: u32, arch: u32 } {
        const argv = getArgv();
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
                inline for (info.@"struct".fields) |field| {
            const value = @field(manifest, field.name);
            const FT = @TypeOf(value);
            if (FT == []const u8) {
                stdoutPrint("{s}={s}\n", .{ field.name, value });
            } else if (FT == u32) {
                stdoutPrint("{s}={s}\n", .{ field.name, atomToString(value) });
            } else if (@typeInfo(FT) == .int) {
                stdoutPrint("{s}={d}\n", .{ field.name, value });
            } else if (FT == bool) {
                stdoutPrint("{s}={}\n", .{ field.name, value });
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
// String — String utilities
// ============================================================

pub const String = struct {
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

    /// Concatenate two strings into a fresh allocation backed by the
    /// runtime arena. Zap-emitted code calls this directly because Zap
    /// has no notion of allocators at the call site.
    pub fn concat(a: []const u8, b: []const u8) []const u8 {
        const result = bumpAlloc(a.len + b.len);
        if (result.len == 0) return a; // fallback: return first string
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }

    pub fn length(s: []const u8) i64 {
        return @intCast(s.len);
    }

    pub fn slice(s: []const u8, start: i64, end: i64) []const u8 {
        const safe_start: usize = if (start >= 0) @intCast(start) else 0;
        const safe_end: usize = if (end >= 0) @intCast(end) else 0;
        const s_end = @min(safe_end, s.len);
        const s_start = @min(safe_start, s_end);
        return s[s_start..s_end];
    }

    pub fn contains(haystack: []const u8, needle: []const u8) bool {
        return std.mem.find(u8, haystack, needle) != null;
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

    /// Get byte at index as a single-character string.
    pub fn byte_at(s: []const u8, index: i64) []const u8 {
        const i: usize = if (index >= 0) @intCast(index) else return "";
        if (i >= s.len) return "";
        const result = bumpAlloc(1);
        if (result.len == 0) return "";
        result[0] = s[i];
        return result;
    }

    // Forwarding functions for string operations that live on Prelude.
    // These provide the :zig.String.* namespace for all string ops.
    pub const upcase = Prelude.upcase;
    pub const downcase = Prelude.downcase;
    pub const reverse_string = Prelude.reverse_string;
    pub const replace_string = Prelude.replace_string;
    pub const index_of = Prelude.index_of;
    pub const pad_leading = Prelude.pad_leading;
    pub const pad_trailing = Prelude.pad_trailing;
    pub const repeat_string = Prelude.repeat_string;
    pub const capitalize = Prelude.capitalize;
    pub const trim_leading = Prelude.trim_leading;
    pub const trim_trailing = Prelude.trim_trailing;
    pub const string_count = Prelude.string_count;
    pub const split_to_list = Prelude.split_to_list;
    pub const string_join = Prelude.string_join;
};

// ============================================================
// Prelude / Kernel functions (spec §30.2)
// ============================================================

pub fn panic(message: []const u8) noreturn {
        posixWrite(STDERR_FD, "** (NilError) ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
    std.process.exit(1);
}

pub const Range = struct {
    /// Iterator protocol for ranges.
    /// Uses the range struct as its own state — `start` is the current position.
    /// Returns {:cont, current, next_range} or {:done, 0, nil_range}.
    pub fn next(range: anytype) @TypeOf(.{ .@"0" = @as(u32, 0), .@"1" = @as(i64, 0), .@"2" = range }) {
        const start = range.start;
        const end_val = range.end;
        const step_mag = range.step;
        const going_forward = start <= end_val;

        // Check if done
        const done = if (going_forward) start > end_val else start < end_val;
        if (done) {
            return .{ .@"0" = ATOM_DONE, .@"1" = 0, .@"2" = range };
        }

        // Advance: create next range with updated start
        const step: i64 = if (going_forward) step_mag else -step_mag;
        var next_range = range;
        next_range.start = start + step;
        return .{ .@"0" = ATOM_CONT, .@"1" = start, .@"2" = next_range };
    }

    pub fn to_list(range: anytype) ?*const List(i64) {
        const start = range.start;
        const end_val = range.end;
        const step_mag = range.step;
        if (step_mag == 0) return null;

        const going_forward = start <= end_val;
        const step: i64 = if (going_forward) step_mag else -step_mag;

        var result: ?*const List(i64) = null;
        var current = start;

        if (going_forward) {
            while (current <= end_val) {
                result = List(i64).cons(current, result);
                current += step;
            }
        } else {
            while (current >= end_val) {
                result = List(i64).cons(current, result);
                current += step;
            }
        }
        return List(i64).reverse(result);
    }
};

pub const Kernel = struct {
    /// Generic to_string for string interpolation — delegates to Prelude.to_string.
    pub const to_string = Prelude.to_string;

    pub fn is_integer(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        return info == .int or info == .comptime_int;
    }

    pub fn is_float(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        return info == .float or info == .comptime_float;
    }

    pub fn is_number(value: anytype) bool {
        return is_integer(value) or is_float(value);
    }

    pub fn is_boolean(value: anytype) bool {
        return @TypeOf(value) == bool;
    }

    pub fn is_string(value: anytype) bool {
        const T = @TypeOf(value);
        if (T == []const u8) return true;
        const info = @typeInfo(T);
        if (info == .pointer) {
            const child = std.meta.Child(T);
            return @typeInfo(child) == .array and std.meta.Elem(child) == u8;
        }
        return false;
    }

    pub fn is_atom(value: anytype) bool {
        // Atoms are represented as u32 at runtime
        return @TypeOf(value) == u32;
    }

    pub fn is_nil(value: anytype) bool {
        const T = @TypeOf(value);
        if (T == @TypeOf(null)) return true;
        const info = @typeInfo(T);
        if (info == .optional) {
            return value == null;
        }
        return false;
    }

    pub fn is_list(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .optional) {
            const child = @typeInfo(info.optional.child);
            if (child == .pointer and child.pointer.size == .one) {
                return @hasField(child.pointer.child, "head") and @hasField(child.pointer.child, "tail");
            }
        }
        return false;
    }

    pub fn is_tuple(value: anytype) bool {
        const T = @TypeOf(value);
        const info = @typeInfo(T);
        return info == .@"struct" and info.@"struct".is_tuple;
    }

    pub fn is_map(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .optional) {
            const child = @typeInfo(info.optional.child);
            if (child == .pointer and child.pointer.size == .one) {
                return @hasField(child.pointer.child, "entries") and @hasField(child.pointer.child, "size");
            }
        }
        return false;
    }

    pub fn is_struct(value: anytype) bool {
        const info = @typeInfo(@TypeOf(value));
        if (info == .@"struct" and !info.@"struct".is_tuple) return true;
        if (info == .pointer) {
            const child = @typeInfo(std.meta.Child(@TypeOf(value)));
            if (child == .@"struct" and !child.@"struct".is_tuple) return true;
        }
        return false;
    }

    pub fn raise(message: []const u8) noreturn {
        posixWrite(STDERR_FD, "** (RuntimeError) ");
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    // Operator primitives backing the generic `pub fn ==`/`!=`/`<`/`>`/
    // `<=`/`>=` in lib/kernel.zap. The Zap monomorphizer specializes the
    // Kernel operator per concrete type pair, so each instantiation here
    // sees a concrete `T` and Zig's comptime dispatch picks the right
    // operation (`std.mem.eql` for slices, `==` for value types, etc.).

    pub fn eq(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.eql(u8, a, b);
        return a == b;
    }

    pub fn neq(a: anytype, b: anytype) bool {
        return !eq(a, b);
    }

    pub fn lt(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.lessThan(u8, a, b);
        return a < b;
    }

    pub fn gt(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return std.mem.lessThan(u8, b, a);
        return a > b;
    }

    pub fn lte(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return !std.mem.lessThan(u8, b, a);
        return a <= b;
    }

    pub fn gte(a: anytype, b: anytype) bool {
        const T = @TypeOf(a);
        if (comptime T == []const u8) return !std.mem.lessThan(u8, a, b);
        return a >= b;
    }

    pub fn add(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a +% b;
        return a + b;
    }

    pub fn sub(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a -% b;
        return a - b;
    }

    pub fn mul(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return a *% b;
        return a * b;
    }

    pub fn divide(a: anytype, b: anytype) @TypeOf(a) {
        const T = @TypeOf(a);
        const info = @typeInfo(T);
        if (comptime info == .int) return @divTrunc(a, b);
        return a / b;
    }

    pub fn remainder(a: anytype, b: anytype) @TypeOf(a) {
        return @rem(a, b);
    }

    pub fn sleep(milliseconds: i64) i64 {
        if (milliseconds <= 0) return milliseconds;
        const ms: u64 = @intCast(milliseconds);
        var ts = std.posix.timespec{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        };
        while (true) {
            const rc = std.c.nanosleep(&ts, &ts);
            if (rc == 0) break;
            if (std.posix.errno(rc) != .INTR) break;
        }
        return milliseconds;
    }
};

/// Simple fixed-buffer writer for inspect formatting.
/// Replaces the std.Io.File writer with direct buffer writes.
const BufWriter = struct {
    buf: []u8,
    pos: usize,

    pub fn print(self: *BufWriter, comptime fmt: []const u8, args: anytype) !void {
        const remaining = self.buf[self.pos..];
        const result = std.fmt.bufPrint(remaining, fmt, args) catch return;
        self.pos += result.len;
    }
};

pub const Prelude = struct {
    pub fn println(value: anytype) void {
                const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdoutPrint("{s}\n", .{value});
        } else if (info == .int or info == .comptime_int) {
            stdoutPrint("{d}\n", .{value});
        } else if (info == .float or info == .comptime_float) {
            stdoutPrint("{d}\n", .{value});
        } else if (T == bool) {
            stdoutPrint("{}\n", .{value});
        } else if (info == .@"enum") {
            stdoutPrint(":{s}\n", .{@tagName(value)});
        } else if (T == u32) {
            // Could be an atom ID — print as atom if it looks up
            const name = atomToString(value);
            if (!std.mem.eql(u8, name, "<unknown_atom>")) {
                stdoutPrint(":{s}\n", .{name});
            } else {
                stdoutPrint("{d}\n", .{value});
            }
        } else {
            // For tuples, structs, and other compound types, use inspect formatting
            var iw_buf: [4096]u8 = undefined;
            var iw = BufWriter{ .buf = &iw_buf, .pos = 0 };
            inspectWrite(&iw, value);
            posixWrite(STDOUT_FD, iw_buf[0..iw.pos]);
            stdoutPrint("\n", .{});
        }
    }

    pub fn inspect(value: anytype) InspectReturn(@TypeOf(value)) {
        var iw_buf: [4096]u8 = undefined;
        var iw = BufWriter{ .buf = &iw_buf, .pos = 0 };
        inspectWrite(&iw, value);
        posixWrite(STDOUT_FD, iw_buf[0..iw.pos]);
        stdoutPrint("\n", .{});
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
            const rounded: i64 = @trunc(value);
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
                const T = @TypeOf(value);
        const info = @typeInfo(T);
        if (T == []const u8 or (info == .pointer and @typeInfo(std.meta.Child(T)) == .array)) {
            stdoutPrint("{s}", .{value});
        } else {
            stdoutPrint("{any}", .{value});
        }
    }

    /// Read a line from stdin. Returns the line without the trailing newline.
    /// Returns an empty string on EOF or error.
    pub fn gets() []const u8 {
        var buf: [4096]u8 = undefined;
        var len: usize = 0;
        // Read one byte at a time until newline or EOF
        while (len < buf.len - 1) {
            var one_buf = [_]u8{0};
            const n = posixRead(STDIN_FD, &one_buf);
            if (n == 0) break; // EOF
            if (one_buf[0] == '\n') break;
            buf[len] = one_buf[0];
            len += 1;
        }
        // Strip trailing \r if present (Windows line endings)
        if (len > 0 and buf[len - 1] == '\r') len -= 1;
        if (len == 0) return "";
        const result = bumpAlloc(len);
        if (result.len == 0) return "";
        @memcpy(result, buf[0..len]);
        return result;
    }

    /// Write a string to stderr followed by a newline.
    /// Switch terminal mode. Accepts u32 atom ID — checks atom name for "Raw".
    pub fn set_terminal_mode(mode: u32) void {
        const posix = std.posix;
        const stdin_fd = posix.STDIN_FILENO;
        const is_raw = std.mem.eql(u8, atomToString(mode), "Raw");
        if (is_raw) {
            // Raw mode: disable canonical mode and echo
            var termios = posix.tcgetattr(stdin_fd) catch return;
            // Save original settings on first call
            if (!raw_mode_saved) {
                original_termios = termios;
                raw_mode_saved = true;
            }
            termios.lflag.ICANON = false;
            termios.lflag.ECHO = false;
            // Read returns after 1 byte
            termios.cc[@intFromEnum(posix.V.MIN)] = 1;
            termios.cc[@intFromEnum(posix.V.TIME)] = 0;
            posix.tcsetattr(stdin_fd, .FLUSH, termios) catch return;
        } else {
            // Normal mode: restore original settings
            if (raw_mode_saved) {
                posix.tcsetattr(stdin_fd, .FLUSH, original_termios) catch return;
            }
        }
    }

    /// Non-blocking read of a single character from stdin.
    /// Returns a 1-byte string if a key is available, or "" if not.
    /// Must be in raw mode for meaningful use.
    pub fn try_get_char() []const u8 {
        const posix = std.posix;
        const stdin_fd = posix.STDIN_FILENO;
        const POLLIN: i16 = 0x0001;

        // poll with timeout 0 = return immediately
        var fds = [_]std.c.pollfd{.{
            .fd = stdin_fd,
            .events = POLLIN,
            .revents = 0,
        }};
        const ready = posix.poll(&fds, 0) catch return "";
        if (ready == 0) return "";

        // Data available — read one byte
        var one_buf = [_]u8{0};
        const n = posixRead(STDIN_FD, &one_buf);
        if (n == 0) return "";
        const result_buf = bumpAlloc(1);
        if (result_buf.len == 0) return "";
        result_buf[0] = one_buf[0];
        return result_buf;
    }

    /// Read a single character from stdin. Returns a 1-byte string.
    /// In raw mode, returns immediately after one keypress.
    /// In normal mode, blocks until Enter then returns first char.
    pub fn get_char() []const u8 {
        var one_buf = [_]u8{0};
        const n = posixRead(STDIN_FD, &one_buf);
        if (n == 0) return "";
        const result = bumpAlloc(1);
        if (result.len == 0) return "";
        result[0] = one_buf[0];
        return result;
    }

    pub fn warn(message: []const u8) void {
        posixWrite(STDERR_FD, message);
        posixWrite(STDERR_FD, "\n");
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

    /// Parse string to i64, returning 0 on failure (non-optional).
    pub fn parse_i64(s: []const u8) i64 {
        return std.fmt.parseInt(i64, s, 10) catch 0;
    }

    /// Parse string to f64, returning 0.0 on failure (non-optional).
    pub fn parse_f64(s: []const u8) f64 {
        return std.fmt.parseFloat(f64, s) catch 0.0;
    }

    pub fn div_i64(a: i64, b: i64) i64 {
        if (b == 0) return 0;
        return @divTrunc(a, b);
    }

    pub fn rem_i64(a: i64, b: i64) i64 {
        if (b == 0) return 0;
        return @rem(a, b);
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

    // --- Float math ---
    pub fn round_f64(x: f64) f64 {
        return @round(x);
    }

    pub fn floor_f64(x: f64) f64 {
        return @floor(x);
    }

    pub fn ceil_f64(x: f64) f64 {
        return @ceil(x);
    }

    pub fn trunc_f64(x: f64) f64 {
        return @trunc(x);
    }

    pub fn f64_to_i64(x: f64) i64 {
        return @trunc(x);
    }

    pub fn i64_to_f64(x: i64) f64 {
        return @floatFromInt(x);
    }

    // --- Math functions (Zig 0.16 float builtins) ---
    pub fn sqrt_f64(x: f64) f64 {
        return @sqrt(x);
    }

    pub fn sin_f64(x: f64) f64 {
        return @sin(x);
    }

    pub fn cos_f64(x: f64) f64 {
        return @cos(x);
    }

    pub fn tan_f64(x: f64) f64 {
        return @tan(x);
    }

    pub fn exp_f64(x: f64) f64 {
        return @exp(x);
    }

    pub fn exp2_f64(x: f64) f64 {
        return @exp2(x);
    }

    pub fn log_f64(x: f64) f64 {
        return @log(x);
    }

    pub fn log2_f64(x: f64) f64 {
        return @log2(x);
    }

    pub fn log10_f64(x: f64) f64 {
        return @log10(x);
    }

    // --- Float-to-integer conversions (Zig 0.16 direct builtins) ---
    pub fn floor_to_i64(x: f64) i64 {
        return @floor(x);
    }

    pub fn ceil_to_i64(x: f64) i64 {
        return @ceil(x);
    }

    pub fn round_to_i64(x: f64) i64 {
        return @round(x);
    }

    // --- Integer bit operations ---
    pub fn clz_i64(x: i64) i64 {
        return @intCast(@clz(x));
    }

    pub fn ctz_i64(x: i64) i64 {
        return @intCast(@ctz(x));
    }

    pub fn popcount_i64(x: i64) i64 {
        return @intCast(@popCount(x));
    }

    pub fn byte_swap_i64(x: i64) i64 {
        return @byteSwap(x);
    }

    pub fn bit_reverse_i64(x: i64) i64 {
        return @bitReverse(x);
    }

    // --- Integer predicates ---
    pub fn sign_i64(x: i64) i64 {
        if (x > 0) return 1;
        if (x < 0) return -1;
        return 0;
    }

    pub fn even_i64(x: i64) bool {
        return @rem(x, 2) == 0;
    }

    pub fn odd_i64(x: i64) bool {
        return @rem(x, 2) != 0;
    }

    pub fn gcd_i64(a: i64, b: i64) i64 {
        var x = if (a < 0) -a else a;
        var y = if (b < 0) -b else b;
        while (y != 0) {
            const t = y;
            y = @rem(x, t);
            x = t;
        }
        return x;
    }

    pub fn lcm_i64(a: i64, b: i64) i64 {
        if (a == 0 and b == 0) return 0;
        const g = gcd_i64(a, b);
        if (g == 0) return 0;
        const abs_a = if (a < 0) -a else a;
        const abs_b = if (b < 0) -b else b;
        return @divTrunc(abs_a, g) * abs_b;
    }

    // --- Saturating arithmetic ---
    pub fn add_sat_i64(a: i64, b: i64) i64 {
        return a +| b;
    }

    pub fn sub_sat_i64(a: i64, b: i64) i64 {
        return a -| b;
    }

    pub fn mul_sat_i64(a: i64, b: i64) i64 {
        return a *| b;
    }

    // --- Bitwise operations ---
    pub fn band_i64(a: i64, b: i64) i64 {
        return a & b;
    }

    pub fn bor_i64(a: i64, b: i64) i64 {
        return a | b;
    }

    pub fn bxor_i64(a: i64, b: i64) i64 {
        return a ^ b;
    }

    pub fn bnot_i64(a: i64) i64 {
        return ~a;
    }

    pub fn bsl_i64(a: i64, b: i64) i64 {
        if (b < 0 or b >= 64) return 0;
        const shift: u6 = @intCast(b);
        return a << shift;
    }

    pub fn bsr_i64(a: i64, b: i64) i64 {
        if (b < 0 or b >= 64) return if (a < 0) -1 else 0;
        const shift: u6 = @intCast(b);
        return a >> shift;
    }

    // --- String operations ---
    pub fn capitalize(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        result[0] = if (s[0] >= 'a' and s[0] <= 'z') s[0] - 32 else s[0];
        for (s[1..], 0..) |c, i| {
            result[i + 1] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    pub fn trim_leading(s: []const u8) []const u8 {
        return std.mem.trimStart(u8, s, " \t\n\r");
    }

    pub fn trim_trailing(s: []const u8) []const u8 {
        return std.mem.trimEnd(u8, s, " \t\n\r");
    }

    pub fn string_count(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        var count: i64 = 0;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                count += 1;
                i += needle.len;
            } else {
                i += 1;
            }
        }
        return count;
    }

    pub fn upcase(s: []const u8) []const u8 {
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        return result;
    }

    pub fn downcase(s: []const u8) []const u8 {
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
        }
        return result;
    }

    pub fn reverse_string(s: []const u8) []const u8 {
        if (s.len == 0) return s;
        const result = bumpAlloc(s.len);
        if (result.len == 0) return s;
        for (s, 0..) |c, i| {
            result[s.len - 1 - i] = c;
        }
        return result;
    }

    pub fn replace_string(s: []const u8, pattern: []const u8, replacement: []const u8) []const u8 {
        if (pattern.len == 0) return s;
        // Count occurrences first
        var count: usize = 0;
        var pos: usize = 0;
        while (pos + pattern.len <= s.len) {
            if (std.mem.eql(u8, s[pos .. pos + pattern.len], pattern)) {
                count += 1;
                pos += pattern.len;
            } else {
                pos += 1;
            }
        }
        if (count == 0) return s;
        const new_len = s.len - (count * pattern.len) + (count * replacement.len);
        const result = bumpAlloc(new_len);
        if (result.len == 0) return s;
        var src: usize = 0;
        var dst: usize = 0;
        while (src < s.len) {
            if (src + pattern.len <= s.len and std.mem.eql(u8, s[src .. src + pattern.len], pattern)) {
                @memcpy(result[dst .. dst + replacement.len], replacement);
                dst += replacement.len;
                src += pattern.len;
            } else {
                result[dst] = s[src];
                dst += 1;
                src += 1;
            }
        }
        return result;
    }

    pub fn index_of(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        if (needle.len > haystack.len) return -1;
        if (std.mem.find(u8, haystack, needle)) |idx| {
            return @intCast(idx);
        }
        return -1;
    }

    pub fn pad_leading(s: []const u8, total_len: i64, pad_char: []const u8) []const u8 {
        const target: usize = if (total_len > 0) @intCast(total_len) else return s;
        if (s.len >= target) return s;
        const pad_count = target - s.len;
        const result = bumpAlloc(target);
        if (result.len == 0) return s;
        const fill: u8 = if (pad_char.len > 0) pad_char[0] else ' ';
        @memset(result[0..pad_count], fill);
        @memcpy(result[pad_count..target], s);
        return result;
    }

    pub fn pad_trailing(s: []const u8, total_len: i64, pad_char: []const u8) []const u8 {
        const target: usize = if (total_len > 0) @intCast(total_len) else return s;
        if (s.len >= target) return s;
        const result = bumpAlloc(target);
        if (result.len == 0) return s;
        @memcpy(result[0..s.len], s);
        const fill: u8 = if (pad_char.len > 0) pad_char[0] else ' ';
        @memset(result[s.len..target], fill);
        return result;
    }

    /// Split a string by delimiter, returning a List([]const u8) (linked list of strings).
    pub fn split_to_list(s: []const u8, delimiter: []const u8) ?*const List([]const u8) {
        if (delimiter.len == 0) {
            return List([]const u8).cons(s, null);
        }
        // Build the list in reverse, then reverse it
        var result: ?*const List([]const u8) = null;
        var pos: usize = 0;
        var seg_start: usize = 0;
        while (pos < s.len) {
            if (pos + delimiter.len <= s.len and std.mem.eql(u8, s[pos .. pos + delimiter.len], delimiter)) {
                const seg = s[seg_start..pos];
                const seg_copy = bumpAlloc(seg.len);
                if (seg_copy.len > 0) @memcpy(seg_copy, seg);
                result = List([]const u8).cons(seg_copy, result);
                pos += delimiter.len;
                seg_start = pos;
            } else {
                pos += 1;
            }
        }
        // Last segment
        const last_seg = s[seg_start..];
        const last_copy = bumpAlloc(last_seg.len);
        if (last_copy.len > 0) @memcpy(last_copy, last_seg);
        result = List([]const u8).cons(last_copy, result);
        return List([]const u8).reverse(result);
    }

    /// Join a list of strings with a separator.
    pub fn string_join(list: ?*const List([]const u8), separator: []const u8) []const u8 {
        if (list == null) return "";
        // First pass: compute total length
        var total: usize = 0;
        var count: usize = 0;
        var current = list;
        while (current) |cell| {
            total += cell.head.len;
            count += 1;
            current = cell.tail;
        }
        if (count == 0) return "";
        total += separator.len * (count - 1);
        const result = bumpAlloc(total);
        if (result.len == 0) return "";
        // Second pass: copy segments
        var dst: usize = 0;
        var first = true;
        current = list;
        while (current) |cell| {
            if (!first and separator.len > 0) {
                @memcpy(result[dst..][0..separator.len], separator);
                dst += separator.len;
            }
            @memcpy(result[dst..][0..cell.head.len], cell.head);
            dst += cell.head.len;
            first = false;
            current = cell.tail;
        }
        return result[0..dst];
    }

    pub fn split_string(s: []const u8, delimiter: []const u8) []const u8 {
        // Returns a single bump-allocated buffer: count (as 4-byte LE) followed by
        // length-prefixed segments.  The Zap wrapper peels segments off with slice().
        if (delimiter.len == 0) return s;

        // First pass: count segments and total size
        var seg_count: usize = 1;
        var total: usize = 0;
        {
            var pos: usize = 0;
            while (pos < s.len) {
                if (pos + delimiter.len <= s.len and std.mem.eql(u8, s[pos .. pos + delimiter.len], delimiter)) {
                    seg_count += 1;
                    pos += delimiter.len;
                } else {
                    total += 1;
                    pos += 1;
                }
            }
        }

        // For simplicity, encode as "seg1\x00seg2\x00seg3" (null-separated).
        // The Zap side counts nulls to split.
        const result_len = total + seg_count - 1; // segments + null separators
        const result = bumpAlloc(result_len);
        if (result.len == 0) return s;
        var dst: usize = 0;
        var pos: usize = 0;
        while (pos < s.len) {
            if (pos + delimiter.len <= s.len and std.mem.eql(u8, s[pos .. pos + delimiter.len], delimiter)) {
                if (dst < result_len) {
                    result[dst] = 0;
                    dst += 1;
                }
                pos += delimiter.len;
            } else {
                if (dst < result_len) {
                    result[dst] = s[pos];
                    dst += 1;
                }
                pos += 1;
            }
        }
        return result[0..dst];
    }

    pub fn split_count(s: []const u8) i64 {
        if (s.len == 0) return 1;
        var count: i64 = 1;
        for (s) |c| {
            if (c == 0) count += 1;
        }
        return count;
    }

    pub fn split_get(s: []const u8, index: i64) []const u8 {
        const idx: usize = if (index >= 0) @intCast(index) else return "";
        var seg_start: usize = 0;
        var current: usize = 0;
        for (s, 0..) |c, i| {
            if (c == 0) {
                if (current == idx) return s[seg_start..i];
                current += 1;
                seg_start = i + 1;
            }
        }
        if (current == idx) return s[seg_start..s.len];
        return "";
    }

    pub fn repeat_string(s: []const u8, count: i64) []const u8 {
        if (count <= 0 or s.len == 0) return "";
        const n: usize = @intCast(count);
        const result = bumpAlloc(s.len * n);
        if (result.len == 0) return s;
        for (0..n) |i| {
            @memcpy(result[i * s.len .. (i + 1) * s.len], s);
        }
        return result;
    }

    // --- File I/O ---

    pub fn file_read(path: []const u8) []const u8 {
        const path_z = std.posix.toPosixPath(path) catch return "";
        const fd = std.c.open(&path_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0)); if (fd < 0) return "";
        defer _ = std.c.close(fd);
        var stat: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat) != 0) return "";
        const file_size: usize = @intCast(@max(stat.size, 0));
        if (file_size == 0) return "";
        const read_size = @min(file_size, 1024 * 1024);
        const result = bumpAlloc(read_size);
        if (result.len == 0) return "";
        var total: usize = 0;
        while (total < read_size) {
            const n = std.posix.read(fd, result[total..read_size]) catch break;
            if (n == 0) break;
            total += n;
        }
        return result[0..total];
    }

    pub fn file_write(path: []const u8, content: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        const fd = std.c.open(&path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644)); if (fd < 0) return false;
        defer _ = std.c.close(fd);
        var written: usize = 0;
        while (written < content.len) {
            const rc = std.c.write(fd, content[written..].ptr, content[written..].len);
            if (rc <= 0) return false;
            written += @intCast(rc);
        }
        return true;
    }

    pub fn file_exists(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.faccessat(std.posix.AT.FDCWD, &path_z, std.posix.F_OK, 0) == 0;
    }

    pub fn file_rm(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.unlinkat(std.posix.AT.FDCWD, &path_z, 0) == 0;
    }

    pub fn file_mkdir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        return std.c.mkdirat(std.posix.AT.FDCWD, &path_z, 0o755) == 0;
    }

    pub fn file_rmdir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        const AT_REMOVEDIR: u32 = 0x80; // POSIX standard
        return std.c.unlinkat(std.posix.AT.FDCWD, &path_z, AT_REMOVEDIR) == 0;
    }

    pub fn file_rename(old_path: []const u8, new_path: []const u8) bool {
        const old_z = std.posix.toPosixPath(old_path) catch return false;
        const new_z = std.posix.toPosixPath(new_path) catch return false;
        return std.c.renameat(std.posix.AT.FDCWD, &old_z, std.posix.AT.FDCWD, &new_z) == 0;
    }

    pub fn file_cp(src: []const u8, dest: []const u8) bool {
        const content = file_read(src);
        if (content.len == 0) return false;
        return file_write(dest, content);
    }

    pub fn file_is_dir(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, &path_z, &stat, 0) != 0) return false;
        return stat.mode & std.posix.S.IFMT == std.posix.S.IFDIR;
    }

    pub fn file_is_regular(path: []const u8) bool {
        const path_z = std.posix.toPosixPath(path) catch return false;
        var stat: std.c.Stat = undefined;
        if (std.c.fstatat(std.posix.AT.FDCWD, &path_z, &stat, 0) != 0) return false;
        return stat.mode & std.posix.S.IFMT == std.posix.S.IFREG;
    }

    // --- System ---

    pub fn sys_cwd() []const u8 {
        var buf: [4096]u8 = undefined;
        const cwd = std.process.getCwd(&buf) catch return "";
        const result = bumpAlloc(cwd.len);
        if (result.len == 0) return "";
        @memcpy(result, cwd);
        return result;
    }

    // --- Path operations (pure string manipulation) ---

    pub fn path_join(a: []const u8, b: []const u8) []const u8 {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const need_sep = a[a.len - 1] != '/';
        const total = a.len + b.len + @as(usize, if (need_sep) 1 else 0);
        const result = bumpAlloc(total);
        if (result.len == 0) return "";
        @memcpy(result[0..a.len], a);
        if (need_sep) {
            result[a.len] = '/';
            @memcpy(result[a.len + 1 ..][0..b.len], b);
        } else {
            @memcpy(result[a.len..][0..b.len], b);
        }
        return result;
    }

    pub fn path_basename(path: []const u8) []const u8 {
        if (path.len == 0) return "";
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') return path[i + 1 ..];
        }
        return path;
    }

    pub fn path_dirname(path: []const u8) []const u8 {
        if (path.len == 0) return ".";
        var i: usize = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/') {
                if (i == 0) return "/";
                return path[0..i];
            }
        }
        return ".";
    }

    pub fn path_extname(path: []const u8) []const u8 {
        const base = path_basename(path);
        var i: usize = base.len;
        while (i > 0) {
            i -= 1;
            if (base[i] == '.') return base[i..];
        }
        return "";
    }

    pub fn atom_name(id: anytype) []const u8 {
        const T = @TypeOf(id);
        if (T == u32) return atomToString(id);
        if (@typeInfo(T) == .int) return atomToString(@intCast(id));
        return "<not_an_atom>";
    }

    pub fn get_env(name: []const u8) []const u8 {
        return env.getenvRuntime(name) orelse "";
    }

    pub fn panic(msg: []const u8) noreturn {
        posixWrite(STDERR_FD, "panic: ");
        posixWrite(STDERR_FD, msg);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    pub fn halt(msg: []const u8) noreturn {
        posixWrite(STDERR_FD, "halt: ");
        posixWrite(STDERR_FD, msg);
        posixWrite(STDERR_FD, "\n");
        std.process.exit(1);
    }

    /// Call a callable value — either a bare function pointer or a closure struct.
    /// Closure structs have {call_fn, env, env_release} fields.
    pub inline fn callCallable0(callable: anytype) @TypeOf(callable()) {
        const T = @TypeOf(callable);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
            return callable.call_fn(callable.env);
        } else {
            return callable();
        }
    }

    pub inline fn callCallable1(callable: anytype, arg0: anytype) CallReturnType(@TypeOf(callable)) {
        const T = @TypeOf(callable);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
            return callable.call_fn(callable.env, arg0);
        } else {
            return callable(arg0);
        }
    }

    pub inline fn callCallable2(callable: anytype, arg0: anytype, arg1: anytype) CallReturnType(@TypeOf(callable)) {
        const T = @TypeOf(callable);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
            return callable.call_fn(callable.env, arg0, arg1);
        } else {
            return callable(arg0, arg1);
        }
    }

    pub inline fn callCallable3(callable: anytype, arg0: anytype, arg1: anytype, arg2: anytype) CallReturnType(@TypeOf(callable)) {
        const T = @TypeOf(callable);
        if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
            return callable.call_fn(callable.env, arg0, arg1, arg2);
        } else {
            return callable(arg0, arg1, arg2);
        }
    }

    fn CallReturnType(comptime T: type) type {
        if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
            const fn_info = @typeInfo(@TypeOf(@field(@as(T, undefined), "call_fn")));
            if (fn_info == .pointer) {
                const child = @typeInfo(fn_info.pointer.child);
                if (child == .@"fn") {
                    return child.@"fn".return_type orelse i64;
                }
            }
            return i64;
        } else {
            const info = @typeInfo(T);
            if (info == .pointer) {
                const child = @typeInfo(info.pointer.child);
                if (child == .@"fn") {
                    return child.@"fn".return_type orelse i64;
                }
            }
            return i64;
        }
    }


    // CLI argument access — use getArgv() directly (no allocation)
    pub fn arg_count() i64 {
        const argv = getArgv();
        return if (argv.len > 0) @as(i64, @intCast(argv.len)) - 1 else 0;
    }

    pub fn arg_at(index: anytype) []const u8 {
        const argv = getArgv();
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
// TestTracker — mutable counters for test/assertion reporting
// ============================================================

pub const Zest = struct {
    var test_count: i64 = 0;
    var test_failures: i64 = 0;
    var assertion_count: i64 = 0;
    var assertion_failures: i64 = 0;
    var current_test_failed: bool = false;
    var seed: i64 = 0;
    var seed_set: bool = false;
    var timeout_ms: i64 = 0; // per-test timeout in milliseconds (0 = no timeout)
    var test_start_ns: i96 = 0; // timestamp when current test started
    var timeout_count: i64 = 0; // number of tests that timed out

    pub fn set_seed(s: i64) void {
        seed = s;
        seed_set = true;
    }

    pub fn get_seed() i64 {
        if (!seed_set) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            const abs_nanos: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
            const positive = if (abs_nanos < 0) -abs_nanos else abs_nanos;
            seed = @intCast(positive & 0x7FFFFFFFFFFFFFFF);
            seed_set = true;
        }
        return seed;
    }

    pub fn set_timeout(ms: i64) void {
        timeout_ms = ms;
    }

    pub fn get_timeout() i64 {
        return timeout_ms;
    }

    pub fn begin_test() void {
        current_test_failed = false;
        test_count += 1;
        if (timeout_ms > 0) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
            test_start_ns = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
        }
    }

    pub fn check_timeout() bool {
        if (timeout_ms <= 0) return false;
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
            _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        const now_ns: i96 = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec);
        const elapsed_ns = now_ns - test_start_ns;
        const timeout_ns: i96 = @as(i96, timeout_ms) * 1_000_000;
        if (elapsed_ns > timeout_ns) {
            current_test_failed = true;
            timeout_count += 1;
            stdoutPrint("\x1b[1;33mT\x1b[0m", .{}); // yellow T for timeout
            return true;
        }
        return false;
    }

    pub fn end_test() void {
        if (current_test_failed) {
            test_failures += 1;
        }
    }

    pub fn print_result() void {
        if (current_test_failed) {
            print_fail();
        } else {
            print_dot();
        }
    }

    pub fn pass_assertion() void {
        assertion_count += 1;
    }

    pub fn fail_assertion() void {
        assertion_count += 1;
        assertion_failures += 1;
        current_test_failed = true;
    }

    pub fn print_dot() void {
        stdoutPrint("\x1b[1;32m.\x1b[0m", .{});
    }

    pub fn print_fail() void {
        stdoutPrint("\x1b[1;31mF\x1b[0m", .{});
    }

    pub fn summary() i64 {
        stdoutPrint("\n\nSeed: ", .{});
        writeI64(get_seed());
        if (timeout_ms > 0) {
            stdoutPrint("\nTimeout: ", .{});
            writeI64(timeout_ms);
            stdoutPrint("ms", .{});
        }
        stdoutPrint("\n", .{});
        writeI64(test_count);
        stdoutPrint(" tests, ", .{});
        writeI64(test_failures);
        stdoutPrint(" failures", .{});
        if (timeout_count > 0) {
            stdoutPrint(" (", .{});
            writeI64(timeout_count);
            stdoutPrint(" timed out)", .{});
        }
        stdoutPrint("\n", .{});
        writeI64(assertion_count);
        stdoutPrint(" assertions, ", .{});
        writeI64(assertion_failures);
        stdoutPrint(" failures\n", .{});
        return test_failures;
    }

    fn writeI64(val: i64) void {
        if (val < 0) {
            stdoutPrint("-", .{});
            writeI64(-val);
            return;
        }
        if (val >= 10) {
            writeI64(@divTrunc(val, 10));
        }
        const digit: u8 = @intCast(@mod(val, 10));
        const buf = [1]u8{'0' + digit};
        stdoutWrite(&buf);
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

    pub fn readIntU8(data: []const u8, offset: usize) i64 {
        if (offset >= data.len) return 0;
        return @intCast(data[offset]);
    }

    pub fn readIntU16Big(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .big));
    }

    pub fn readIntU16Little(data: []const u8, offset: usize) i64 {
        if (offset + 2 > data.len) return 0;
        return @intCast(std.mem.readInt(u16, data[offset..][0..2], .little));
    }

    pub fn readIntU32Big(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .big));
    }

    pub fn readIntU32Little(data: []const u8, offset: usize) i64 {
        if (offset + 4 > data.len) return 0;
        return @intCast(std.mem.readInt(u32, data[offset..][0..4], .little));
    }

    pub fn readIntU64Big(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return @bitCast(std.mem.readInt(u64, data[offset..][0..8], .big));
    }

    pub fn readIntU64Little(data: []const u8, offset: usize) i64 {
        if (offset + 8 > data.len) return 0;
        return @bitCast(std.mem.readInt(u64, data[offset..][0..8], .little));
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
    pub fn readBitsU(data: []const u8, offset: usize, bit_offset: u3, bits: u8) i64 {
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
// List — Concrete cons-cell for pointer-based lists.
//
// Lists use nullable pointers: null = empty, non-null = cons cell.
// This allows runtime empty/non-empty checks that survive ZIR.
// ============================================================

// ---- Callable dispatch helpers ----
// Handle both bare function pointers and closure structs transparently.
// Used by List, Map, and List higher-order functions.

inline fn call1(callback: anytype, arg0: anytype) @TypeOf(if (@typeInfo(@TypeOf(callback)) == .@"struct" and @hasField(@TypeOf(callback), "call_fn")) callback.call_fn(callback.env, arg0) else callback(arg0)) {
    const T = @TypeOf(callback);
    if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
        return callback.call_fn(callback.env, arg0);
    } else {
        return callback(arg0);
    }
}

inline fn call2(callback: anytype, arg0: anytype, arg1: anytype) @TypeOf(if (@typeInfo(@TypeOf(callback)) == .@"struct" and @hasField(@TypeOf(callback), "call_fn")) callback.call_fn(callback.env, arg0, arg1) else callback(arg0, arg1)) {
    const T = @TypeOf(callback);
    if (@typeInfo(T) == .@"struct" and @hasField(T, "call_fn")) {
        return callback.call_fn(callback.env, arg0, arg1);
    } else {
        return callback(arg0, arg1);
    }
}

// ============================================================
// Map — Generic HAMT-based persistent map.
//
// Map(K, V) generates a type-specific map for any key/value types.
// Maps use nullable pointers: null = empty, non-null = map cell.
// Hybrid: flat array for small maps, HAMT trie for larger.
// ============================================================

pub fn Map(comptime K: type, comptime V: type) type {
    return struct {
    const Self = @This();
    // Hybrid representation: flat array for small maps, HAMT trie for larger maps.
    // The HAMT (Hash Array Mapped Trie) provides O(log32 n) lookup, insert, and
    // delete for large maps while the flat array remains optimal for <= 8 entries.
    // All nodes are bump-allocated (persistent/immutable).

    total_count: u32,
    repr_tag: u8, // 0 = flat, 1 = trie
    // Payload is one of:
    //   flat: entries + count stored inline
    //   trie: root node pointer
    flat_entries: [*]const MapEntry,
    flat_count: u32,
    trie_root: ?*const HamtNode,

    const FLAT_THRESHOLD = 8;
    const BITS_PER_LEVEL = 5;
    const BRANCHING_FACTOR = 1 << BITS_PER_LEVEL; // 32
    const LEVEL_MASK: u32 = BRANCHING_FACTOR - 1; // 0x1F
    const MAX_DEPTH = 7; // ceil(32 / 5)

    pub const MapEntry = struct {
        key: K,
        value: V,
    };

    /// HAMT trie node: bitmap-indexed with packed children array.
    /// Each child is either a leaf entry or a pointer to a sub-node.
    const HamtNode = struct {
        bitmap: u32,
        children_entries: [*]const MapEntry, // leaf entries (parallel to children_nodes)
        children_nodes: [*]const ?*const HamtNode, // sub-nodes (null = leaf at this slot)
        child_count: u5,
    };

    /// Hash a key value for HAMT lookup. Supports u32 (atoms), i64, []const u8 (strings), bool.
    fn hashKey(key: K) u32 {
        const raw: u32 = if (K == u32)
            key
        else if (K == i64)
            @truncate(@as(u64, @bitCast(key)))
        else if (K == []const u8) blk: {
            var h: u32 = 2166136261;
            for (key) |byte| {
                h ^= byte;
                h *%= 16777619;
            }
            break :blk h;
        } else if (K == bool)
            if (key) @as(u32, 1) else @as(u32, 0)
        else
            0;
        // Murmur3 finalizer
        var h = raw;
        h ^= h >> 16;
        h *%= 0x85ebca6b;
        h ^= h >> 13;
        h *%= 0xc2b2ae35;
        h ^= h >> 16;
        return h;
    }

    fn keysEqual(a: K, b: K) bool {
        if (K == []const u8) return std.mem.eql(u8, a, b);
        return a == b;
    }

    fn allocMap() ?*Self {
        const slice = bumpAllocSlice(Self, 1);
        if (slice.len == 0) return null;
        return &slice[0];
    }

    fn allocEntries(count: usize) ?[*]MapEntry {
        if (count == 0) return @as([*]MapEntry, undefined);
        const slice = bumpAllocSlice(MapEntry, count);
        if (slice.len == 0) return null;
        return slice.ptr;
    }

    fn allocHamtNode() ?*HamtNode {
        const slice = bumpAllocSlice(HamtNode, 1);
        if (slice.len == 0) return null;
        return &slice[0];
    }

    fn allocNodePtrs(count: usize) ?[*]?*const HamtNode {
        if (count == 0) return @as([*]?*const HamtNode, undefined);
        const slice = bumpAllocSlice(?*const HamtNode, count);
        if (slice.len == 0) return null;
        for (0..count) |i| {
            slice[i] = null;
        }
        return slice.ptr;
    }

    fn makeFlatMap(entries: [*]const MapEntry, count: u32) ?*const Self {
        const cell = allocMap() orelse return null;
        cell.* = .{
            .total_count = count,
            .repr_tag = 0,
            .flat_entries = entries,
            .flat_count = count,
            .trie_root = null,
        };
        return cell;
    }

    fn makeTrieMap(root: *const HamtNode, total: u32) ?*const Self {
        const cell = allocMap() orelse return null;
        cell.* = .{
            .total_count = total,
            .repr_tag = 1,
            .flat_entries = undefined,
            .flat_count = 0,
            .trie_root = root,
        };
        return cell;
    }

    // === HAMT internal operations ===

    /// Get the index into the bitmap for a given hash at a given depth.
    fn sparseIndex(bitmap: u32, bit: u32) u5 {
        return @intCast(@popCount(bitmap & (bit - 1)));
    }

    fn hamtGet(node: *const HamtNode, key: K, hash: u32, depth: u5) ?V {
        const shift: u5 = depth * BITS_PER_LEVEL;
        const bit: u32 = @as(u32, 1) << @intCast((hash >> shift) & LEVEL_MASK);

        if (node.bitmap & bit == 0) return null;

        const idx = sparseIndex(node.bitmap, bit);
        if (node.children_nodes[idx]) |sub| {
            // Recurse into sub-node
            return hamtGet(sub, key, hash, depth + 1);
        } else {
            // Leaf entry
            const entry = node.children_entries[idx];
            return if (keysEqual(entry.key, key)) entry.value else null;
        }
    }

    fn hamtPut(node: *const HamtNode, key: K, value: V, hash: u32, depth: u5) ?*const HamtNode {
        const shift: u5 = depth * BITS_PER_LEVEL;
        const bit: u32 = @as(u32, 1) << @intCast((hash >> shift) & LEVEL_MASK);
        const idx = sparseIndex(node.bitmap, bit);

        if (node.bitmap & bit == 0) {
            // Empty slot — insert new leaf
            const old_count: usize = @intCast(node.child_count);
            const new_count = old_count + 1;
            const new_entries = allocEntries(new_count) orelse return null;
            const new_nodes = allocNodePtrs(new_count) orelse return null;
            const new_node = allocHamtNode() orelse return null;

            // Copy entries before idx
            if (idx > 0) {
                @memcpy(new_entries[0..idx], node.children_entries[0..idx]);
                @memcpy(new_nodes[0..idx], node.children_nodes[0..idx]);
            }
            // Insert new leaf at idx
            new_entries[idx] = .{ .key = key, .value = value };
            new_nodes[idx] = null; // leaf
            // Copy entries after idx
            const after = old_count - idx;
            if (after > 0) {
                @memcpy(new_entries[idx + 1 ..][0..after], node.children_entries[idx..][0..after]);
                @memcpy(new_nodes[idx + 1 ..][0..after], node.children_nodes[idx..][0..after]);
            }

            new_node.* = .{
                .bitmap = node.bitmap | bit,
                .children_entries = new_entries,
                .children_nodes = new_nodes,
                .child_count = @intCast(new_count),
            };
            return new_node;
        }

        if (node.children_nodes[idx]) |sub| {
            // Recurse into existing sub-node
            const updated_sub = hamtPut(sub, key, value, hash, depth + 1) orelse return null;
            return copyNodeWithUpdatedChild(node, idx, null, updated_sub);
        }

        // Existing leaf at this slot
        const existing = node.children_entries[idx];
        if (keysEqual(existing.key, key)) {
            // Update value
            return copyNodeWithUpdatedEntry(node, idx, .{ .key = key, .value = value });
        }

        // Hash collision at this depth — create sub-node
        if (depth >= MAX_DEPTH - 1) {
            // At max depth, just replace (degenerate case)
            return copyNodeWithUpdatedEntry(node, idx, .{ .key = key, .value = value });
        }

        // Create a new sub-node containing both the existing and new entries
        const existing_hash = hashKey(existing.key);
        const initial_sub = allocHamtNode() orelse return null;
        initial_sub.* = .{ .bitmap = 0, .children_entries = undefined, .children_nodes = undefined, .child_count = 0 };
        const sub_with_existing = hamtPut(initial_sub, existing.key, existing.value, existing_hash, depth + 1) orelse return null;
        const sub_with_both = hamtPut(sub_with_existing, key, value, hash, depth + 1) orelse return null;
        return copyNodeWithUpdatedChild(node, idx, null, sub_with_both);
    }

    fn hamtDelete(node: *const HamtNode, key: K, hash: u32, depth: u5) ?*const HamtNode {
        const shift: u5 = depth * BITS_PER_LEVEL;
        const bit: u32 = @as(u32, 1) << @intCast((hash >> shift) & LEVEL_MASK);

        if (node.bitmap & bit == 0) return node; // not found

        const idx = sparseIndex(node.bitmap, bit);

        if (node.children_nodes[idx]) |sub| {
            const updated = hamtDelete(sub, key, hash, depth + 1) orelse return null;
            if (updated.child_count == 0) {
                return removeChildFromNode(node, idx, bit);
            }
            return copyNodeWithUpdatedChild(node, idx, null, updated);
        }

        // Leaf
        const existing = node.children_entries[idx];
        if (!keysEqual(existing.key, key)) return node; // not found
        return removeChildFromNode(node, idx, bit);
    }

    fn copyNodeWithUpdatedEntry(node: *const HamtNode, idx: usize, entry: MapEntry) ?*const HamtNode {
        const count: usize = @intCast(node.child_count);
        const new_entries = allocEntries(count) orelse return null;
        const new_nodes = allocNodePtrs(count) orelse return null;
        const new_node = allocHamtNode() orelse return null;

        @memcpy(new_entries[0..count], node.children_entries[0..count]);
        @memcpy(new_nodes[0..count], node.children_nodes[0..count]);
        new_entries[idx] = entry;

        new_node.* = .{
            .bitmap = node.bitmap,
            .children_entries = new_entries,
            .children_nodes = new_nodes,
            .child_count = node.child_count,
        };
        return new_node;
    }

    fn copyNodeWithUpdatedChild(node: *const HamtNode, idx: usize, entry: ?MapEntry, sub: *const HamtNode) ?*const HamtNode {
        const count: usize = @intCast(node.child_count);
        const new_entries = allocEntries(count) orelse return null;
        const new_nodes = allocNodePtrs(count) orelse return null;
        const new_node = allocHamtNode() orelse return null;

        @memcpy(new_entries[0..count], node.children_entries[0..count]);
        @memcpy(new_nodes[0..count], node.children_nodes[0..count]);
        if (entry) |e| new_entries[idx] = e;
        new_nodes[idx] = sub;

        new_node.* = .{
            .bitmap = node.bitmap,
            .children_entries = new_entries,
            .children_nodes = new_nodes,
            .child_count = node.child_count,
        };
        return new_node;
    }

    fn removeChildFromNode(node: *const HamtNode, idx: usize, bit: u32) ?*const HamtNode {
        const old_count: usize = @intCast(node.child_count);
        if (old_count <= 1) {
            const empty_node = allocHamtNode() orelse return null;
            empty_node.* = .{ .bitmap = 0, .children_entries = undefined, .children_nodes = undefined, .child_count = 0 };
            return empty_node;
        }
        const new_count = old_count - 1;
        const new_entries = allocEntries(new_count) orelse return null;
        const new_nodes = allocNodePtrs(new_count) orelse return null;
        const new_node = allocHamtNode() orelse return null;

        var dst: usize = 0;
        for (0..old_count) |i| {
            if (i != idx) {
                new_entries[dst] = node.children_entries[i];
                new_nodes[dst] = node.children_nodes[i];
                dst += 1;
            }
        }

        new_node.* = .{
            .bitmap = node.bitmap & ~bit,
            .children_entries = new_entries,
            .children_nodes = new_nodes,
            .child_count = @intCast(new_count),
        };
        return new_node;
    }

    /// Collect all entries from a HAMT trie into a flat list.
    fn hamtCollect(node: *const HamtNode, result: *std.ArrayListUnmanaged(MapEntry)) void {
        const count: usize = @intCast(node.child_count);
        for (0..count) |i| {
            if (node.children_nodes[i]) |sub| {
                hamtCollect(sub, result);
            } else {
                // Use a fixed-size buffer approach since we can't return errors
                result.append(runtime_arena.allocator(), node.children_entries[i]) catch {};
            }
        }
    }

    /// Convert flat entries to a HAMT trie.
    fn flatToTrie(entries: [*]const MapEntry, count: u32) ?*const HamtNode {
        const initial = allocHamtNode() orelse return null;
        initial.* = .{ .bitmap = 0, .children_entries = undefined, .children_nodes = undefined, .child_count = 0 };

        var root: *const HamtNode = initial;
        for (0..count) |i| {
            const entry = entries[i];
            const hash = hashKey(entry.key);
            root = hamtPut(root, entry.key, entry.value, hash, 0) orelse return null;
        }
        return root;
    }

    // === Public API (unchanged signatures) ===

    pub fn empty() ?*const Self {
        return null;
    }

    pub fn fromPairs(key_ids: []const K, vals: []const V, count: u32) ?*const Self {
        if (count == 0) return null;
        const n: usize = @intCast(count);
        const entry_arr = allocEntries(n) orelse return null;
        for (0..n) |i| {
            entry_arr[i] = .{ .key = key_ids[i], .value = vals[i] };
        }

        if (count <= FLAT_THRESHOLD) {
            return makeFlatMap(entry_arr, count);
        }
        // Build HAMT from entries
        const root = flatToTrie(entry_arr, count) orelse return makeFlatMap(entry_arr, count);
        return makeTrieMap(root, count);
    }

    pub fn get(map: ?*const Self, key: K, default: V) V {
        if (map) |m| {
            if (m.repr_tag == 0) {
                // Flat: linear scan
                for (m.flat_entries[0..m.flat_count]) |entry| {
                    if (keysEqual(entry.key, key)) return entry.value;
                }
            } else {
                // Trie: hash lookup
                if (m.trie_root) |root| {
                    const hash = hashKey(key);
                    return hamtGet(root, key, hash, 0) orelse default;
                }
            }
        }
        return default;
    }

    pub fn getStr(map: ?*const Self, key: K, default: []const u8) []const u8 {
        _ = map;
        _ = key;
        return default;
    }

    pub fn hasKey(map: ?*const Self, key: K) bool {
        if (map) |m| {
            if (m.repr_tag == 0) {
                for (m.flat_entries[0..m.flat_count]) |entry| {
                    if (keysEqual(entry.key, key)) return true;
                }
            } else {
                if (m.trie_root) |root| {
                    const hash = hashKey(key);
                    return hamtGet(root, key, hash, 0) != null;
                }
            }
        }
        return false;
    }

    pub fn size(map: ?*const Self) i64 {
        if (map) |m| return @intCast(m.total_count);
        return 0;
    }

    pub fn isEmpty(map: ?*const Self) bool {
        return map == null;
    }

    pub fn put(map: ?*const Self, key: K, value: V) ?*const Self {
        if (map == null) {
            // Create new single-entry flat map
            const entries = allocEntries(1) orelse return null;
            entries[0] = .{ .key = key, .value = value };
            return makeFlatMap(entries, 1);
        }

        const m = map.?;

        if (m.repr_tag == 0) {
            // Currently flat
            const old_count: usize = @intCast(m.flat_count);

            // Check if key exists (update)
            for (0..old_count) |i| {
                if (keysEqual(m.flat_entries[i].key, key)) {
                    // Update existing key — copy and replace
                    const new_entries = allocEntries(old_count) orelse return map;
                    for (0..old_count) |j| {
                        new_entries[j] = if (j == i) MapEntry{ .key = key, .value = value } else m.flat_entries[j];
                    }
                    if (old_count <= FLAT_THRESHOLD) {
                        return makeFlatMap(new_entries, m.flat_count);
                    }
                    const root = flatToTrie(new_entries, m.flat_count) orelse return makeFlatMap(new_entries, m.flat_count);
                    return makeTrieMap(root, m.flat_count);
                }
            }

            // New key — append
            const new_count: u32 = m.flat_count + 1;
            const new_entries = allocEntries(old_count + 1) orelse return map;
            for (0..old_count) |i| {
                new_entries[i] = m.flat_entries[i];
            }
            new_entries[old_count] = .{ .key = key, .value = value };

            if (new_count <= FLAT_THRESHOLD) {
                return makeFlatMap(new_entries, new_count);
            }
            // Promote to trie
            const root = flatToTrie(new_entries, new_count) orelse return makeFlatMap(new_entries, new_count);
            return makeTrieMap(root, new_count);
        }

        // Trie mode
        if (m.trie_root) |root| {
            const hash = hashKey(key);
            const was_present = hamtGet(root, key, hash, 0) != null;
            const new_root = hamtPut(root, key, value, hash, 0) orelse return map;
            const new_total = if (was_present) m.total_count else m.total_count + 1;
            return makeTrieMap(new_root, new_total);
        }
        return map;
    }

    pub fn delete(map: ?*const Self, key: K) ?*const Self {
        if (map == null) return null;
        const m = map.?;

        if (m.repr_tag == 0) {
            // Flat mode
            var found = false;
            for (m.flat_entries[0..m.flat_count]) |entry| {
                if (keysEqual(entry.key, key)) {
                    found = true;
                    break;
                }
            }
            if (!found) return map;

            const new_count = m.flat_count - 1;
            if (new_count == 0) return null;

            const new_entries = allocEntries(new_count) orelse return map;
            var dst: usize = 0;
            for (m.flat_entries[0..m.flat_count]) |entry| {
                if (!keysEqual(entry.key, key)) {
                    new_entries[dst] = entry;
                    dst += 1;
                }
            }
            return makeFlatMap(new_entries, new_count);
        }

        // Trie mode
        if (m.trie_root) |root| {
            const hash = hashKey(key);
            if (hamtGet(root, key, hash, 0) == null) return map; // not found
            const new_root = hamtDelete(root, key, hash, 0) orelse return map;
            const new_total = m.total_count - 1;
            if (new_total == 0) return null;
            // Demote to flat if below threshold
            if (new_total <= FLAT_THRESHOLD) {
                var collected: std.ArrayListUnmanaged(MapEntry) = .empty;
                hamtCollect(new_root, &collected);
                if (collected.items.len > 0) {
                    const entries = allocEntries(collected.items.len) orelse return makeTrieMap(new_root, new_total);
                    for (collected.items, 0..) |entry, i| {
                        entries[i] = entry;
                    }
                    return makeFlatMap(entries, new_total);
                }
            }
            return makeTrieMap(new_root, new_total);
        }
        return map;
    }

    /// Iterator protocol for maps.
    /// Returns `{:cont, {key, value}, remaining_map}` on each step or
    /// `{:done, undefined, map}` when the map is empty. Each call removes
    /// one entry; full iteration runs in O(n log n) for a map of n
    /// entries. Iteration order is unspecified across runs but stable
    /// within a single iteration on a single map value.
    pub fn next(map: ?*const Self) struct {
        u32,
        struct { K, V },
        ?*const Self,
    } {
        if (map == null or map.?.total_count == 0) {
            return .{ ATOM_DONE, .{ undefined, undefined }, map };
        }
        const m = map.?;

        const first_entry: MapEntry = if (m.repr_tag == 0)
            m.flat_entries[0]
        else
            firstTrieEntry(m.trie_root.?);

        const remaining = delete(map, first_entry.key);
        return .{ ATOM_CONT, .{ first_entry.key, first_entry.value }, remaining };
    }

    /// Find the first leaf entry in a HAMT subtree by depth-first
    /// traversal. Caller must guarantee the tree is non-empty (the
    /// root's parent map had `total_count > 0`).
    fn firstTrieEntry(node: *const HamtNode) MapEntry {
        const count: usize = @intCast(node.child_count);
        for (0..count) |i| {
            if (node.children_nodes[i]) |sub| {
                return firstTrieEntry(sub);
            } else {
                return node.children_entries[i];
            }
        }
        unreachable;
    }

    pub fn merge(map_a: ?*const Self, map_b: ?*const Self) ?*const Self {
        if (map_a == null) return map_b;
        if (map_b == null) return map_a;
        // Apply all entries from b onto a
        var result = map_a;
        const b = map_b.?;

        if (b.repr_tag == 0) {
            for (b.flat_entries[0..b.flat_count]) |entry| {
                result = put(result, entry.key, entry.value);
            }
        } else {
            // Collect trie entries and apply
            var collected: std.ArrayListUnmanaged(MapEntry) = .empty;
            if (b.trie_root) |root| hamtCollect(root, &collected);
            for (collected.items) |entry| {
                result = put(result, entry.key, entry.value);
            }
        }
        return result;
    }

    pub fn keys(map: ?*const Self) ?*const List(K) {
        if (map == null) return null;
        const m = map.?;

        if (m.repr_tag == 0) {
            var result: ?*const List(K) = null;
            var i: usize = m.flat_count;
            while (i > 0) {
                i -= 1;
                result = List(K).cons(m.flat_entries[i].key, result);
            }
            return result;
        }

        // Trie: collect and build list
        var collected: std.ArrayListUnmanaged(MapEntry) = .empty;
        if (m.trie_root) |root| hamtCollect(root, &collected);
        var result: ?*const List(K) = null;
        var i: usize = collected.items.len;
        while (i > 0) {
            i -= 1;
            result = List(K).cons(collected.items[i].key, result);
        }
        return result;
    }

    pub fn values(map: ?*const Self) ?*const List(V) {
        if (map == null) return null;
        const m = map.?;

        if (m.repr_tag == 0) {
            var result: ?*const List(V) = null;
            var i: usize = m.flat_count;
            while (i > 0) {
                i -= 1;
                result = List(V).cons(m.flat_entries[i].value, result);
            }
            return result;
        }

        // Trie: collect and build list
        var collected: std.ArrayListUnmanaged(MapEntry) = .empty;
        if (m.trie_root) |root| hamtCollect(root, &collected);
        var result: ?*const List(V) = null;
        var i: usize = collected.items.len;
        while (i > 0) {
            i -= 1;
            result = List(V).cons(collected.items[i].value, result);
        }
        return result;
    }

    /// Simple reduce: folds map entries with a (acc, key, value) -> acc callback.
    /// Iterates all entries and applies the callback with the accumulator.
    pub fn enumReduceSimple(map: ?*const Self, initial: i64, callback: anytype) i64 {
        if (map == null) return initial;
        const m = map.?;
        var acc: i64 = initial;

        if (m.repr_tag == 0) {
            // Flat representation
            for (0..m.flat_count) |i| {
                acc = callback(acc, @as(i64, @intCast(m.flat_entries[i].key)), m.flat_entries[i].value);
            }
        } else if (m.trie_root) |root| {
            // Trie: collect entries then iterate
            var collected: std.ArrayListUnmanaged(MapEntry) = .empty;
            hamtCollect(root, &collected);
            for (collected.items) |entry| {
                acc = callback(acc, @as(i64, @intCast(entry.key)), entry.value);
            }
        }
        return acc;
    }

    /// Reduce for Enumerable: folds map values with a (acc, value) -> acc callback.
    /// Only passes the value (not the key) to match the Enumerable protocol.
    pub fn enumReduceValues(map: ?*const Self, initial: i64, callback: anytype) i64 {
        if (map == null) return initial;
        const m = map.?;
        var acc: i64 = initial;

        if (m.repr_tag == 0) {
            for (0..m.flat_count) |i| {
                acc = callback(acc, m.flat_entries[i].value);
            }
        } else if (m.trie_root) |root| {
            var collected: std.ArrayListUnmanaged(MapEntry) = .empty;
            hamtCollect(root, &collected);
            for (collected.items) |entry| {
                acc = callback(acc, entry.value);
            }
        }
        return acc;
    }
    }; // end of returned struct
} // end of Map

// ============================================================
// Generic List factory — produces monomorphic list types
// for any element type T. Used for string lists, atom lists, etc.
// ============================================================

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();
        head: T,
        tail: ?*const Self,

        pub fn empty() ?*const Self {
            return null;
        }

        pub fn cons(head: T, tail: ?*const Self) ?*const Self {
            const bytes = bumpAlloc(@sizeOf(Self));
            if (bytes.len == 0) return null;
            const cell: *Self = @ptrCast(@alignCast(bytes.ptr));
            cell.* = .{ .head = head, .tail = tail };
            return cell;
        }

        pub fn getHead(list: ?*const Self) T {
            if (list) |cell| return cell.head;
            return std.mem.zeroes(T);
        }

        pub fn getTail(list: ?*const Self) ?*const Self {
            if (list) |cell| return cell.tail;
            return null;
        }

        pub fn isEmpty(list: ?*const Self) bool {
            return list == null;
        }

        pub fn length(list: ?*const Self) i64 {
            var current = list;
            var count: i64 = 0;
            while (current) |cell| {
                count += 1;
                current = cell.tail;
            }
            return count;
        }

        pub fn get(list: ?*const Self, index: i64) T {
            var current = list;
            var i: i64 = 0;
            while (current) |cell| {
                if (i == index) return cell.head;
                current = cell.tail;
                i += 1;
            }
            return std.mem.zeroes(T);
        }

        pub fn last(list: ?*const Self) T {
            var current = list;
            var result: T = std.mem.zeroes(T);
            while (current) |cell| {
                result = cell.head;
                current = cell.tail;
            }
            return result;
        }

        pub fn reverse(list: ?*const Self) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                result = cons(cell.head, result);
                current = cell.tail;
            }
            return result;
        }

        /// Iterator protocol: returns {atom, value, next_state}.
        /// :cont (5) with head and tail for non-empty, :done (7) for empty.
        pub fn next(list: ?*const Self) std.meta.Tuple(&.{ u32, T, ?*const Self }) {
            if (list) |cell| {
                return .{ ATOM_CONT, cell.head, cell.tail };
            }
            return .{ ATOM_DONE, std.mem.zeroes(T), null };
        }

        pub fn contains(list: ?*const Self, value: T) bool {
            var current = list;
            while (current) |cell| {
                if (std.mem.eql(u8, std.mem.asBytes(&cell.head), std.mem.asBytes(&value))) return true;
                current = cell.tail;
            }
            return false;
        }

        pub fn append(list: ?*const Self, value: T) ?*const Self {
            return reverse(cons(value, reverse(list)));
        }

        pub fn concat(first: ?*const Self, second: ?*const Self) ?*const Self {
            if (first == null) return second;
            var reversed_first = reverse(first);
            var result = second;
            while (reversed_first) |cell| {
                result = cons(cell.head, result);
                reversed_first = cell.tail;
            }
            return result;
        }

        pub fn take(list: ?*const Self, count: i64) ?*const Self {
            if (count <= 0 or list == null) return null;
            var current = list;
            var collected: ?*const Self = null;
            var remaining: i64 = count;
            while (current) |cell| {
                if (remaining <= 0) break;
                collected = cons(cell.head, collected);
                current = cell.tail;
                remaining -= 1;
            }
            return reverse(collected);
        }

        pub fn drop(list: ?*const Self, count: i64) ?*const Self {
            if (count <= 0) return list;
            var current = list;
            var remaining: i64 = count;
            while (current) |cell| {
                if (remaining <= 0) return current;
                current = cell.tail;
                remaining -= 1;
            }
            return null;
        }

        pub fn uniq(list: ?*const Self) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                if (!contains(result, cell.head)) {
                    result = cons(cell.head, result);
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        // Higher-order functions
        pub fn mapFn(list: ?*const Self, callback: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                result = cons(call1(callback, cell.head), result);
                current = cell.tail;
            }
            return reverse(result);
        }

        pub fn filterFn(list: ?*const Self, predicate: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                if (call1(predicate, cell.head)) {
                    result = cons(cell.head, result);
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        pub fn rejectFn(list: ?*const Self, predicate: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                if (!call1(predicate, cell.head)) {
                    result = cons(cell.head, result);
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        pub fn enumReduceSimple(list: ?*const Self, initial: T, callback: anytype) T {
            var current = list;
            var acc: T = initial;
            while (current) |cell| {
                acc = call2(callback, acc, cell.head);
                current = cell.tail;
            }
            return acc;
        }

        pub fn eachFn(list: ?*const Self, callback: anytype) ?*const Self {
            var current = list;
            while (current) |cell| {
                _ = call1(callback, cell.head);
                current = cell.tail;
            }
            return list;
        }

        pub fn findFn(list: ?*const Self, default: T, predicate: anytype) T {
            var current = list;
            while (current) |cell| {
                if (call1(predicate, cell.head)) return cell.head;
                current = cell.tail;
            }
            return default;
        }

        pub fn anyFn(list: ?*const Self, predicate: anytype) bool {
            var current = list;
            while (current) |cell| {
                if (call1(predicate, cell.head)) return true;
                current = cell.tail;
            }
            return false;
        }

        pub fn allFn(list: ?*const Self, predicate: anytype) bool {
            var current = list;
            while (current) |cell| {
                if (!call1(predicate, cell.head)) return false;
                current = cell.tail;
            }
            return true;
        }

        pub fn countFn(list: ?*const Self, predicate: anytype) i64 {
            var current = list;
            var count: i64 = 0;
            while (current) |cell| {
                if (call1(predicate, cell.head)) count += 1;
                current = cell.tail;
            }
            return count;
        }

        pub fn sortFn(list: ?*const Self, comparator: anytype) ?*const Self {
            const len_val = length(list);
            if (len_val <= 1) return list;
            const len: usize = @intCast(len_val);
            const arr = bumpAllocSlice(T, len);
            if (arr.len == 0) return list;
            var current = list;
            var i: usize = 0;
            while (current) |cell| {
                if (i < len) arr[i] = cell.head;
                current = cell.tail;
                i += 1;
            }
            const Ctx = struct {
                cmp: @TypeOf(comparator),
                fn lessThan(ctx: @This(), a: T, b: T) bool {
                    return call2(ctx.cmp, a, b);
                }
            };
            std.sort.pdq(T, arr, Ctx{ .cmp = comparator }, Ctx.lessThan);
            var result: ?*const Self = null;
            var ri: usize = len;
            while (ri > 0) {
                ri -= 1;
                result = cons(arr[ri], result);
            }
            return result;
        }

        pub fn flatMapFn(list: ?*const Self, callback: anytype) ?*const Self {
            var current = list;
            var result: ?*const Self = null;
            while (current) |cell| {
                var inner = call1(callback, cell.head);
                while (inner) |inner_cell| {
                    result = cons(inner_cell.head, result);
                    inner = inner_cell.tail;
                }
                current = cell.tail;
            }
            return reverse(result);
        }

        // Numeric-only methods (only instantiated when T is an integer type)
        pub fn sum(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("sum requires integer element type");
            var current = list;
            var total: T = 0;
            while (current) |cell| {
                total += cell.head;
                current = cell.tail;
            }
            return total;
        }

        pub fn product(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("product requires integer element type");
            var current = list;
            var total: T = 1;
            while (current) |cell| {
                total *= cell.head;
                current = cell.tail;
            }
            return total;
        }

        pub fn maxVal(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("maxVal requires integer element type");
            if (list == null) return 0;
            var current = list;
            var result: T = list.?.head;
            while (current) |cell| {
                if (cell.head > result) result = cell.head;
                current = cell.tail;
            }
            return result;
        }

        pub fn minVal(list: ?*const Self) T {
            if (comptime @typeInfo(T) != .int) @compileError("minVal requires integer element type");
            if (list == null) return 0;
            var current = list;
            var result: T = list.?.head;
            while (current) |cell| {
                if (cell.head < result) result = cell.head;
                current = cell.tail;
            }
            return result;
        }
    };
}

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

    /// Create a new map with a key's value updated.
    /// Returns the same map type with the matching entry's value replaced.
    pub fn put(map: anytype, key: anytype, value: anytype) @TypeOf(map) {
        var result = map;
        const info = @typeInfo(@TypeOf(map));
        if (info != .@"struct") return result;
        inline for (info.@"struct".fields) |field| {
            const entry = @field(map, field.name);
            const E = @TypeOf(entry);
            const e_info = @typeInfo(E);
            if (e_info == .@"struct") {
                const is_kv = comptime blk: {
                    for (e_info.@"struct".fields) |f| {
                        if (std.mem.eql(u8, f.name, "key")) break :blk true;
                    }
                    break :blk false;
                };
                if (is_kv) {
                    if (keysEqual(entry.key, key)) {
                        @field(result, field.name).value = value;
                    }
                }
            }
        }
        return result;
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

test "String operations" {
    try std.testing.expect(String.contains("hello world", "world"));
    try std.testing.expect(!String.contains("hello world", "xyz"));
    try std.testing.expect(String.startsWith("hello", "hel"));
    try std.testing.expect(String.endsWith("hello", "llo"));
    try std.testing.expectEqualStrings("llo", String.slice("hello", 2, 5));
    try std.testing.expectEqualStrings("hello", String.trim("  hello  "));
}

test "String concat" {
    try std.testing.expectEqualStrings("hello world", String.concat("hello", " world"));
}

