//! `Custom.TrackingPool` — a TEST-FIXTURE third-party memory manager backend
//! that is NOT one of the five stdlib managers.
//!
//! ## Purpose: the capability-driven-codegen acceptance proof (Axis A ==
//! ## INDIVIDUAL_NO_REFCOUNT)
//!
//! Companion to `bulk_arena_manager.zig`. This manager declares **Axis A ==
//! INDIVIDUAL_NO_REFCOUNT** with **Axis B == CLONE_ON_SHARE** (`declared_caps
//! == 0x2`) — the identical capability bitmask `Memory.Tracking` declares —
//! while its type name (`Custom.TrackingPool`) is unknown to the compiler.
//! Because the compiler keys codegen off the caps bits and never the name, a
//! program built with this manager gets the **identical** Tracking codegen:
//! refcount ops elided, no `ArcHeader`, static **free-at-last-use** of owning
//! locals, and **clone-on-share** for persistent second owners (deep clone via
//! the runtime's `clone_on_share_active` path, which the compiler enables iff
//! `reclamationModel == individual_no_refcount && sharingStrategy ==
//! clone_on_share`).
//!
//! ## A deliberately DIFFERENT implementation from `Memory.Tracking`
//!
//! The stdlib Tracking manager (`src/memory/tracking/manager.zig`, ~1800 lines)
//! carries a full leak-attribution subsystem (per-allocation Zap-type +
//! backtrace, canary bytes, a runtime-installed report sink). `Custom.TrackingPool`
//! is a minimal but correct INDIVIDUAL_NO_REFCOUNT allocator: it really frees
//! each block on `core.deallocate` (the defining contract of the model) and
//! maintains a live-allocation counter so the Zest `assert_no_leaks` checkpoint
//! and the deinit-time survivor count are observable — proving the model's
//! free-at-last-use codegen actually reclaims memory. It deliberately omits the
//! backtrace/canary machinery: the acceptance proof is about the codegen
//! contract (driven by caps), not about reproducing Tracking's diagnostics.
//!
//! ## Self-contained convention (spec section 11.1.1)
//!
//! Imports only `std` + `builtin`; redeclares the ABI v1.0 extern shapes
//! locally with `comptime` size/offset asserts. `page_allocator` (no libc).
//! Each block is prefixed with a small bookkeeping header so `core.deallocate`
//! can return the exact backing slice to `page_allocator` and decrement the
//! live counter.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// ABI v1.0 extern types — redeclared locally (spec §11.1.1).
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
        "custom tracking_pool: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "custom tracking_pool: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "custom tracking_pool: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "custom tracking_pool: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "custom tracking_pool: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "custom tracking_pool: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "custom tracking_pool: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "custom tracking_pool: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "custom tracking_pool: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
    );
}

// ---------------------------------------------------------------------------
// Manager constants
// ---------------------------------------------------------------------------

const ZMEM_MAGIC: u32 = switch (builtin.target.cpu.arch.endian()) {
    .little => 0x4D454D5A,
    .big => 0x5A4D454D,
};

/// `Custom.TrackingPool`'s declared capabilities — **Axis A ==
/// INDIVIDUAL_NO_REFCOUNT, Axis B == CLONE_ON_SHARE**.
///
/// Bit 0 clear (no `REFCOUNT_V1`), Axis-A field (bits 1..2) == `0b01`
/// (`RECLAMATION_INDIVIDUAL_NO_REFCOUNT`), Axis-B bit (bit 3) clear
/// (`CLONE_ON_SHARE`) ⇒ `declared_caps == 0x2`. Byte-for-byte the value
/// `Memory.Tracking` declares; the matching Zap-side constant is
/// `abi.CAPS_INDIVIDUAL_NO_REFCOUNT`. The compiler reads these bits — never the
/// name — and gives this manager Tracking's static-free + clone-on-share codegen.
const CAP_DECLARED_CAPS: u64 = 0x0000_0000_0000_0002;

