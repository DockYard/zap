//! Stub registered as `zap_active_manager` when the build selects a
//! third-party memory manager. The runtime's `.third_party` comptime
//! branch never references symbols from this module; it routes through
//! the manager `.o`'s `.zapmem`-registered vtable instead. This stub
//! exists solely so the runtime's top-level
//! `@import("zap_active_manager")` resolves cleanly.
//!
//! ## Source-of-truth note
//!
//! The bytes of this file are `@embedFile`'d by `src/compiler.zig` as
//! `THIRD_PARTY_ACTIVE_MANAGER_STUB` (consumed by the user-binary
//! build via `getActiveManagerSourceBytes(.third_party)`) AND
//! registered as the `zap_active_manager` sibling module in
//! `build.zig` (consumed by the host test suite that loads
//! `runtime.zig` as a Zig module). Both consumers MUST point at this
//! same file — never duplicate the contents inline.
//!
//! ## Uniform first-party manager interface (Phase 4)
//!
//! Phase 4 introduced a uniform `pub` interface on every first-party
//! manager — `init`, `deinit`, `allocate`, `deallocate`, `retain`,
//! `release`, `retainSized`, `releaseSized`, `allocateRefcounted`,
//! `refcountSized`, `getCapabilityDesc`, and the first-party class
//! specialization helpers — so the runtime's comptime
//! dispatch can call into the active manager's hot paths directly
//! through `@import("zap_active_manager")` and let LLVM inline across
//! the module boundary (the whole motivation behind Phases 3-5 of the
//! perf-recovery plan).
//!
//! Under a `.third_party` build, the runtime's comptime branch always
//! selects the vtable path — `active_manager.<fn>(...)` is never called.
//! The panic-stub functions below give the uniform interface a complete
//! set of well-typed symbols so the runtime source compiles uniformly
//! across both first-party and third-party builds. Reaching any of
//! these panics would indicate that the runtime's
//! `if (comptime ACTIVE_MANAGER_TAG == .third_party)` guard somehow
//! routed a call through the first-party arm — a soundness bug. The
//! panic messages are loud and specific so that bug surfaces at the
//! call site rather than masquerading as an indirect crash.
//!
//! The exact function signatures match `AbiV1.ZapMemoryManagerCoreV1`
//! and `AbiV1.ZapRefcountCapabilityV1` in `src/runtime.zig` so the
//! Zig compiler accepts them as type-compatible substitutes for the
//! first-party managers' real implementations during semantic
//! analysis.

const std = @import("std");

// ABI v1.0 extern types are redeclared locally rather than imported
// from `src/memory/abi.zig` because this stub is `@embedFile`'d into
// the compiler binary and parsed as a standalone source unit — the
// same self-contained convention every first-party `manager.zig`
// follows (spec section 11.1.1).

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

const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

pub fn init(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    @panic("third-party stub: init unreachable — vtable path always selected under .third_party builds");
}

pub fn deinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
    @panic("third-party stub: deinit unreachable — vtable path always selected under .third_party builds");
}

pub fn allocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("third-party stub: allocate unreachable — vtable path always selected under .third_party builds");
}

pub fn deallocate(ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = size;
    _ = alignment;
    @panic("third-party stub: deallocate unreachable — vtable path always selected under .third_party builds");
}

pub fn allocateRefcounted(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("third-party stub: allocateRefcounted unreachable — vtable path always selected under .third_party builds");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("third-party stub: allocateRefcountedClass unreachable — vtable path always selected under .third_party builds");
}

pub fn retain(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("third-party stub: retain unreachable — vtable path always selected under .third_party builds");
}

pub fn release(ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("third-party stub: release unreachable — vtable path always selected under .third_party builds");
}

pub fn retainSized(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("third-party stub: retainSized unreachable — vtable path always selected under .third_party builds");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("third-party stub: retainSizedClass unreachable — vtable path always selected under .third_party builds");
}

pub fn releaseSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    _ = deep_walk;
    @panic("third-party stub: releaseSized unreachable — vtable path always selected under .third_party builds");
}

pub inline fn releaseSizedClass(
    ctx: *anyopaque,
    object: *anyopaque,
    comptime class_index: u32,
    deep_walk: ?ZapDeepWalkFn,
) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    _ = deep_walk;
    @panic("third-party stub: releaseSizedClass unreachable — vtable path always selected under .third_party builds");
}

pub fn refcountSized(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("third-party stub: refcountSized unreachable — vtable path always selected under .third_party builds");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("third-party stub: refcountSizedClass unreachable — vtable path always selected under .third_party builds");
}

pub fn getCapabilityDesc(ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    @panic("third-party stub: getCapabilityDesc unreachable — vtable path always selected under .third_party builds");
}
