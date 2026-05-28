//! `Custom.BulkArena` — a TEST-FIXTURE third-party memory manager backend
//! that is NOT one of the five stdlib managers.
//!
//! ## Purpose: the capability-driven-codegen acceptance proof
//!
//! This backend exists to prove the adapter-bounded principle (CLAUDE.md;
//! `docs/capability-driven-memory-model-plan.md` "Verification matrix"): the
//! Zap compiler keys **every** memory-codegen decision off the manager's
//! declared `declared_caps` bits, **never** off the manager's name. This
//! manager declares **Axis A == BULK_OR_NEVER** (`declared_caps == 0x0`) — the
//! identical capability bitmask `Memory.Arena` declares — yet its type name
//! (`Custom.BulkArena`) is unknown to the compiler. If the compiler's codegen
//! gating special-cased manager names, a program built with this manager would
//! compile differently from the same program built with `Memory.Arena` (it
//! would emit retain/release ZIR ops and panic on the refcount panic-stubs
//! below at first refcounted-type construction). Because codegen reads only
//! the caps bits, the program instead gets the **identical** BULK_OR_NEVER
//! elision as Arena: zero retain/release ZIR ops, no `ArcHeader`, every
//! allocation served from this manager's `core.allocate`, bulk-freed at
//! `core.deinit`.
//!
//! ## A deliberately DIFFERENT implementation from `Memory.Arena`
//!
//! To make the proof airtight this is a genuinely different allocator from the
//! stdlib Arena (which wraps `std.heap.ArenaAllocator`): `Custom.BulkArena`
//! implements its own singly-linked-list-of-mmap'd-chunks bump allocator. The
//! point is that the codegen contract follows from the declared caps alone, so
//! the manager's internal allocation strategy is irrelevant — only that it
//! declares `BULK_OR_NEVER` and therefore performs no individual frees
//! (`core.deallocate` is a no-op; storage is reclaimed wholesale at
//! `core.deinit`).
//!
//! ## Self-contained convention (spec section 11.1.1)
//!
//! Compiled by the Zig-fork primitive `zap_fork_compile_zig_to_object` with
//! `link_libc = false`, so it imports only `std` and `builtin` and redeclares
//! the ABI v1.0 extern struct shapes locally. The `comptime` size/offset
//! asserts catch drift from the canonical definitions in `src/memory/abi.zig`.
//! `page_allocator` (direct `mmap`/`NtAllocateVirtualMemory`) is used rather
//! than `c_allocator` because libc is not linked.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// ABI v1.0 extern types — redeclared locally per the self-contained manager
// convention (spec section 11.1.1).
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
        "custom bulk_arena: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "custom bulk_arena: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "custom bulk_arena: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "custom bulk_arena: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "custom bulk_arena: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "custom bulk_arena: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "custom bulk_arena: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "custom bulk_arena: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "custom bulk_arena: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
    );
}

// ---------------------------------------------------------------------------
// Manager constants
// ---------------------------------------------------------------------------

/// `ZMEM` FourCC magic in the target's native byte order (spec §3.4).
const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

/// `Custom.BulkArena`'s declared capabilities — **Axis A == BULK_OR_NEVER**.
///
/// Bit 0 clear (no `REFCOUNT_V1`) with the Axis-A field (bits 1..2) at its
/// zero encoding ⇒ `declared_caps == 0x0`. This is byte-for-byte the value
/// `Memory.Arena` declares, so the compiler — reading caps, never the name —
/// gives this manager the identical Arena elision. The matching Zap-side
/// constant is `abi.CAPS_BULK_OR_NEVER`; redeclared locally because the
/// self-contained-manager rule forbids importing sibling compiler modules.
const CAP_DECLARED_CAPS: u64 = 0x0000_0000_0000_0000;

/// Object-format-conditional section name (spec §3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("custom bulk_arena: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Manager context — a bespoke chunked bump allocator.
//
// Deliberately NOT `std.heap.ArenaAllocator`: a singly-linked list of
// page-allocator-backed chunks, each bump-allocated. Demonstrates that the
// codegen contract follows from the declared BULK_OR_NEVER caps, not from
// reusing the stdlib Arena implementation.
// ---------------------------------------------------------------------------

const Chunk = struct {
    /// Backing bytes for this chunk (a single `page_allocator` region).
    bytes: []u8,
    /// Bump offset into `bytes`.
    used: usize,
    /// Previous chunk in the singly-linked list (null at the tail/first).
    prev: ?*Chunk,
};

const DEFAULT_CHUNK_SIZE: usize = 64 * 1024;

const BulkArenaContext = struct {
    /// Head of the chunk list (most-recently-allocated chunk).
    head: ?*Chunk,
};

fn allocChunk(min_size: usize, prev: ?*Chunk) ?*Chunk {
    const chunk_size = @max(min_size, DEFAULT_CHUNK_SIZE);
    const bytes = std.heap.page_allocator.alloc(u8, chunk_size) catch return null;
    const chunk = std.heap.page_allocator.create(Chunk) catch {
        std.heap.page_allocator.free(bytes);
        return null;
    };
    chunk.* = .{ .bytes = bytes, .used = 0, .prev = prev };
    return chunk;
}

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// `core.init` (spec §4.2). Allocates the context (and its first chunk lazily)
/// on `page_allocator`.
fn bulkArenaInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const ctx = std.heap.page_allocator.create(BulkArenaContext) catch return null;
    ctx.* = .{ .head = null };
    return @ptrCast(ctx);
}

