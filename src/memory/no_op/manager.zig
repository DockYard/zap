//! `Zap.Memory.NoOp` — production no-op memory manager.
//!
//! Declares zero capabilities, allocate returns null, deallocate is a no-op,
//! `get_capability_desc` returns null for every ID. Conforms to the Memory
//! Manager ABI v1.0 contract documented in `docs/memory-manager-abi.md`
//! sections 3, 4, and 14.
//!
//! This manager is the primary integration test target for the external-
//! manager pipeline: a Zap program built with `memory: Zap.Memory.NoOp` in
//! its build manifest compiles cleanly, the `.zapmem` section round-trips
//! through the section parser, and the first allocation aborts with the
//! documented OOM diagnostic.
//!
//! The file is self-contained — it only imports `std` and `builtin` — so it
//! can be compiled by the `zap_fork_compile_zig_to_object` primitive (which
//! does not yet accept Zig-package dependencies; see spec section 11.1.1).
//! All ABI extern struct shapes are redeclared locally rather than imported
//! from `src/memory/abi.zig`, matching the convention the spec mandates for
//! third-party managers (every byte of the wire contract is reachable from
//! the manager source).

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// ABI v1.0 extern types — redeclared locally per the self-contained manager
// convention (spec section 11.1.1). The `comptime` size asserts below catch
// any drift from the canonical Zig-side definitions in `src/memory/abi.zig`.
// ---------------------------------------------------------------------------

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

comptime {
    if (@sizeOf(ZapMemoryManagerMetaV1) != 32) @compileError(
        "no_op: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "no_op: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "no_op: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "no_op: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );
}

// ---------------------------------------------------------------------------
// Manager constants
// ---------------------------------------------------------------------------

/// `ZMEM` FourCC magic in the target's native byte order. The byte sequence
/// `5A 4D 45 4D` is the same on both endians; only the integer interpretation
/// differs (spec section 3.4).
const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

/// Object-format-conditional section name. Mach-O places the section inside
/// the `__DATA` segment; ELF and COFF use a top-level `.zapmem` section
/// (spec section 3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("no_op: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Manager context.
//
// The no-op manager has no per-process state to carry through `ctx`, but the
// spec (section 4.2) requires `init` to return a non-null pointer to signal
// success. We return the address of a `const` byte: the address is what
// matters, the byte is never written, and the symbol can live in `.rodata`.
// ---------------------------------------------------------------------------

const no_op_context_sentinel: u8 = 0;

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Returns a non-null sentinel address.
fn noOpInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    // `@constCast` drops the const-ness solely so the public ABI's
    // `?*anyopaque` can carry the address; the vtable contract is that
    // the manager never writes through `ctx`, so the discard is safe.
    return @ptrCast(@constCast(&no_op_context_sentinel));
}

/// Deinitialise the manager. No state to release.
fn noOpDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
}

/// Allocate. Always returns null — the no-op manager refuses every request.
/// The runtime detects the null return and aborts with the OOM diagnostic
/// documented in spec section 4.3.1.
fn noOpAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    return null;
}

/// Deallocate. Never called in practice (allocate always returns null), but
/// kept as a valid function pointer so the vtable is fully populated.
fn noOpDeallocate(
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

/// Capability descriptor lookup. The no-op manager declares no capabilities,
/// so every query returns null (spec section 5.5).
fn noOpGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

// ---------------------------------------------------------------------------
// `.zapmem` section emission (spec section 3.2)
// ---------------------------------------------------------------------------

/// Composite section payload. Wraps the meta header and core vtable into a
/// single `extern struct` so the linker emits them in declaration order as
/// one contiguous allocation. `meta.core_vtable_offset` is derived from the
/// struct layout via `@offsetOf`, so the section is always self-consistent
/// regardless of linker behaviour.
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// The section payload. Exported so the linker does not dead-strip it. The
/// recommended symbol name is `zap_memory_section`, but the compiler does
/// not rely on this name — it discovers the section purely by walking its
/// contents starting at offset 0 (spec section 3.2).
pub export const zap_memory_section: ZapMemorySection
    linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0, // No capabilities declared.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = noOpInit,
        .deinit = noOpDeinit,
        .allocate = noOpAllocate,
        .deallocate = noOpDeallocate,
        .get_capability_desc = noOpGetCapabilityDesc,
    },
};
