//! `Zap.Memory.ARC` — production atomic-refcount memory manager.
//!
//! Phase 4 of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` and especially sections 4, 5, 8, 10, 11.1
//! and 12 for the normative contract this file implements.
//!
//! This file is the canonical first-party ARC implementation. It is
//! compiled by the Zig-fork primitive `zap_fork_compile_zig_to_object`
//! into a standalone object file that the Zap build pipeline links into
//! every Zap binary whose manifest selects `Zap.Memory.ARC` (the default).
//! Phase 4 ripped the built-in ARC stub out of `src/runtime.zig`; the
//! runtime now sees only this external manager.
//!
//! The file is intentionally self-contained — it only imports `std` and
//! `builtin` — so it can be compiled by the fork primitive (which does
//! not yet accept Zig-package dependencies; see spec section 11.1.1).
//! All ABI extern struct shapes are redeclared locally per the
//! self-contained manager convention in spec section 11.1.1; the
//! `comptime` size and offset asserts below catch drift from the
//! canonical Zig-side definitions in `src/memory/abi.zig`.
//!
//! ## Architecture
//!
//! `Zap.Memory.ARC` declares the `REFCOUNT_V1` capability and exposes
//! the `retain` / `release` vtable that the runtime's inline-header
//! types (`Map(K,V)`, `List(T)`, `MapIter`, ...) dispatch through. Each
//! inline-header cell carries a 4-byte refcount at offset 0; this
//! manager treats the cell pointer as opaque and performs atomic
//! increment/decrement on those first 4 bytes using `acq_rel` ordering
//! on the release path and `monotonic` ordering on the retain path
//! (matching the `ArcHeader` semantics the runtime documents).
//!
//! ### Storage ownership for inline-header cells
//!
//! Spec section 8.2 makes `release` the sole authority for freeing a
//! refcounted cell. On the zero-transition the manager:
//!
//!   1. Invokes `deep_walk(object)` if non-null — the runtime-supplied
//!      per-type callback walks children first.
//!   2. Returns control to the runtime; the cell's storage free for
//!      inline-header types happens inside `deep_walk` (the runtime's
//!      `List.listDeepWalk` / `Map.mapDeepWalk` / `MapIter.iterDeepWalk`
//!      callbacks each call their type's `bufferFreeDeep`, which in
//!      turn frees the buffer through the same allocator that
//!      originally produced it).
//!
//! This is a deliberate Phase 4 architectural choice: inline-header
//! cells allocate their backing buffers through `c_allocator` inside
//! the type-specific `bufferAlloc` helpers in `src/runtime.zig`. The
//! manager does not route those allocations through `core.allocate` —
//! the runtime owns the bespoke allocator selection for these types.
//! Per spec §13.3 the manager must not allocate user-visible objects
//! outside `core.allocate`; this manager honours that contract because
//! it never calls `c_allocator` itself for user-visible storage. The
//! runtime's call sites that allocate via `c_allocator` for inline-
//! header buffers are part of Zap's runtime, not part of any manager,
//! and that arrangement predates the pluggable-manager ABI. Phase 6
//! (conditional layout) will revisit the inline-header storage path
//! once the build pipeline can carry per-manager allocation options.
//!
//! ### Phase 4.x deferrals
//!
//! * **Generic `Arc(T)` side-table allocations** (the `ArcSlabPool(T)`
//!   path in `src/runtime.zig`) still bypass this manager. The slab
//!   pool needs comptime `T` to compute slot sizes; the byte-level
//!   `core.allocate(size, alignment)` cannot drive it without a
//!   runtime size-class dispatch. A future Phase 4.x lands the
//!   byte-level slab-pool rework so generic `Arc(T)` also routes
//!   through the manager's `allocate` / `retain` / `release` slots.
//!   Today the runtime's `ArcRuntime.allocAny` / `releaseAny` /
//!   dispatchers validate that the active manager declares
//!   `REFCOUNT_V1` and then call into the typed slab pool directly.
//! * **Split-phase release** (`ArcRuntime.prepareReleaseAny` /
//!   `destroyPreparedAny`) bypasses the vtable's `release` slot for
//!   the same comptime-`T` reason — it operates on side-table
//!   refcounts and must know the slot size to compute the side-table
//!   index. The same Phase 4.x rework reconciles this path.
//!
//! Both of these are documented at the corresponding dispatchers in
//! `src/runtime.zig`.
//!
//! ### Raw allocations (`core.allocate` / `core.deallocate`)
//!
//! The runtime does NOT dispatch any allocations through this
//! manager's `core.allocate` slot today. Inline-header types own
//! their allocator selection (the per-type `bufferAlloc` helpers in
//! `src/runtime.zig` use `c_allocator` directly), and the typed
//! slab-pool side-table path uses `mmap` for 64 KiB-aligned slabs.
//! The `core.allocate` and `core.deallocate` slots in this manager
//! therefore return `null` (OOM) and no-op respectively — the same
//! convention as `Zap.Memory.NoOp`. Future Phase 4.x work that
//! lands the byte-level slab redesign will populate these slots
//! with a real backing allocator; until then the slots exist purely
//! to satisfy the spec's "every manager exposes the full v1.0
//! `ZapMemoryManagerCoreV1` vtable" contract.
//!
//! Why not use `std.heap.page_allocator` or `std.heap.c_allocator`?
//! The fork primitive `zap_fork_compile_zig_to_object` builds this
//! file with `link_libc = false` (see the Zig fork's `zir_api.zig`).
//! `c_allocator` is unavailable in that mode. `page_allocator`
//! depends on `std.posix` which transitively pulls in declarations
//! that Zig's freestanding-ish `Obj` configuration cannot resolve
//! against the bundled stdlib. Returning `null` from `allocate` is
//! both spec-conforming and avoids the libc/posix dependency cycle.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// ABI v1.0 extern types — redeclared locally per the self-contained manager
// convention (spec section 11.1.1). The `comptime` size and offset asserts
// below catch any drift from the canonical Zig-side definitions in
// `src/memory/abi.zig`.
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