const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("custom tracking_pool: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Manager context — an individual-free allocator with a live-allocation
// counter.
//
// Each allocation is backed by a `page_allocator` slice prefixed with a
// `BlockHeader` recording the original backing length and the payload offset,
// so `core.deallocate` can free the exact slice and decrement the live count.
// The live count drives `liveAllocationStats` (the Zest `assert_no_leaks`
// checkpoint) and the deinit-time survivor assertion.
// ---------------------------------------------------------------------------

const BlockHeader = struct {
    /// Total backing length handed to / reclaimed from `page_allocator`.
    backing_len: usize,
    /// Byte offset from the backing base to the aligned payload pointer.
    payload_offset: usize,
};

const HEADER_RESERVE: usize = @sizeOf(BlockHeader) + @alignOf(BlockHeader);

const TrackingPoolContext = struct {
    /// Number of live (allocated, not-yet-freed) blocks.
    live_count: u64,
    /// Sum of payload bytes across live blocks.
    live_bytes: u64,
};

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// `core.init` (spec §4.2).
fn trackingPoolInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const ctx = std.heap.page_allocator.create(TrackingPoolContext) catch return null;
    ctx.* = .{ .live_count = 0, .live_bytes = 0 };
    return @ptrCast(ctx);
}

/// `core.deinit` (spec §4.4). The **leak gate** for this fixture: any blocks
/// still live at normal-exit deinit are genuine survivors that the
/// INDIVIDUAL_NO_REFCOUNT free-at-last-use codegen failed to reclaim. We print
/// a precise, greppable survivor line to stderr so an acceptance harness can
/// assert leak-freedom by its ABSENCE (a clean program leaves `live_count ==
/// 0`). This is the minimal, self-contained leak gate — it does not reproduce
/// `Memory.Tracking`'s per-allocation backtrace/canary subsystem (which is a
/// diagnostic concern, not part of the caps-driven codegen contract under
/// test). After reporting, the context is freed; the OS reclaims any survivor
/// backing on exit.
fn trackingPoolDeinit(ctx: *anyopaque) callconv(.c) void {
    const pool_ctx: *TrackingPoolContext = @ptrCast(@alignCast(ctx));
    if (pool_ctx.live_count != 0) {
        // `std.debug.print` writes to stderr via basic syscalls, bypassing the
        // `Io` interface — the established self-contained-manager diagnostic
        // path in this fork (see `src/memory/tracking/manager.zig`'s
        // `defaultDiagnosticWriter`). The fixture must not depend on buffered
        // IO that may already be torn down at deinit.
        std.debug.print(
            "Custom.TrackingPool LEAK: {d} live allocation(s), {d} byte(s) survived to deinit\n",
            .{ pool_ctx.live_count, pool_ctx.live_bytes },
        );
    }
    std.heap.page_allocator.destroy(pool_ctx);
}

/// `core.allocate` (spec §4.2). Allocates a backing slice large enough for the
/// header + alignment padding + payload, writes the header, bumps the live
/// counter, and returns the aligned payload pointer.
fn trackingPoolAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const pool_ctx: *TrackingPoolContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));

    // Reserve room for the header (which we place immediately before the
    // aligned payload) plus worst-case alignment padding plus the payload.
    const reserve = HEADER_RESERVE + alignment + size;
    const backing = std.heap.page_allocator.alloc(u8, reserve) catch return null;

    const base = @intFromPtr(backing.ptr);
    // The payload must be aligned AND leave at least @sizeOf(BlockHeader) bytes
    // before it for the header. Align the candidate that sits past the header.
    const min_payload = base + HEADER_RESERVE;
    const payload_addr = std.mem.alignForward(usize, min_payload, alignment);
    const payload_offset = payload_addr - base;

    // The header sits immediately before the payload, naturally aligned.
    const header_addr = std.mem.alignBackward(usize, payload_addr - @sizeOf(BlockHeader), @alignOf(BlockHeader));
    const header: *BlockHeader = @ptrFromInt(header_addr);
    header.* = .{ .backing_len = backing.len, .payload_offset = payload_offset };

    pool_ctx.live_count += 1;
    pool_ctx.live_bytes += @as(u64, size);
    return @ptrFromInt(payload_addr);
}