/// `core.deinit` (spec §4.4). Bulk-frees every chunk, then the context — the
/// whole-program-lifetime reclamation that defines BULK_OR_NEVER.
fn bulkArenaDeinit(ctx: *anyopaque) callconv(.c) void {
    const arena_ctx: *BulkArenaContext = @ptrCast(@alignCast(ctx));
    var maybe_chunk = arena_ctx.head;
    while (maybe_chunk) |chunk| {
        const prev = chunk.prev;
        std.heap.page_allocator.free(chunk.bytes);
        std.heap.page_allocator.destroy(chunk);
        maybe_chunk = prev;
    }
    std.heap.page_allocator.destroy(arena_ctx);
}

/// `core.allocate` (spec §4.2). Bump-allocates from the head chunk, growing a
/// new chunk when the request does not fit. `alignment` is a power-of-two byte
/// count ≥ `@alignOf(usize)` per the spec contract.
fn bulkArenaAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const arena_ctx: *BulkArenaContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));

    // Try the head chunk; if the aligned request does not fit, grow.
    if (arena_ctx.head) |chunk| {
        if (bumpFrom(chunk, size, alignment)) |ptr| return ptr;
    }

    // Need a fresh chunk large enough for the aligned request (worst-case the
    // alignment padding plus the size).
    const fresh = allocChunk(size + alignment, arena_ctx.head) orelse return null;
    arena_ctx.head = fresh;
    return bumpFrom(fresh, size, alignment);
}

fn bumpFrom(chunk: *Chunk, size: usize, alignment: u32) ?[*]u8 {
    const base = @intFromPtr(chunk.bytes.ptr);
    const cursor = base + chunk.used;
    const aligned = std.mem.alignForward(usize, cursor, alignment);
    const padding = aligned - cursor;
    const new_used = chunk.used + padding + size;
    if (new_used > chunk.bytes.len) return null;
    chunk.used = new_used;
    return @ptrFromInt(aligned);
}

/// `core.deallocate` (spec §4.2). No-op — BULK_OR_NEVER never frees
/// individually; storage is reclaimed wholesale at `core.deinit`.
fn bulkArenaDeallocate(ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = size;
    _ = alignment;
}

/// Capability descriptor lookup. Declares zero capabilities ⇒ always null.
fn bulkArenaGetCapabilityDesc(ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

// ---------------------------------------------------------------------------
// `.zapmem` section emission (spec §3.2)
// ---------------------------------------------------------------------------

const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// MANDATORY exported symbol `zap_memory_section` (spec §3.2). The runtime
/// discovers the payload via this exact name; the driver enforces it post-link.
pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_DECLARED_CAPS, // Axis A == BULK_OR_NEVER (0x0) — identical to Memory.Arena.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_DECLARED_CAPS,
        .init = bulkArenaInit,
        .deinit = bulkArenaDeinit,
        .allocate = bulkArenaAllocate,
        .deallocate = bulkArenaDeallocate,
        .get_capability_desc = bulkArenaGetCapabilityDesc,
    },
};

// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs — `Custom.BulkArena` declares no REFCOUNT_V1.
//
// These are never invoked: the compiler's BULK_OR_NEVER codegen (selected
// purely from `declared_caps == 0x0`) elides every retain/release ZIR op. They
// exist only to give the uniform first-party manager interface a complete
// symbol set so the runtime source compiles. If a regression ever bypassed
// elision and reached one, the panic names the missing capability — which is
// itself the acceptance signal that codegen WRONGLY emitted a refcount op for a
// BULK_OR_NEVER manager.
// ---------------------------------------------------------------------------

fn bulkArenaRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn bulkArenaReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn bulkArenaRetainSizedStub(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn bulkArenaReleaseSizedStub(
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
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn bulkArenaAllocateRefcountedStub(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn bulkArenaRefcountSizedStub(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
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
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Custom.BulkArena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface — the `pub` names the runtime's
// comptime dispatch calls through `@import("zap_active_manager")`.
// ---------------------------------------------------------------------------

pub const init = bulkArenaInit;
pub const deinit = bulkArenaDeinit;
pub const allocate = bulkArenaAllocate;
pub const deallocate = bulkArenaDeallocate;
pub const allocateRefcounted = bulkArenaAllocateRefcountedStub;
pub const retain = bulkArenaRetainStub;
pub const release = bulkArenaReleaseStub;
pub const retainSized = bulkArenaRetainSizedStub;
pub const releaseSized = bulkArenaReleaseSizedStub;
pub const refcountSized = bulkArenaRefcountSizedStub;
pub const getCapabilityDesc = bulkArenaGetCapabilityDesc;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock — pins each alias against its
// canonical AbiV1 slot type at module scope so drift is caught at the manager
// build site rather than at user-binary link time.
// ---------------------------------------------------------------------------

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