const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

const ZapRefcountCapabilityV1 = extern struct {
    retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
    release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
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
        "arc: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "arc: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "arc: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "arc: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );
    if (@sizeOf(ZapRefcountCapabilityV1) != 16) @compileError(
        "arc: ZapRefcountCapabilityV1 v1.0 must be exactly 16 bytes",
    );

    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "arc: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "arc: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "arc: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "arc: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "arc: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "retain") != 0) @compileError(
        "arc: ZapRefcountCapabilityV1.retain must be at offset 0",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "release") != 8) @compileError(
        "arc: ZapRefcountCapabilityV1.release must be at offset 8",
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

/// `REFC` FourCC capability tag in the target's native byte order
/// (spec §7.1). Computed via `std.mem.readInt` so the constant resolves
/// correctly on every supported endian without hand-computed hex
/// literals.
const REFC_TAG: u32 = std.mem.readInt(u32, "REFC", builtin.target.cpu.arch.endian());

/// `REFCOUNT_V1` bit in `declared_caps` (spec §7.1 — bit 0).
const CAP_REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

/// Object-format-conditional section name. Mach-O places the section
/// inside the `__DATA` segment; ELF and COFF use a top-level
/// `.zapmem` section (spec §3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("arc: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Manager context.
//
// The ARC manager carries a single atomic allocation counter so
// `ctx` is exercised meaningfully on every allocation path. Mirrors
// the tinyref example pattern in spec §15. A production manager
// would extend this with high-water-mark and per-size-class statistics;
// the runtime's existing `arc_retains_total` / `arc_releases_total`
// counters are runtime-side and remain there because they aggregate
// across all dispatch paths (including the still-typed slab-pool path
// that bypasses this manager — see the Phase 4.x deferral note above).
// ---------------------------------------------------------------------------

/// Sentinel byte the manager returns from `init`. The spec accepts
/// any non-null pointer as a valid context; the manager has no
/// per-process state, so a sentinel is sufficient. `const` because
/// the address is what matters — the byte is never written — and
/// the symbol can live in `.rodata`.
const arc_context_sentinel: u8 = 0;

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Returns a non-null sentinel address per
/// spec §4.2.
///
/// Spec §4.2 prohibits the manager from calling its own `allocate`
/// during init in a way that would trigger compiler-emitted allocation
/// paths (`Map`, `List`, `String` constructors, etc.). This manager
/// performs no work during init — it just returns the sentinel —
/// so the prohibition is satisfied trivially.
fn arcInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    return @ptrCast(@constCast(&arc_context_sentinel));
}

