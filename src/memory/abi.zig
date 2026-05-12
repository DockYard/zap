//! Memory Manager ABI v1.0 — canonical Zig source for shared extern types.
//!
//! This module is the single source of truth on the Zig side for the
//! `.zapmem` metadata structures defined in `docs/memory-manager-abi.md`
//! sections 3 and 4. Both the section parser (`section_parser.zig`) and
//! any future Zig-side manager runtime should import these types from
//! here rather than redeclaring them locally.
//!
//! The spike's no-op manager (`spike/manager_v1/src/manager.zig`)
//! intentionally redeclares its own copies because it is throwaway code
//! built against the C ABI rather than against this Zig module. Future
//! first-party managers should depend on this module directly.
//!
//! `runtime.zig` ALSO redeclares the same shapes — but for a different
//! reason: `runtime.zig` is `@embedFile`'d into the Zap compiler and
//! injected into every Zap user binary as a standalone source unit with
//! no sibling files (it can only import `std` and `builtin`). The
//! redeclaration there is unavoidable; the `comptime` size asserts in
//! both modules tripwire any accidental drift.
//!
//! Any field rename, reorder, or size change here must be accompanied by
//! a corresponding update to the spec doc, the matching runtime-side
//! shape in `src/runtime.zig` (search for `pub const AbiV1 = struct`),
//! and an ABI minor/major bump per spec section 2.3.

const std = @import("std");
const builtin = @import("builtin");

/// `ZMEM` FourCC magic, read as a little-endian u32. The byte sequence
/// `5A 4D 45 4D` spells `Z`, `M`, `E`, `M` in either byte order; the
/// integer constant below is the little-endian interpretation.
pub const ZMEM_MAGIC_LE: u32 = 0x4D454D5A;

/// `REFC` capability tag (spec section 7.1) read at the target's native
/// endianness. The spec mandates that managers use `std.mem.readInt(u32,
/// "REFC", target_endianness)` rather than hand-computed hex literals so
/// the constant resolves correctly on either byte order.
pub const REFC_TAG: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4346_4552,
    .big => 0x5245_4643,
};

/// `REFCOUNT_V1` bit in `declared_caps` (spec section 7.1). Bit 0.
pub const REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

/// `.zapmem` metadata header. Spec section 3.5. The exact 32-byte
/// layout is normative for ABI v1.0; the `comptime` assertion below
/// guards against accidental drift.
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
        "abi: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
}

/// Options passed to the manager's `init` entry point. Spec section 4.1.
///
/// Unlike `ZapMemoryManagerMetaV1`, `ZapCapabilityDescV1`, and
/// `ZapMemoryManagerCoreV1` — which are versioned by structural layout
/// and grow new `*V2` siblings on minor bumps — `ZapInitOptions` evolves
/// in place via the leading `size` field. Callers pass `size = sizeof(<their
/// known options>)`; managers compiled against newer versions read up to
/// `size` bytes and ignore the trailer, and managers compiled against
/// older versions read up to `sizeof(<known options>)` bytes and ignore
/// the trailing fields the caller doesn't yet know about. The naming
/// drops the `V1` suffix to make this single-concept evolution explicit.
pub const ZapInitOptions = extern struct {
    size: u32,
    reserved: u32,
};

comptime {
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "abi: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
}

/// Capability descriptor record embedded in the manager's `.zapmem`
/// metadata block (after the meta header). Spec section 3.6.
pub const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

comptime {
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "abi: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
}

/// Compiler-emitted deep-walk callback. When the refcount of an object
/// drops to zero, the manager's release function invokes this callback
/// (if non-null) to release the object's children. Spec section 8.
///
/// Calling convention is `callconv(.c)` so the callback pointer is
/// ABI-stable and can be stored in cell headers alongside type tags.
pub const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

/// Core capability vtable. Spec section 4.2.
///
/// Function-pointer fields are typed (rather than `*const anyopaque`)
/// so callers obtain compile-time argument and return-type checking at
/// every dispatch site. The `extern struct` layout still matches the
/// ABI: typed function pointers occupy the same 8 bytes as a raw
/// `*const anyopaque` on the supported 64-bit targets.
pub const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (ctx: *anyopaque) callconv(.c) void,
    allocate: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void,
    get_capability_desc: *const fn (ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1,
};

comptime {
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "abi: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );
}

/// `REFCOUNT_V1` capability vtable. Spec section 8. Pointed at by a
/// `ZapCapabilityDescV1` whose `id == REFC_TAG` and `version == 1`.
///
/// `retain` increments the reference count. `release` decrements and,
/// on the zero-transition, invokes `deep_walk(object)` (if non-null)
/// before freeing the cell's storage. The manager owns the full
/// freeing path for refcounted cells — see spec section 8.2.
pub const ZapRefcountCapabilityV1 = extern struct {
    retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
    release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
};

comptime {
    if (@sizeOf(ZapRefcountCapabilityV1) != 16) @compileError(
        "abi: ZapRefcountCapabilityV1 v1.0 must be exactly 16 bytes",
    );
}

test "ZapMemoryManagerMetaV1 layout is exactly 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ZapMemoryManagerMetaV1));
}

test "ZapInitOptions layout is exactly 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ZapInitOptions));
}

test "ZapCapabilityDescV1 layout is exactly 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ZapCapabilityDescV1));
}

test "ZapMemoryManagerCoreV1 layout is exactly 56 bytes" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(ZapMemoryManagerCoreV1));
}

test "ZapRefcountCapabilityV1 layout is exactly 16 bytes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ZapRefcountCapabilityV1));
}

test "ZMEM_MAGIC_LE is little-endian 'ZMEM'" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, ZMEM_MAGIC_LE, .little);
    try std.testing.expectEqualStrings("ZMEM", &buf);
}

test "REFC_TAG round-trips through native endian" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, REFC_TAG, builtin.target.cpu.arch.endian());
    try std.testing.expectEqualStrings("REFC", &buf);
}

test "REFCOUNT_V1_BIT is bit 0" {
    try std.testing.expectEqual(@as(u64, 1), REFCOUNT_V1_BIT);
}
