//! `Zap.Memory.Arena` — placeholder (Phase 5 implementation pending).
//!
//! This file exists so the `Zap.Memory.Arena` stdlib struct in
//! `lib/zap/memory/arena.zap` has a valid `@memory_manager_source` target.
//! Phase 5 of the pluggable memory manager roadmap will replace it with a
//! production arena manager. For now the file emits a valid `.zapmem`
//! section that declares zero capabilities — selecting `Zap.Memory.Arena` in
//! a manifest produces a binary whose first allocation aborts, exactly like
//! `Zap.Memory.NoOp`.
//!
//! Once Phase 5 lands, this file will gain the real arena implementation
//! (single bump allocator, no individual deallocation, reset at shutdown).
//! The stdlib struct's `@memory_manager_source` attribute does not need to
//! change.

const std = @import("std");
const builtin = @import("builtin");

const ZapMemoryManagerMetaV1 = extern struct {
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

const ZapInitOptions = extern struct {
    size: u32,
    reserved: u32,
};

const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (?*const ZapInitOptions) callconv(.c) ?*anyopaque,
    deinit: *const fn (*anyopaque) callconv(.c) void,
    allocate: *const fn (*anyopaque, usize, u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (*anyopaque, [*]u8, usize, u32) callconv(.c) void,
    get_capability_desc: *const fn (*anyopaque, u32) callconv(.c) ?*const ZapCapabilityDescV1,
};

const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("arena: unsupported object format for .zapmem section"),
};

const arena_context_sentinel: u8 = 0;

fn arenaInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(@constCast(&arena_context_sentinel));
}

fn arenaDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
}

fn arenaAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    // Phase 5 will replace this with a real bump allocator. Until then the
    // placeholder declares zero capabilities and returns null on every
    // allocation — selecting Zap.Memory.Arena in a manifest produces a
    // binary that aborts on first allocation, matching Zap.Memory.NoOp.
    return null;
}

fn arenaDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = size;
    _ = alignment;
}

fn arenaGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// **`zap_memory_section` is a MANDATORY exported symbol name for every
/// memory manager** — first-party and third-party alike. The runtime's
/// bootstrap (`src/runtime.zig`'s `externalMemorySection`) discovers the
/// payload via `@extern(?*const ExternalMemorySectionPrefix, .{ .name =
/// "zap_memory_section", .linkage = .weak })`. A manager that emits the
/// `.zapmem` section under any other symbol name (or as an unnamed
/// section payload) will produce a binary whose weak-extern resolves to
/// null at runtime, silently falling back to the built-in ARC vtable.
///
/// The driver enforces this contract at build time: see
/// `src/memory/driver.zig`'s post-link symbol check (`assertExportsManagerSymbol`).
/// Spec section 3.2 + section 10.5 codify the requirement; this comment
/// pins the implementation-side invariant in source.
pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0,
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = arenaInit,
        .deinit = arenaDeinit,
        .allocate = arenaAllocate,
        .deallocate = arenaDeallocate,
        .get_capability_desc = arenaGetCapabilityDesc,
    },
};