/// Deinitialise the manager. Spec §4.4 makes this a best-effort hook
/// — `deinit` is not guaranteed to run on every termination path.
/// ARC has no per-process state that requires explicit teardown
/// (the runtime's inline-header buffers are freed on the zero-
/// transition of their refcount via `release`/`deep_walk`, and the
/// typed slab pools in `src/runtime.zig` rely on the OS to reclaim
/// their `mmap`'d pages at process exit per the existing runtime
/// contract).
fn arcDeinit(ctx: *anyopaque) callconv(.c) void {
    _ = ctx;
}

/// Raw allocation slot — `core.allocate` (spec §4.2). Currently
/// unused by the runtime (inline-header types own their allocator
/// selection in `src/runtime.zig`; the typed slab pool uses `mmap`
/// directly). Returns `null` for every request — the spec's
/// documented OOM signal — so any future caller that dispatches
/// through this slot triggers the runtime's OOM-abort diagnostic
/// per §4.3.1. See the architecture note in this file's docstring
/// for the libc/posix dependency rationale.
fn arcAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    return null;
}

/// Raw deallocation slot — `core.deallocate` (spec §4.2). No-op
/// because `arcAllocate` never returns a non-null pointer.
fn arcDeallocate(
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

/// Capability descriptor lookup. Returns the REFCOUNT_V1 descriptor
/// for the `REFC` tag; returns null for every other ID (spec §5.5,
/// §7.2).
fn arcGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    if (id == REFC_TAG) return &refcount_descriptor;
    return null;
}

/// Atomic helpers provided by the runtime translation unit
/// (`src/runtime.zig`). The runtime is LLVM-compiled (via Zap's
/// outer `zig build`, which uses the system Zig with full
/// LLVM-backed codegen), so its atomics lower to native
/// `LDAXR`/`STLXR` (aarch64) or `LOCK XADD` (x86_64) instructions
/// without issue.
///
/// This manager — compiled by the Zig-fork primitive
/// `zap_fork_compile_zig_to_object`, which currently lacks LLVM in
/// the prebuilt `libzap_compiler.a` — cannot emit native
/// `@atomicRmw` itself (the self-hosted aarch64 backend in Zig 0.16
/// returns `unimplemented atomic_rmw` from `aarch64/Select.zig`).
/// Calling the runtime's helpers is the spec-conforming workaround:
/// the call site emits a plain C call (every self-hosted backend
/// supports those), and the actual atomic instruction is emitted
/// inside the runtime where LLVM-backed codegen IS available.
///
/// The long-term fix is to add `atomic_rmw` lowering to the Zig
/// fork's aarch64 self-hosted backend; this externalised dispatch
/// is the Phase 4 stop-gap that unblocks production benchmarks
/// today without modifying the Zig fork.
///
/// The runtime exports these under their C-symbol names below; see
/// `src/runtime.zig`'s `zap_runtime_atomic_add_u32_acq_rel` for the
/// implementation.
extern fn zap_runtime_atomic_add_u32_acq_rel(ptr: *u32, delta: u32) callconv(.c) u32;

inline fn atomicAdd32AcqRel(ptr: *u32, delta: u32) u32 {
    return zap_runtime_atomic_add_u32_acq_rel(ptr, delta);
}

