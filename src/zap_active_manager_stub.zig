//! Stub registered as `zap_active_manager` only for the host Zig test
//! build. Compiler-driven Zap binaries register the selected
//! `Memory.Manager` adapter's convention-resolved backend source instead.
//!
//! Host tests load `runtime.zig` directly and keep
//! `active_manager_source_available == false`, so runtime hot paths bind
//! the test-only ARC fallback state and should not call into this module.
//! The panic-stub functions below give the source-backed interface a
//! complete set of well-typed symbols so the runtime source still
//! compiles uniformly. Reaching any of these panics would indicate that a
//! source-backed call was emitted for a build that did not register a real
//! manager source.
//!
//! The exact function signatures match `AbiV1.ZapMemoryManagerCoreV1`
//! and `AbiV1.ZapRefcountCapabilityV1` in `src/runtime.zig` so the
//! Zig compiler accepts them as type-compatible substitutes for the
//! real manager implementations during semantic
//! analysis.

const std = @import("std");

// ABI v1.0 extern types are redeclared locally rather than imported
// from `src/memory/abi.zig` because this stub is `@embedFile`'d into
// the compiler binary and parsed as a standalone source unit — the
// same self-contained convention every primitive `manager.zig`
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