/// `core.deallocate` (spec §4.2). The defining INDIVIDUAL_NO_REFCOUNT
/// behaviour: actually free the block. Recovers the header to find the backing
/// slice, decrements the live counter, and returns the slice to
/// `page_allocator`.
fn trackingPoolDeallocate(ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void {
    _ = alignment;
    const pool_ctx: *TrackingPoolContext = @ptrCast(@alignCast(ctx));

    const payload_addr = @intFromPtr(ptr);
    const header_addr = std.mem.alignBackward(usize, payload_addr - @sizeOf(BlockHeader), @alignOf(BlockHeader));
    const header: *BlockHeader = @ptrFromInt(header_addr);
    const base = payload_addr - header.payload_offset;
    const backing_ptr: [*]u8 = @ptrFromInt(base);
    const backing = backing_ptr[0..header.backing_len];

    pool_ctx.live_count -= 1;
    pool_ctx.live_bytes -= @as(u64, size);
    std.heap.page_allocator.free(backing);
}

fn trackingPoolGetCapabilityDesc(ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

/// Optional manager interface (`@hasDecl`-gated in `src/runtime.zig`). Reports
/// the live-allocation count + bytes the runtime's `live_allocation_count()` /
/// `live_allocation_bytes()` surface — which the Zest `assert_no_leaks` macro
/// samples. Presence of this decl makes the runtime's `leak_tracking_active`
/// true for this manager, exactly as for `Memory.Tracking`.
pub fn liveAllocationStats(ctx: *anyopaque, out_count: *u64, out_bytes: *u64) callconv(.c) void {
    const pool_ctx: *TrackingPoolContext = @ptrCast(@alignCast(ctx));
    out_count.* = pool_ctx.live_count;
    out_bytes.* = pool_ctx.live_bytes;
}

// ---------------------------------------------------------------------------
// `.zapmem` section emission (spec §3.2)
// ---------------------------------------------------------------------------

const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_DECLARED_CAPS, // INDIVIDUAL_NO_REFCOUNT + CLONE_ON_SHARE (0x2) — identical to Memory.Tracking.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_DECLARED_CAPS,
        .init = trackingPoolInit,
        .deinit = trackingPoolDeinit,
        .allocate = trackingPoolAllocate,
        .deallocate = trackingPoolDeallocate,
        .get_capability_desc = trackingPoolGetCapabilityDesc,
    },
};

// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs — `Custom.TrackingPool` declares no REFCOUNT_V1
// (INDIVIDUAL_NO_REFCOUNT elides refcount ops). Never invoked under correct
// caps-driven codegen; reaching one is the acceptance signal that codegen
// wrongly emitted a refcount op for a non-refcounted manager.
// ---------------------------------------------------------------------------

fn trackingPoolRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingPoolReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingPoolRetainSizedStub(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingPoolReleaseSizedStub(
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
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingPoolAllocateRefcountedStub(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingPoolRefcountSizedStub(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
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
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Custom.TrackingPool does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface.
// ---------------------------------------------------------------------------

pub const init = trackingPoolInit;
pub const deinit = trackingPoolDeinit;
pub const allocate = trackingPoolAllocate;
pub const deallocate = trackingPoolDeallocate;
pub const allocateRefcounted = trackingPoolAllocateRefcountedStub;
pub const retain = trackingPoolRetainStub;
pub const release = trackingPoolReleaseStub;
pub const retainSized = trackingPoolRetainSizedStub;
pub const releaseSized = trackingPoolReleaseSizedStub;
pub const refcountSized = trackingPoolRefcountSizedStub;
pub const getCapabilityDesc = trackingPoolGetCapabilityDesc;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock.
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
