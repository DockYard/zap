//! `Memory.NoOp` — production no-op memory manager.
//!
//! Declares zero capabilities, allocate returns null, deallocate is a no-op,
//! `get_capability_desc` returns null for every ID. Conforms to the Memory
//! Manager ABI v1.0 contract documented in `docs/memory-manager-abi.md`
//! sections 3, 4, and 14.
//!
//! This manager is the primary integration test target for the external-
//! manager pipeline: a Zap program built with `memory: Memory.NoOp` in
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

/// NoOp's declared capabilities — **Axis A == BULK_OR_NEVER**.
///
/// NoOp never allocates and never frees. It shares the BULK_OR_NEVER
/// reclamation model with Arena and Leak: in the capability-axis encoding (see
/// `src/memory/abi.zig`) that is bit 0 clear with the Axis-A field at its zero
/// encoding — `declared_caps == 0x0`. The compiler elides every retain/release
/// and individual free; no `ArcHeader` is laid out. The Zap-side abi module's
/// `CAPS_BULK_OR_NEVER` constant equals this value; this manager redeclares it
/// locally because the production-manager rule forbids importing sibling
/// compiler modules.
const CAP_DECLARED_CAPS: u64 = 0x0000_0000_0000_0000;

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

/// The section payload. Exported so the linker does not dead-strip it.
///
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
        .declared_caps = CAP_DECLARED_CAPS, // Axis A == BULK_OR_NEVER (0x0).
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_DECLARED_CAPS,
        .init = noOpInit,
        .deinit = noOpDeinit,
        .allocate = noOpAllocate,
        .deallocate = noOpDeallocate,
        .get_capability_desc = noOpGetCapabilityDesc,
    },
};

// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs (Phase 4)
//
// NoOp declares zero capabilities. The runtime's Phase 6 codegen elides
// every retain/release call site under a manager that omits the
// capability, so the stubs below are never invoked in practice. They
// exist solely to give the uniform first-party manager interface a
// complete set of symbols — see the matching section in
// `src/memory/arc/manager.zig` for the full rationale.
// ---------------------------------------------------------------------------

fn noOpRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn noOpReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn noOpRetainSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn noOpReleaseSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    _ = deep_walk;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn noOpAllocateRefcountedStub(
    ctx: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn noOpRefcountSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn releaseSizedClass(
    ctx: *anyopaque,
    object: *anyopaque,
    comptime class_index: u32,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    _ = deep_walk;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.NoOp does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface (Phase 4)
//
// See the matching section in `src/memory/arc/manager.zig` for the full
// rationale.
// ---------------------------------------------------------------------------

pub const init = noOpInit;
pub const deinit = noOpDeinit;
pub const allocate = noOpAllocate;
pub const deallocate = noOpDeallocate;
pub const allocateRefcounted = noOpAllocateRefcountedStub;
pub const retain = noOpRetainStub;
pub const release = noOpReleaseStub;
pub const retainSized = noOpRetainSizedStub;
pub const releaseSized = noOpReleaseSizedStub;
pub const refcountSized = noOpRefcountSizedStub;
pub const getCapabilityDesc = noOpGetCapabilityDesc;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock
//
// `Memory.NoOp` does NOT declare REFCOUNT_V1, so the refcount
// aliases above point at panic-stub bodies. The bodies are never
// invoked (the runtime's comptime dispatch elides those call sites
// under no-REFCOUNT_V1 builds), but the panic-stub signatures still
// MUST match the canonical AbiV1 slot types because the runtime
// source compiles uniformly across both first-party and third-party
// builds — the type system has to validate the shape of every alias,
// not just the ones that get reached at runtime. Pinning each alias
// against its canonical slot type at module scope catches drift at
// the manager build site rather than at user-binary link time.
comptime {
    const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;
    const InitFn = *const fn (options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque;
    const DeinitFn = *const fn (ctx: *anyopaque) callconv(.c) void;
    const AllocateFn = *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8;
    const DeallocateFn = *const fn (ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void;
    const GetCapDescFn = *const fn (ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1;
    const RetainFn = *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void;
    const ReleaseFn = *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void;
    const RetainSizedFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void;
    const ReleaseSizedFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32, deep_walk: ?ZapDeepWalkFn) callconv(.c) void;
    const AllocateRefcountedFn = *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8;
    const RefcountSizedFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32;
    const ClassIndexFn = fn (comptime size: usize, comptime alignment: u32) callconv(.@"inline") ?u32;
    const AllocateRefcountedClassFn = fn (ctx: *anyopaque, comptime class_index: u32) callconv(.@"inline") ?[*]u8;
    const RetainSizedClassFn = fn (ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) callconv(.@"inline") void;
    const ReleaseSizedClassFn = fn (ctx: *anyopaque, object: *anyopaque, comptime class_index: u32, deep_walk: ?ZapDeepWalkFn) callconv(.@"inline") void;
    const RefcountSizedClassFn = fn (ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) callconv(.@"inline") u32;

    _ = @as(InitFn, init);
    _ = @as(DeinitFn, deinit);
    _ = @as(AllocateFn, allocate);
    _ = @as(DeallocateFn, deallocate);
    _ = @as(GetCapDescFn, getCapabilityDesc);
    _ = @as(RetainFn, retain);
    _ = @as(ReleaseFn, release);
    _ = @as(RetainSizedFn, retainSized);
    _ = @as(ReleaseSizedFn, releaseSized);
    _ = @as(AllocateRefcountedFn, allocateRefcounted);
    _ = @as(RefcountSizedFn, refcountSized);
    _ = @as(*const ClassIndexFn, refcountSlabClassIndex);
    _ = @as(*const AllocateRefcountedClassFn, allocateRefcountedClass);
    _ = @as(*const RetainSizedClassFn, retainSizedClass);
    _ = @as(*const ReleaseSizedClassFn, releaseSizedClass);
    _ = @as(*const RefcountSizedClassFn, refcountSizedClass);
}