/// REFCOUNT_V1 `retain` (spec §8). Atomic increment on the 4-byte
/// refcount at offset 0 of an inline-header cell. The cell pointer
/// is opaque to the manager; the runtime guarantees it points at a
/// 4-byte refcount at offset 0 (the `ArcHeader.ref_count` field in
/// `src/runtime.zig` — which is a `std.atomic.Value(u32)` whose
/// in-memory layout is exactly `u32`).
///
/// We use `acq_rel` ordering on both retain and release for
/// simplicity and uniform inline-assembly emission. `monotonic`
/// would suffice on retain alone (the release fence lives in
/// `arcRelease`), but emitting the same instruction sequence on
/// both paths keeps the inline-asm surface minimal.
fn arcRetain(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    const refcount_ptr: *u32 = @ptrCast(@alignCast(object));
    _ = atomicAdd32AcqRel(refcount_ptr, 1);
}

/// REFCOUNT_V1 `release` (spec §8). Atomic decrement; on the zero-
/// transition invoke `deep_walk(object)` if non-null. The cell's
/// storage free is the runtime's responsibility for inline-header
/// types (handled inside the per-type `deep_walk` callback — see
/// the architecture note in this file's docstring).
///
/// `acq_rel` ordering on the decrement provides the release fence
/// that synchronises with prior retains on this cell so the deep-
/// walk and any subsequent storage free observe a consistent view
/// of the object.
///
/// Decrement via `+0xFFFFFFFF` (two's-complement of -1 in a u32):
/// `LDAXR` / `STLXR` operates on unsigned u32 lanes; adding `-1`
/// modulo 2^32 is the same wrap-around-add we'd get from a real
/// subtraction. The previous value comparison against 1 is then
/// identical to the `fetchSub` semantics in `std.atomic.Value(u32)`.
fn arcRelease(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    _ = ctx;
    const refcount_ptr: *u32 = @ptrCast(@alignCast(object));
    const prev = atomicAdd32AcqRel(refcount_ptr, @bitCast(@as(i32, -1)));
    if (prev == 1) {
        if (deep_walk) |walk| walk(object);
    }
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 capability tables
// ---------------------------------------------------------------------------

const refcount_vtable: ZapRefcountCapabilityV1 = .{
    .retain = arcRetain,
    .release = arcRelease,
};

const refcount_descriptor: ZapCapabilityDescV1 = .{
    .id = REFC_TAG,
    .version = 1,
    .size = @sizeOf(ZapRefcountCapabilityV1),
    .flags = 0,
    .vtable = @ptrCast(&refcount_vtable),
};

// ---------------------------------------------------------------------------
// `.zapmem` section emission (spec §3.2)
// ---------------------------------------------------------------------------

/// Composite section payload. The meta header and core vtable are
/// wrapped in a single `extern struct` so the linker emits them in
/// declaration order as one contiguous allocation. `meta.core_vtable_offset`
/// is derived from the struct layout via `@offsetOf`, so the section
/// is always self-consistent regardless of linker behaviour. This
/// example uses runtime-only capability discovery
/// (`desc_count = 0`); the runtime retrieves the refcount descriptor
/// via `get_capability_desc` at startup rather than embedding it in
/// the section. A manager that prefers embedded discovery would add
/// a `desc_0: ZapCapabilityDescV1` field after `core` and set
/// `desc_count = 1`.
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// The section payload. Exported so the linker does not dead-strip
/// it. The runtime discovers the payload via
/// `@extern(?*const ExternalMemorySectionPrefix, .{ .name =
/// "zap_memory_section", .linkage = .weak })` in `src/runtime.zig`.
/// Spec §3.2 + §10.5 codify the requirement; the driver enforces it
/// at build time (`assertExportsManagerSymbol` in
/// `src/memory/driver.zig`).
pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_REFCOUNT_V1_BIT,
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_REFCOUNT_V1_BIT,
        .init = arcInit,
        .deinit = arcDeinit,
        .allocate = arcAllocate,
        .deallocate = arcDeallocate,
        .get_capability_desc = arcGetCapabilityDesc,
    },
};
