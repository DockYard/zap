//! Phase 1 spike: no-op memory manager.
//!
//! Emits a minimal `.zapmem` section per the Memory Manager ABI v1.0 spec
//! (`docs/memory-manager-abi.md`, sections 3, 4, 14). The manager:
//!   * Declares zero capabilities (`declared_caps = 0`).
//!   * Embeds zero descriptors (`desc_count = 0`).
//!   * `init` returns a non-null placeholder so the runtime considers
//!     initialization successful.
//!   * `deinit` is a no-op.
//!   * `allocate` returns null (the runtime aborts with OOM diagnostic).
//!   * `deallocate` is a no-op.
//!   * `get_capability_desc` returns null for every ID.
//!
//! This is the no-op manager from spec section 14, used to validate the
//! end-to-end .zapmem emission/parsing pipeline and (later) to verify
//! that with `declared_caps = 0` the compiler elides every retain/release.

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

// FourCC 'ZMEM' as a u32 in the target's endianness.
const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("unsupported object format for .zapmem section"),
};

// Non-null placeholder context so the runtime can distinguish init
// success from init failure. The address of the placeholder is the
// `ctx` pointer threaded through every subsequent vtable call.
var noop_context_placeholder: u8 = 0;

fn noopInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(&noop_context_placeholder);
}

fn noopDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
}

fn noopAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    return null;
}

fn noopDeallocate(
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

fn noopGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

// Recommended emission pattern (spec section 3.2): wrap the meta header
// and core vtable into a single composite extern struct and emit it as
// one `export const ... linksection(...)` so that linker preserves the
// relative order.
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

pub export const zap_memory_section: ZapMemorySection
    linksection(SECTION_NAME) = .{
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
        .init = noopInit,
        .deinit = noopDeinit,
        .allocate = noopAllocate,
        .deallocate = noopDeallocate,
        .get_capability_desc = noopGetCapabilityDesc,
    },
};

// A trivial extra symbol used by the spike driver to confirm that
// `zap_fork_compile_zig_to_object` produces an object file containing
// caller-defined symbols (independent of the .zapmem section).
pub export const noop_const: u32 = 42;
