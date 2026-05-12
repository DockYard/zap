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
//! Any field rename, reorder, or size change here must be accompanied by
//! a corresponding update to the spec doc and an ABI minor/major bump
//! per spec section 2.3.

const std = @import("std");

/// `ZMEM` FourCC magic, read as a little-endian u32. The byte sequence
/// `5A 4D 45 4D` spells `Z`, `M`, `E`, `M` in either byte order; the
/// integer constant below is the little-endian interpretation.
pub const ZMEM_MAGIC_LE: u32 = 0x4D454D5A;

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
pub const ZapInitOptionsV1 = extern struct {
    size: u32,
    reserved: u32,
};

/// Capability descriptor record embedded in the manager's `.zapmem`
/// metadata block (after the meta header). Spec section 3.6.
pub const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

/// Core capability vtable. Spec section 4.2.
pub const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init_fn: *const anyopaque,
    deinit_fn: *const anyopaque,
    allocate_fn: *const anyopaque,
    deallocate_fn: *const anyopaque,
    get_capability_desc_fn: *const anyopaque,
};

test "ZapMemoryManagerMetaV1 layout is exactly 32 bytes" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ZapMemoryManagerMetaV1));
}

test "ZMEM_MAGIC_LE is little-endian 'ZMEM'" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, ZMEM_MAGIC_LE, .little);
    try std.testing.expectEqualStrings("ZMEM", &buf);
}
