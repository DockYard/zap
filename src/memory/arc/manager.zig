//! `Memory.ARC` — production atomic-refcount memory manager.
//!
//! Phase 4 + Phase 4.x of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` (sections 4, 5, 8, 10, 11.1 and 12) and
//! `docs/phase8-results.md` for the architectural context. This file is
//! the canonical first-party ARC implementation. It is compiled by the
//! Zig-fork primitive `zap_fork_compile_zig_to_object` into a standalone
//! object file that the Zap build pipeline links into every Zap binary
//! whose manifest selects `Memory.ARC` (the default).
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
//! `Memory.ARC` declares the `REFCOUNT_V1` capability and exposes
//! the `retain` / `release` vtable that the runtime's inline-header
//! types (`Map(K,V)`, `List(T)`, `MapIter`) dispatch through, plus the
//! extended `retain_sized` / `release_sized` slots that the runtime's
//! generic `Arc(T)` cells dispatch through.
//!
//! ### Inline-header cells (Map / List / MapIter)
//!
//! Each inline-header cell carries a 4-byte refcount at offset 0; the
//! manager's `retain(ctx, ptr)` performs an atomic increment on those
//! first 4 bytes, and the manager's `release(ctx, ptr, deep_walk)`
//! performs an atomic decrement and on the zero-transition invokes
//! `deep_walk(ptr)` — the runtime-supplied per-type walk callback that
//! both releases children AND frees the cell's variable-length backing
//! buffer (allocated by the runtime via `c_allocator`). The manager
//! never sees those c_allocator-backed buffers directly.
//!
//! ### Generic `Arc(T)` cells (side-table refcount)
//!
//! `Arc(T)` cells are allocated from a byte-keyed multi-class slab
//! pool inside this manager. The slab pool keys allocations by
//! `(size, alignment)` and partitions them into size classes ranging
//! from 16 bytes up to 4096 bytes. Each class owns a stable bank of
//! 64 KiB slabs; each slab carries a per-slot side-table refcount in
//! its header so the cell's slot bytes are 100% user payload (no
//! per-cell ArcHeader overhead, no alignment padding to host an
//! ArcHeader).
//!
//! Allocations larger than 4096 bytes fall back to `page_allocator`
//! (one `mmap` syscall per cell); each large allocation gets a
//! tagged header prefix so `retain_sized` / `release_sized` can
//! locate its refcount slot.
//!
//! The slab-pool refcount layout is the load-bearing optimization
//! that the binarytrees benchmark depends on: at ~8.4 M live cells
//! during N=21 stretch construction, the previous inline-header
//! shape paid `4 + 4 + 16 = 24` bytes per `Tree` (4-byte header +
//! 4-byte align pad + 16-byte value), totalling ~200 MB of RSS. The
//! side-table layout collapses that to `16 + 4 = 20` bytes per cell
//! (16-byte value + 4-byte side-table entry), totalling ~167 MB —
//! within the 170 MB budget recorded in `docs/phase8-results.md`.
//!
//! ### Why `page_allocator` (and not `c_allocator`) for slab backing
//!
//! The fork primitive `zap_fork_compile_zig_to_object` builds this
//! file with `link_libc = false` (see the Zig fork's `zir_api.zig`).
//! `c_allocator` is unavailable in that mode. `page_allocator` makes
//! a direct `mmap` syscall on POSIX and `NtAllocateVirtualMemory` on
//! Windows; neither depends on libc startup. The Arena / Leak /
//! Tracking managers follow the same pattern for the same reason.
//!
//! ### Vtable shape
//!
//! `ZapRefcountCapabilityV1` carries six function-pointer slots:
//!
//!   * `retain(ctx, ptr)` — inline-header path. Atomic increment on
//!     the 4-byte refcount at offset 0 of the cell.
//!   * `release(ctx, ptr, deep_walk)` — inline-header path. Atomic
//!     decrement; on the zero-transition the manager invokes
//!     `deep_walk` (which performs the cell's full teardown).
//!   * `retain_sized(ctx, ptr, size, alignment)` — side-table path.
//!     Locates the cell's slab via pointer masking, reads the size
//!     class from the slab header, atomic-increments the side-table
//!     refcount for the slot.
//!   * `release_sized(ctx, ptr, size, alignment, deep_walk)` —
//!     side-table path. Locates the cell's slab, atomic-decrements
//!     the side-table refcount; on the zero-transition invokes
//!     `deep_walk(ptr)` (children) and returns the slot to the slab.
//!   * `allocate_refcounted(ctx, size, alignment)` — side-table path.
//!     Allocates a slot from the appropriate size class, initialises
//!     the side-table refcount to 1, and returns the slot pointer.
//!   * `refcount_sized(ctx, ptr, size, alignment)` — side-table path.
//!     Reads the side-table refcount for the slot. Used by the
//!     runtime's `resetAny` / Perceus reuse path so a uniquely-owned
//!     cell can be reused in place rather than freed and reallocated.
//!
//! The vtable is forward-extensible: descriptor `size` advertises the
//! actual vtable length so a v1.0 runtime that knows only the first
//! two slots ignores the rest. The runtime in this codebase reads the
//! full extended vtable; future runtimes built against an even larger
//! capability surface read additional fields at the tail.
//!
//! Spec §13.3 mandates that user-visible objects originate from
//! `core.allocate` so tracking managers can observe every alloc/free
//! pair. This manager honours that contract for the side-table path:
//! `core.allocate` routes through the same size-class slab pool that
//! `allocate_refcounted` does (the only difference is that
//! `allocate_refcounted` initialises the side-table refcount to 1).
//! Inline-header buffers still come from the runtime's `c_allocator`
//! because those cells own variable-length payloads whose sizing is
//! a runtime-private concern; that arrangement is documented in
//! spec §13.3 as "type-specific bespoke storage" and is the
//! Phase 4 architectural carve-out.

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

/// REFCOUNT_V1 capability vtable. The first two slots are the original
/// v1.0 inline-header path (operate on a 4-byte refcount at offset 0
/// of the cell). The trailing four slots are the side-table path used
/// by generic `Arc(T)` cells — added in Phase 4.x to close the
/// Phase 4 vtable-bypass deferral. The descriptor's `size` field
/// advertises the actual vtable length so older v1.0 runtimes that
/// only read the first two slots continue to interoperate.
const ZapRefcountCapabilityV1 = extern struct {
    retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
    release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
    retain_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
    release_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
    allocate_refcounted: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
    refcount_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32,
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
    // Native pointer width. The vtable-bearing ABI structs carry
    // pointers, so their size/offset checks are RELATIVE to `PTR`
    // (mirroring `src/memory/abi.zig`'s `PTR`). On 64-bit targets
    // (`PTR == 8`) these reduce to the original 24/56/48-byte layout;
    // on wasm32 (`PTR == 4`) the descriptors are correctly smaller. The
    // wire-format `ZapMemoryManagerMetaV1` (all fixed-width ints) keeps
    // its literal 32-byte assert.
    const PTR: usize = @sizeOf(*const anyopaque);
    if (@sizeOf(ZapMemoryManagerMetaV1) != 32) @compileError(
        "arc: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "arc: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != std.mem.alignForward(usize, 12, PTR) + PTR) @compileError(
        "arc: ZapCapabilityDescV1 size must be its integer prefix plus one pointer",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != std.mem.alignForward(usize, 16 + 5 * PTR, @alignOf(ZapMemoryManagerCoreV1))) @compileError(
        "arc: ZapMemoryManagerCoreV1 size must be its 16-byte prefix plus five pointers (aligned)",
    );
    if (@sizeOf(ZapRefcountCapabilityV1) != 6 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1 (Phase 4.x extended) must be six pointer slots wide",
    );

    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16 + 0 * PTR) @compileError(
        "arc: ZapMemoryManagerCoreV1.init must follow the 16-byte prefix",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 16 + 1 * PTR) @compileError(
        "arc: ZapMemoryManagerCoreV1.deinit must be the second pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 16 + 2 * PTR) @compileError(
        "arc: ZapMemoryManagerCoreV1.allocate must be the third pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 16 + 3 * PTR) @compileError(
        "arc: ZapMemoryManagerCoreV1.deallocate must be the fourth pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 16 + 4 * PTR) @compileError(
        "arc: ZapMemoryManagerCoreV1.get_capability_desc must be the fifth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "retain") != 0 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.retain must be the first pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "release") != 1 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.release must be the second pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "retain_sized") != 2 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.retain_sized must be the third pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "release_sized") != 3 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.release_sized must be the fourth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "allocate_refcounted") != 4 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.allocate_refcounted must be the fifth pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "refcount_sized") != 5 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.refcount_sized must be the sixth pointer slot",
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
///
/// ARC's reclamation model is **Axis A == REFCOUNTED**. In the
/// capability-axis encoding (see `src/memory/abi.zig`) REFCOUNTED is signalled
/// by this `REFCOUNT_V1` flag with the Axis-A field (bits 1..2) held at its
/// `0b00` REFCOUNTED encoding — so ARC's full `declared_caps` is exactly
/// `0x1`, byte-identical to the pre-axes ABI. The Zap-side abi module's
/// `CAPS_REFCOUNTED` constant equals this value; this manager redeclares it
/// locally because the production-manager rule forbids importing sibling
/// compiler modules.
const CAP_REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

/// Object-format-conditional section name. Mach-O places the section
/// inside the `__DATA` segment; ELF and COFF use a top-level
/// `.zapmem` section (spec §3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    // WebAssembly custom sections are named directly (no segment
    // prefix); `linksection(".zapmem")` emits a `.zapmem` custom section
    // the driver's wasm object reader locates by name.
    .wasm => ".zapmem",
    else => @compileError("arc: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Size-class slab pool
//
// The slab pool partitions allocations into fixed size classes and
// allocates one slot per request from a 64-KiB-aligned slab keyed by
// the class. Each slab carries:
//
//   * A fixed header with the class index, magic, live count, free-list
//     head, bump-allocation index, and intrusive prev/next pointers for
//     a per-class partial-slab list.
//   * A side-table refcount array — one u32 per slot — that lets the
//     manager carry the cell's refcount outside the slot itself.
//   * The slot array proper, with each slot exactly `slot_size` bytes.
//
// Slab base alignment to 64 KiB (`SLAB_ALIGN`) lets `retain_sized` /
// `release_sized` recover the slab header from any slot pointer with a
// single AND, then read the class index to know `slot_size`, then
// compute the slot index by offset arithmetic.
//
// The pool is single-threaded today; Zap programs are single-threaded.
// A thread-safe version would protect each class's `current` / `partials`
// pointers with a per-class mutex and use `atomicRmw` on the side-table
// entries (which it already does — `acq_rel` on every retain/release).
// ---------------------------------------------------------------------------

/// Slab side (64 KiB) and alignment. The alignment must match the slab
/// size so any slot pointer's owning slab is `ptr & ~(SLAB_SIZE-1)`.
/// 64 KiB is a multiple of every supported page size (4 KiB on x86_64
/// Linux, 16 KiB on aarch64 macOS), so the over-aligned mmap helper
/// can trim the head and tail of an over-allocated region by integer
/// page counts.
const SLAB_SIZE: usize = 64 * 1024;
const SLAB_ALIGN: usize = SLAB_SIZE;
const SLAB_MASK: usize = SLAB_SIZE - 1;
const SLAB_BASE_MASK: usize = ~SLAB_MASK;
const NULL_SLOT: u32 = 0xFFFFFFFF;

/// Slab magic for the size-class slab pool. Stored in the slab header's
/// first 4 bytes so `release_sized` can refuse to operate on a pointer
/// that does not belong to a slab (defence in depth — codegen should
/// never emit such a call).
const SLAB_MAGIC: u32 = 0x5A4D5342; // "ZMSB" in little-endian: Zap Memory Slab Base.

/// Magic for the large-allocation header used when a request exceeds
/// the largest slab class. Each large allocation carries this 16-byte
/// preamble (magic + size + alignment + refcount); the user pointer
/// points past the preamble. `release_sized` finds the preamble by
/// pointer arithmetic; the magic byte sequence is checked before any
/// dereference of the trailing fields.
const LARGE_MAGIC: u32 = 0x5A4D4C47; // "ZMLG": Zap Memory LarGe.

/// Size classes for the slab pool. Modelled on the mimalloc / jemalloc
/// 1.5x progression, capped at 4096 bytes (one Linux page minus header).
/// Each class is the smallest slot size that fits the requested
/// allocation. Slot start within a slab is aligned to the class's
/// natural alignment (see `slotAlignForClass`); requests with a larger
/// alignment than the class's natural alignment promote to the next
/// class with sufficient alignment.
const SLAB_CLASS_SIZES = [_]u32{ 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096 };
const SLAB_CLASS_COUNT = SLAB_CLASS_SIZES.len;

/// Largest slot size served from the slab pool. Allocations above this
/// fall through to the large-allocation `page_allocator` path. Chosen
/// so a 4096-byte slot still leaves 64*1024 - 4096*1 = 61440 bytes
/// per slab — i.e., at most one slot per slab — so 4096 is a hard
/// ceiling for the slab class table.
const MAX_SLAB_CLASS_SIZE: u32 = SLAB_CLASS_SIZES[SLAB_CLASS_COUNT - 1];

/// Natural alignment of each class — comptime-built lookup table so
/// the hot path (`lookupClass` -> retain/release dispatch) reads one
/// u32 instead of running a 32-iteration loop per class probe.
const SLAB_CLASS_ALIGNS: [SLAB_CLASS_COUNT]u32 = blk: {
    var aligns: [SLAB_CLASS_COUNT]u32 = undefined;
    var class_index: u32 = 0;
    while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
        const size = SLAB_CLASS_SIZES[class_index];
        // Natural alignment is the largest power-of-two divisor of
        // `size`. For 16 -> 16, 24 -> 8, 32 -> 32, 48 -> 16, 64 -> 64,
        // 96 -> 32, 128 -> 128, 192 -> 64, 256 -> 256, 384 -> 128,
        // 512 -> 512, 768 -> 256, 1024 -> 1024, 1536 -> 512, 2048 -> 2048,
        // 3072 -> 1024, 4096 -> 4096.
        var align_val: u32 = 1;
        var bit: u32 = 0;
        while (bit < 32) : (bit += 1) {
            const probe: u32 = @as(u32, 1) << bit;
            if (probe > size) break;
            if (size % probe == 0) align_val = probe;
        }
        aligns[class_index] = align_val;
    }
    break :blk aligns;
};

inline fn slotAlignForClass(class_index: u32) u32 {
    return SLAB_CLASS_ALIGNS[class_index];
}

/// Comptime-built lookup table mapping a size to the smallest class
/// index whose `slot_size >= size`. The table is indexed by
/// `(size - 1) / 8` (so each entry covers 8 consecutive byte sizes),
/// which fits the largest slab class (4096 bytes) in 512 entries
/// (2 KiB of static data). The 8-byte granularity matches the
/// minimum alignment that v1.x guarantees (`@alignOf(usize) = 8` on
/// every supported target), so no entry is ever skipped.
///
/// The lookup collapses `lookupClass`'s former 17-iteration linear
/// scan to a single load + alignment-probe loop (alignment-induced
/// class escalation never crosses more than 2-3 classes in practice).
/// On binarytrees N=21 — which calls `lookupClass` ~600 M times — this
/// optimization shaves 5+ seconds of wall time off the runtime.
const SLAB_CLASS_LOOKUP_GRANULARITY: usize = 8;
const SLAB_CLASS_LOOKUP_TABLE_LEN: usize = (MAX_SLAB_CLASS_SIZE + SLAB_CLASS_LOOKUP_GRANULARITY - 1) / SLAB_CLASS_LOOKUP_GRANULARITY;
const SLAB_CLASS_LOOKUP_TABLE: [SLAB_CLASS_LOOKUP_TABLE_LEN]u32 = blk: {
    @setEvalBranchQuota(20000);
    var table: [SLAB_CLASS_LOOKUP_TABLE_LEN]u32 = undefined;
    var bucket: usize = 0;
    while (bucket < SLAB_CLASS_LOOKUP_TABLE_LEN) : (bucket += 1) {
        // Every size in `[bucket*8 + 1, (bucket+1)*8]` falls in this
        // bucket. The smallest class that can serve every size in the
        // bucket is the smallest class whose `slot_size >= (bucket+1)*8`.
        const upper_bound: u32 = @intCast((bucket + 1) * SLAB_CLASS_LOOKUP_GRANULARITY);
        var class_index: u32 = 0;
        while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
            if (SLAB_CLASS_SIZES[class_index] >= upper_bound) break;
        }
        table[bucket] = class_index;
    }
    break :blk table;
};

/// Find the smallest slab class whose slot size and natural alignment
/// can serve a request for `(size, alignment)`. Returns null when the
/// request is too large for the slab pool (caller must use the large-
/// allocation path). O(1) on the hot path: one table lookup to
/// resolve the size lower bound, then at most a few class probes to
/// satisfy alignment (the alignment promotion ladder is bounded by
/// the class table's 1.5×-per-step growth, so alignment-induced class
/// escalation never crosses more than 2-3 classes in practice).
inline fn lookupClass(size: usize, alignment: u32) ?u32 {
    if (size == 0 or size > MAX_SLAB_CLASS_SIZE) return null;
    const bucket: usize = (size - 1) / SLAB_CLASS_LOOKUP_GRANULARITY;
    var class_index: u32 = SLAB_CLASS_LOOKUP_TABLE[bucket];
    while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
        if (SLAB_CLASS_ALIGNS[class_index] >= alignment) return class_index;
    }
    return null;
}

/// First-party direct-call helper for runtime comptime specialization.
/// Returns the ARC slab class that serves `(size, alignment)`, or null
/// when the request must use the generic large-allocation path.
pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;
    return lookupClass(size, alignment);
}

inline fn validateSlabClassIndex(comptime class_index: u32) void {
    if (class_index >= SLAB_CLASS_COUNT) {
        @compileError("arc: slab class index out of range");
    }
}

/// Slab header. Lives at the start of every slab; the side-table
/// refcount array begins immediately after the header (4-byte aligned;
/// the header is already a multiple of 4 bytes), and the slot array
/// begins after the side table rounded up to the class's natural
/// alignment.
const SlabHeader = extern struct {
    /// `SLAB_MAGIC` (`0x5A4D5342`). Set by `slabInit` and never
    /// modified. Verified at the top of every `release_sized` / `retain_sized`
    /// call so a stray pointer cannot trigger a side-table dereference.
    magic: u32,

    /// Index into `SLAB_CLASS_SIZES`. Read by `release_sized` to
    /// recover `slot_size`, `slot_align`, and `capacity` without a
    /// runtime lookup table.
    class_index: u32,

    /// Number of currently-live slots in this slab. Decremented by
    /// `release_sized` on the zero-transition; when this drops to zero
    /// and the slab is NOT the class's `current`, the slab is either
    /// cached as the class's lone `cached_empty` (for hot reuse) or
    /// returned to `page_allocator`.
    live_count: u32,

    /// Free-list head (slot index). `NULL_SLOT` when the free list is
    /// empty (allocations come from bump-allocation in that case until
    /// the slab fills).
    free_list_head: u32,

    /// Bump-allocation cursor. Slot indices `< bump_index` have been
    /// handed out at least once; new allocations either pop from the
    /// free list or bump-allocate at `bump_index` (when `bump_index <
    /// capacity`).
    bump_index: u32,

    /// Total slot count in this slab. Computed by `slabInit` from the
    /// class size and the slab's payload bytes.
    capacity: u32,

    /// Intrusive prev/next pointers for the class's partial-slab list.
    /// Null on both ends when the slab is not on the list (i.e., when
    /// it is `current`, full, or in `cached_empty`).
    prev: ?*SlabHeader,
    next: ?*SlabHeader,

    /// Slab base pointer (== `@ptrCast(self)`). Cached here so the
    /// munmap path can return the aligned page region without recomputing
    /// the mask. The cast assert (`@intFromPtr(self) == @intFromPtr(allocation_base)`)
    /// catches a layout error early in debug builds.
    allocation_base: [*]align(std.heap.page_size_min) u8,

    /// Slab's owning class (`*SizeClass`). Stored here so `release_sized`
    /// can return the slot to its class's free list with one indirect
    /// load. Cross-thread frees in a future concurrent model would walk
    /// `owner` to route the free back to the originating heap.
    owner: *anyopaque,
};

/// Per-size-class state. Each class owns its own bank of slabs; the
/// `current` slab is the most-recently-used allocation target (slot
/// bumps come from here first), the `partials` list holds slabs with
/// both live cells AND free slots (a freed slot in a previously-full
/// slab pushes it to the front), and `cached_empty` holds at most one
/// fully-empty slab to absorb mmap thrash from hot/cold oscillation.
const SizeClass = extern struct {
    /// The active slab — allocations pop from this slab's free list
    /// first, then bump-allocate. Switched out only when full (rotated
    /// to the partial list) or when zero-live in `release_sized` (held
    /// in `cached_empty`).
    current: ?*SlabHeader,

    /// Head of an intrusive doubly-linked list of slabs with both live
    /// cells AND free slots. Slabs migrate full→partial on `release_sized`
    /// and partial→current on `acquireSlab` (no allocator call). Empty
    /// slabs leave the partial list (either to `cached_empty` or back
    /// to the OS via `unmapSlab`).
    partials: ?*SlabHeader,

    /// At most one fully-empty slab is held for fast reuse. Workloads
    /// that oscillate around exactly one slab's working set avoid
    /// mmap/munmap thrash entirely; larger working sets that exceed
    /// this cache pay the syscall cost.
    cached_empty: ?*SlabHeader,
};

/// Compute the byte offset to the slot array's first slot inside a
/// slab. Derived from the header size + the side-table refcount array
/// size, rounded up to the class's natural alignment.
inline fn slotsOffsetForClass(class_index: u32, capacity: u32) usize {
    const refcount_bytes: usize = @as(usize, capacity) * @sizeOf(u32);
    const header_end: usize = @sizeOf(SlabHeader) + refcount_bytes;
    const align_v: usize = slotAlignForClass(class_index);
    return std.mem.alignForward(usize, header_end, align_v);
}

/// Compute the maximum slot count for a class. Solves the closed-form
/// inequality:
///   slotsOffset(capacity) + capacity * slot_size <= SLAB_SIZE
/// where slotsOffset(capacity) = alignUp(sizeOf(SlabHeader) +
///                                       capacity * sizeOf(u32),
///                                       slot_align).
inline fn capacityForClass(class_index: u32) u32 {
    const slot_size: usize = SLAB_CLASS_SIZES[class_index];
    const slot_align: usize = slotAlignForClass(class_index);
    // Each slot adds 4 bytes (side-table) + slot_size (slot proper).
    // The slot start is bumped up to `slot_align` from the side-table
    // end. Bound the alignment pad above by `slot_align - 1` to get
    // a conservative lower bound on capacity that's at most 1 slot
    // off from the true maximum.
    if (SLAB_SIZE <= @sizeOf(SlabHeader) + slot_align) return 0;
    const usable: usize = SLAB_SIZE - @sizeOf(SlabHeader) - slot_align;
    const per_slot: usize = slot_size + @sizeOf(u32);
    return @intCast(usable / per_slot);
}

/// Slab management context. Each manager carries this in its
/// `Context` struct. The slab pool is single-threaded — Zap programs
/// are single-threaded today.
const SlabPool = struct {
    classes: [SLAB_CLASS_COUNT]SizeClass,
};

inline fn slabPoolInit() SlabPool {
    var pool: SlabPool = undefined;
    var class_index: u32 = 0;
    while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
        pool.classes[class_index] = .{
            .current = null,
            .partials = null,
            .cached_empty = null,
        };
    }
    return pool;
}

/// Acquire a 64-KiB-aligned `SLAB_SIZE` region. Delegates to
/// `page_allocator`, which honours over-page alignment requests on every
/// supported OS (POSIX over-allocates and trims; Windows reserves a
/// placeholder, splits it, and commits the aligned sub-range). This is
/// the same libc-free virtual-memory primitive the large-allocation path
/// uses (`largeAlloc`) and is the primitive the module header documents
/// for slab backing — `mmap` on POSIX, `NtAllocateVirtualMemory` on
/// Windows. Returns the aligned base pointer or null on OOM.
///
/// `page_allocator` returns a region whose address is already
/// `SLAB_ALIGN`-aligned, so no manual head/tail trim is needed (and no
/// raw `std.posix.mmap`, which does not exist on Windows). The returned
/// pointer doubles as the allocation base recorded in
/// `SlabHeader.allocation_base`; `unmapSlab` frees exactly this region.
fn mmapAlignedSlab() ?[*]align(std.heap.page_size_min) u8 {
    const page_size = std.heap.page_size_min;
    // SLAB_SIZE must be a multiple of the OS page size so the
    // page-granular allocator returns exactly `SLAB_SIZE` usable bytes.
    std.debug.assert(SLAB_SIZE % page_size == 0);

    // `SLAB_ALIGN` (64 KiB) exceeds every supported page size, so the
    // alignment is the load-bearing request; clamp to at least the page
    // size for the degenerate case where a future page size meets or
    // exceeds `SLAB_ALIGN`.
    const slab_alignment: std.mem.Alignment =
        .fromByteUnits(@max(SLAB_ALIGN, @as(usize, page_size)));
    const base = std.heap.page_allocator.rawAlloc(
        SLAB_SIZE,
        slab_alignment,
        @returnAddress(),
    ) orelse return null;

    return @alignCast(base);
}

/// Counterpart to `mmapAlignedSlab`: release a `SLAB_SIZE`-aligned
/// `SLAB_SIZE` region back to `page_allocator` (POSIX `munmap` /
/// Windows `NtFreeVirtualMemory`).
fn unmapSlab(base: [*]align(std.heap.page_size_min) u8) void {
    const page_size = std.heap.page_size_min;
    const slab_alignment: std.mem.Alignment =
        .fromByteUnits(@max(SLAB_ALIGN, @as(usize, page_size)));
    std.heap.page_allocator.rawFree(base[0..SLAB_SIZE], slab_alignment, @returnAddress());
}

/// Initialise a freshly-mmapped slab. Sets the header and zero-fills
/// the side-table refcount array so newly bump-allocated slots see rc=0
/// before the allocator writes the rc=1 starter value.
fn slabInit(slab: *SlabHeader, class_index: u32, owner: *anyopaque, base: [*]align(std.heap.page_size_min) u8) void {
    const capacity = capacityForClass(class_index);
    slab.* = .{
        .magic = SLAB_MAGIC,
        .class_index = class_index,
        .live_count = 0,
        .free_list_head = NULL_SLOT,
        .bump_index = 0,
        .capacity = capacity,
        .prev = null,
        .next = null,
        .allocation_base = base,
        .owner = owner,
    };
    // Zero-fill the side-table array. The capacity is at most a few
    // thousand u32 entries; @memset is the most portable way to clear
    // them without per-slot loops.
    const refcount_ptr_byte: [*]u8 = @ptrCast(slab);
    const refcount_bytes_ptr = refcount_ptr_byte + @sizeOf(SlabHeader);
    const refcount_bytes_count: usize = @as(usize, capacity) * @sizeOf(u32);
    @memset(refcount_bytes_ptr[0..refcount_bytes_count], 0);
}

/// Pointer to the side-table refcount entry for slot `index` in `slab`.
inline fn slabRefcountPtr(slab: *SlabHeader, index: u32) *u32 {
    const base: [*]u8 = @ptrCast(slab);
    const table: [*]u32 = @ptrCast(@alignCast(base + @sizeOf(SlabHeader)));
    return &table[index];
}

/// Pointer to slot `index` in `slab`. Slots start at
/// `slotsOffsetForClass(class_index, capacity)` and are spaced by
/// `slot_size` bytes.
inline fn slabSlotPtr(slab: *SlabHeader, index: u32) [*]u8 {
    const base: [*]u8 = @ptrCast(slab);
    const offset = slotsOffsetForClass(slab.class_index, slab.capacity);
    const slot_size: usize = SLAB_CLASS_SIZES[slab.class_index];
    return base + offset + slot_size * @as(usize, index);
}

/// Convert a slot pointer back to its (slab, slot_index) pair. Caller
/// must have verified that `ptr` is slab-allocated (e.g., by checking
/// the size class).
inline fn slabFromSlotPtr(ptr: *anyopaque) *SlabHeader {
    const ptr_addr = @intFromPtr(ptr);
    const slab_addr = ptr_addr & SLAB_BASE_MASK;
    const slab: *SlabHeader = @ptrFromInt(slab_addr);
    return slab;
}

inline fn slotIndexInSlab(slab: *SlabHeader, ptr: *anyopaque) u32 {
    const base_addr = @intFromPtr(slab);
    const ptr_addr = @intFromPtr(ptr);
    const offset = ptr_addr - base_addr - slotsOffsetForClass(slab.class_index, slab.capacity);
    const slot_size: usize = SLAB_CLASS_SIZES[slab.class_index];
    return @intCast(offset / slot_size);
}

/// Link `slab` to the head of `class`'s partial-slab list.
fn pushPartial(class: *SizeClass, slab: *SlabHeader) void {
    slab.prev = null;
    slab.next = class.partials;
    if (class.partials) |head| {
        head.prev = slab;
    }
    class.partials = slab;
}

/// Remove `slab` from the partial-slab list (no-op when the slab is
/// not currently on the list).
fn unlinkPartial(class: *SizeClass, slab: *SlabHeader) void {
    if (slab.prev) |prev_slab| {
        prev_slab.next = slab.next;
    } else if (class.partials == slab) {
        class.partials = slab.next;
    }
    if (slab.next) |next_slab| {
        next_slab.prev = slab.prev;
    }
    slab.prev = null;
    slab.next = null;
}

inline fn slabOnPartialList(class: *SizeClass, slab: *SlabHeader) bool {
    return slab.prev != null or class.partials == slab;
}

/// Acquire a slab for `class` to make active. Pulls from the cached-
/// empty slot if present, then the partial list, then mmaps fresh.
/// Returns null on OOM.
fn acquireSlab(pool: *SlabPool, class_index: u32) ?*SlabHeader {
    const class = &pool.classes[class_index];

    if (class.cached_empty) |cached| {
        class.cached_empty = null;
        // Reset bump cursor — the cached slab's live_count was 0 when
        // it was cached; re-bump from zero on reuse so the side-table
        // contents (which were zeroed at init and may have been
        // mutated since) are written fresh by `allocate_refcounted`.
        cached.live_count = 0;
        cached.free_list_head = NULL_SLOT;
        cached.bump_index = 0;
        cached.prev = null;
        cached.next = null;
        // Re-zero the side-table — a previously-used slab has dirty
        // refcount entries from prior allocations.
        const ref_ptr_byte: [*]u8 = @ptrCast(cached);
        const refcount_bytes_ptr = ref_ptr_byte + @sizeOf(SlabHeader);
        const refcount_bytes_count: usize = @as(usize, cached.capacity) * @sizeOf(u32);
        @memset(refcount_bytes_ptr[0..refcount_bytes_count], 0);
        return cached;
    }

    if (class.partials) |partial| {
        unlinkPartial(class, partial);
        return partial;
    }

    const aligned_base = mmapAlignedSlab() orelse return null;
    const slab: *SlabHeader = @ptrCast(@alignCast(aligned_base));
    slabInit(slab, class_index, @ptrCast(class), aligned_base);
    return slab;
}

/// Allocate a slot from `class`. Caller has guaranteed the slot will
/// satisfy the original `(size, alignment)` pair via `lookupClass`.
/// Returns null on OOM (mmap failure).
fn slabAllocSlot(pool: *SlabPool, class_index: u32, init_refcount: u32) ?[*]u8 {
    const class = &pool.classes[class_index];
    var slab: *SlabHeader = class.current orelse blk: {
        const acquired = acquireSlab(pool, class_index) orelse return null;
        class.current = acquired;
        break :blk acquired;
    };

    while (true) {
        if (slab.free_list_head != NULL_SLOT) {
            const slot_index = slab.free_list_head;
            const slot_bytes = slabSlotPtr(slab, slot_index);
            const free_node: *u32 = @ptrCast(@alignCast(slot_bytes));
            slab.free_list_head = free_node.*;
            slab.live_count += 1;
            slabRefcountPtr(slab, slot_index).* = init_refcount;
            return slot_bytes;
        }
        if (slab.bump_index < slab.capacity) {
            const slot_index = slab.bump_index;
            slab.bump_index += 1;
            slab.live_count += 1;
            const slot_bytes = slabSlotPtr(slab, slot_index);
            slabRefcountPtr(slab, slot_index).* = init_refcount;
            return slot_bytes;
        }
        // Active slab is full. Rotate to a fresh slab.
        class.current = null;
        const fresh = acquireSlab(pool, class_index) orelse return null;
        class.current = fresh;
        slab = fresh;
    }
}

/// Return a slot to its slab. Decrements the live count; on the zero-
/// transition either caches or unmaps the slab when it is not the
/// class's `current`.
fn slabFreeSlot(pool: *SlabPool, slab: *SlabHeader, slot_index: u32) void {
    const class: *SizeClass = @ptrCast(@alignCast(slab.owner));
    _ = pool;

    const was_full = slab.free_list_head == NULL_SLOT and slab.bump_index >= slab.capacity;
    const slot_bytes = slabSlotPtr(slab, slot_index);
    const free_node: *u32 = @ptrCast(@alignCast(slot_bytes));
    free_node.* = slab.free_list_head;
    slab.free_list_head = slot_index;
    std.debug.assert(slab.live_count > 0);
    slab.live_count -= 1;
    // Reset the side-table refcount so the slot's next allocation
    // begins from a known-zero baseline (the allocator overwrites it
    // anyway, but a zeroed entry is friendlier for any future
    // diagnostic that walks the side table for debugging).
    slabRefcountPtr(slab, slot_index).* = 0;

    if (slab == class.current) return;

    if (slab.live_count == 0) {
        // Drain the slab from the partial list if it was on it; then
        // either cache it or unmap.
        if (slabOnPartialList(class, slab)) {
            unlinkPartial(class, slab);
        }
        if (class.cached_empty == null) {
            class.cached_empty = slab;
        } else {
            unmapSlab(slab.allocation_base);
        }
        return;
    }

    if (was_full) {
        // Slab just transitioned full → partial; push it onto the
        // partial list so future allocations can pick it up.
        pushPartial(class, slab);
    }
}

// ---------------------------------------------------------------------------
// Large allocations (above the slab pool's largest class)
//
// Requests for `size > MAX_SLAB_CLASS_SIZE` bypass the slab pool and
// go directly to `page_allocator`. Each large allocation carries a
// 16-byte preamble immediately before the user pointer:
//
//   [ LargeHeader (magic, padding, size, alignment, refcount, padding) ]
//   [ user payload                                                     ]
//
// The header's size is fixed at exactly the requested alignment (with
// a minimum of 16 bytes, the size of the header struct) so the user
// pointer remains aligned. `release_sized` finds the header by walking
// backward from the user pointer.
// ---------------------------------------------------------------------------

const LargeHeader = extern struct {
    magic: u32,
    _pad0: u32,
    size: usize,
    alignment: u32,
    refcount: u32,
};

comptime {
    // Internal large-allocation header (not a cross-tooling ABI type),
    // so the assert is pointer-width relative: a `u32` magic + `u32`
    // pad, then a `usize` size, then `u32` alignment + `u32` refcount —
    // `16 + @sizeOf(usize)` bytes (24 on 64-bit, 20 on wasm32).
    if (@sizeOf(LargeHeader) != 16 + @sizeOf(usize)) @compileError(
        "arc: LargeHeader must be its two u32 prefix + usize + two u32 trailer",
    );
}

/// Return the byte offset from the user pointer back to the `LargeHeader`.
/// The header is placed at `user_ptr - leading`, where `leading` is the
/// larger of `sizeOf(LargeHeader)` and the requested alignment (rounded
/// up to the page allocator's alignment guarantees).
inline fn largeLeadingFor(alignment: u32) usize {
    const min_lead: usize = @sizeOf(LargeHeader);
    const aligned_lead: usize = std.mem.alignForward(usize, min_lead, alignment);
    return aligned_lead;
}

fn largeAlloc(size: usize, alignment: u32, init_refcount: u32) ?[*]u8 {
    const leading = largeLeadingFor(alignment);
    const total = std.math.add(usize, leading, size) catch return null;
    const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(alignment, @as(u32, @intCast(std.heap.page_size_min))));
    const base = std.heap.page_allocator.rawAlloc(total, inner_alignment, @returnAddress()) orelse return null;
    const header_ptr: *LargeHeader = @ptrCast(@alignCast(base + leading - @sizeOf(LargeHeader)));
    header_ptr.* = .{
        .magic = LARGE_MAGIC,
        ._pad0 = 0,
        .size = size,
        .alignment = alignment,
        .refcount = init_refcount,
    };
    return base + leading;
}

fn largeFree(ptr: [*]u8) void {
    const header_ptr: *LargeHeader = @ptrCast(@alignCast(ptr - @sizeOf(LargeHeader)));
    // Magic mismatch is fatal corruption — the pointer either does
    // not belong to this manager or its header was overwritten.
    // Continuing would `munmap` an arbitrary memory range and bring
    // down the process with a SEGV at the next access. Panic loudly
    // even in release builds so the diagnostic surfaces with the
    // failing pointer rather than as a downstream memory corruption.
    if (header_ptr.magic != LARGE_MAGIC) @panic("zap.arc: largeFree: corrupt LargeHeader magic (pointer not owned by this manager or double-free)");
    const alignment = header_ptr.alignment;
    const leading = largeLeadingFor(alignment);
    const total = leading + header_ptr.size;
    const base: [*]u8 = ptr - leading;
    const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(alignment, @as(u32, @intCast(std.heap.page_size_min))));
    std.heap.page_allocator.rawFree(base[0..total], inner_alignment, @returnAddress());
}

inline fn largeHeader(ptr: *anyopaque) *LargeHeader {
    const byte_ptr: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(byte_ptr - @sizeOf(LargeHeader)));
}

// ---------------------------------------------------------------------------
// Manager context.
//
// The ARC manager holds a `SlabPool` for the lifetime of the process.
// The context is allocated through `page_allocator` during `init` and
// freed during `deinit`.
// ---------------------------------------------------------------------------

const ArcContext = struct {
    slab_pool: SlabPool,
};

// ---------------------------------------------------------------------------
// Atomic helpers
//
// Earlier Phase 4 builds of this manager externalised every atomic
// increment to `zap_runtime_atomic_add_u32_acq_rel` (defined in
// `src/runtime.zig`) as a workaround for the self-hosted aarch64
// backend's missing `atomic_rmw` lowering. The prebuilt
// `libzap_compiler.a` ships with LLVM enabled (`build_options.have_llvm
// = true` — verified by the `llvm-libs/` directory in `zap-deps/`),
// so the fork primitive `zap_fork_compile_zig_to_object` lowers
// `@atomicRmw` directly to native `LDAXR` / `STLXR` (aarch64) or
// `LOCK XADD` (x86_64). The externalised helper is no longer
// necessary and added ~3 ns per retain/release through an extra
// C-ABI call hop. This file now emits the atomic op inline.
//
// Ordering policy (spec §8.2): retains use `.monotonic` (relaxed) —
// the spec mandates only that the count be atomic, and a retain has
// no prior writeback to publish (it's a pure ownership-share
// operation). Releases use `.acq_rel` so the final decrement that
// observes the zero-transition synchronises with every prior
// retain/release on the same cell, ensuring the deep-walk and free
// see a consistent view of the object. Same convention as the C++
// `std::shared_ptr` implementation.
// ---------------------------------------------------------------------------

inline fn atomicAddU32(ptr: *u32, delta: u32, comptime ordering: std.builtin.AtomicOrder) u32 {
    return @atomicRmw(u32, ptr, .Add, delta, ordering);
}

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Allocates a `ArcContext` on `page_allocator`
/// (the only allocator available in the fork primitive's freestanding-
/// ish compile environment) and returns its address as the manager
/// context per spec §4.2.
fn arcInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const ctx = std.heap.page_allocator.create(ArcContext) catch return null;
    ctx.* = .{ .slab_pool = slabPoolInit() };
    return @ptrCast(ctx);
}

/// Deinitialise the manager. Walks every class's slab list and
/// returns each slab to the OS. Frees the context struct last.
///
/// Spec §4.4 makes `deinit` best-effort. The slab pool's eager
/// unmap-on-zero-live policy keeps the deinit-time slab count small
/// in well-behaved programs; the loop below handles the residual
/// (cached-empty + current + partial slabs of every class).
fn arcDeinit(ctx: *anyopaque) callconv(.c) void {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    var class_index: u32 = 0;
    while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
        const class = &arc_ctx.slab_pool.classes[class_index];
        if (class.current) |slab| {
            unmapSlab(slab.allocation_base);
            class.current = null;
        }
        while (class.partials) |slab| {
            class.partials = slab.next;
            unmapSlab(slab.allocation_base);
        }
        if (class.cached_empty) |slab| {
            unmapSlab(slab.allocation_base);
            class.cached_empty = null;
        }
    }
    std.heap.page_allocator.destroy(arc_ctx);
}

/// Raw allocation slot — `core.allocate` (spec §4.2). Routes through
/// the size-class slab pool for sizes ≤ `MAX_SLAB_CLASS_SIZE`, falls
/// through to the large-allocation `page_allocator` path for larger
/// requests. The returned pointer is the slot's first byte (no
/// per-cell header); the side-table refcount is left at 0 because
/// the caller is using the raw allocation path (non-refcounted).
fn arcAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return null;
    if (lookupClass(size, alignment)) |class_index| {
        return slabAllocSlot(&arc_ctx.slab_pool, class_index, 0);
    }
    return largeAlloc(size, alignment, 0);
}

/// Raw deallocation slot — `core.deallocate` (spec §4.2). For slab-
/// backed allocations, returns the slot to its class's free list. For
/// large allocations, unmaps the underlying region.
fn arcDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return;
    if (lookupClass(size, alignment)) |class_index| {
        const slab = slabFromSlotPtr(ptr);
        std.debug.assert(slab.magic == SLAB_MAGIC);
        std.debug.assert(slab.class_index == class_index);
        const slot_index = slotIndexInSlab(slab, ptr);
        slabFreeSlot(&arc_ctx.slab_pool, slab, slot_index);
        return;
    }
    largeFree(ptr);
}

/// REFCOUNT_V1 `allocate_refcounted` (Phase 4.x extension). Same as
/// `core.allocate` except the side-table refcount is initialised to 1
/// so the caller observes a fully-owned cell on return.
fn arcAllocateRefcounted(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return null;
    if (lookupClass(size, alignment)) |class_index| {
        return slabAllocSlot(&arc_ctx.slab_pool, class_index, 1);
    }
    return largeAlloc(size, alignment, 1);
}

/// First-party direct-call allocation helper for generic `Arc(T)` cells
/// whose `(size, alignment)` pair maps to a slab class at comptime.
pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    validateSlabClassIndex(class_index);
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    return slabAllocSlot(&arc_ctx.slab_pool, class_index, 1);
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

/// REFCOUNT_V1 `retain` (spec §8). Atomic increment on the 4-byte
/// refcount at offset 0 of an inline-header cell. Used by Map/List/
/// MapIter. `.monotonic` ordering — see the ordering policy comment
/// above `atomicAddU32`.
fn arcRetain(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    const refcount_ptr: *u32 = @ptrCast(@alignCast(object));
    _ = atomicAddU32(refcount_ptr, 1, .monotonic);
}

/// REFCOUNT_V1 `release` (spec §8). Atomic decrement on the inline
/// header; on the zero-transition invokes `deep_walk(object)` (which
/// performs the cell's full teardown for inline-header types).
/// `.acq_rel` ordering so the zero-observing decrement synchronises
/// with every prior retain/release.
fn arcRelease(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    _ = ctx;
    const refcount_ptr: *u32 = @ptrCast(@alignCast(object));
    const prev = atomicAddU32(refcount_ptr, @bitCast(@as(i32, -1)), .acq_rel);
    std.debug.assert(prev > 0);
    if (prev == 1) {
        if (deep_walk) |walk| walk(object);
    }
}

/// REFCOUNT_V1 `retain_sized` (Phase 4.x extension). Locates the cell's
/// slab via pointer masking, reads the size class from the slab header,
/// and atomic-increments the side-table refcount for the slot. Large
/// allocations (size > MAX_SLAB_CLASS_SIZE) use the trailing 4-byte
/// refcount in the cell's `LargeHeader`.
fn arcRetainSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    // Defensive parameter validation. `alignment` must be a power of
    // two per spec §4.2 (matches `core.allocate`'s contract). A zero-
    // size cell is meaningless — a soundness bug in the dispatcher
    // would route here with size == 0; return cleanly rather than
    // index a class that doesn't exist.
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return;
    if (lookupClass(size, alignment)) |class_index| {
        retainSlabClass(object, class_index);
        return;
    }
    const header = largeHeader(object);
    if (header.magic != LARGE_MAGIC) @panic("zap.arc: retain_sized large path: corrupt LargeHeader magic");
    _ = atomicAddU32(&header.refcount, 1, .monotonic);
}

inline fn retainSlabClass(object: *anyopaque, class_index: u32) void {
    const slab = slabFromSlotPtr(object);
    std.debug.assert(slab.magic == SLAB_MAGIC);
    // Cross-check that the (size, alignment) the caller passed
    // matches the slab the pointer actually lives in. A mismatch
    // means the caller computed `size` from the wrong type — a
    // soundness violation. Catch it in debug builds where the
    // bug is cheapest to diagnose; release builds elide the
    // assert and trust the caller's `(size, alignment)` pair.
    std.debug.assert(slab.class_index == class_index);
    const slot_index = slotIndexInSlab(slab, object);
    const refcount_ptr = slabRefcountPtr(slab, slot_index);
    _ = atomicAddU32(refcount_ptr, 1, .monotonic);
}

/// First-party direct-call retain helper for generic `Arc(T)` cells
/// whose `(size, alignment)` pair maps to a slab class at comptime.
pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    validateSlabClassIndex(class_index);
    retainSlabClass(object, class_index);
}

/// REFCOUNT_V1 `release_sized` (Phase 4.x extension). Locates the
/// cell's slab via pointer masking, atomic-decrements the side-table
/// refcount; on the zero-transition invokes `deep_walk(object)`
/// (children walk) and returns the slot to the slab's free list.
fn arcReleaseSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    // Mirror the `retain_sized` parameter validation. Zero-size
    // release is a no-op (mirrors the no-op zero-size alloc).
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return;
    if (lookupClass(size, alignment)) |class_index| {
        releaseSlabClass(&arc_ctx.slab_pool, object, class_index, deep_walk);
        return;
    }
    const header = largeHeader(object);
    // Magic mismatch on a large allocation is a fatal corruption: the
    // caller's pointer either doesn't belong to this manager or was
    // already freed and the header was overwritten. Continuing would
    // free arbitrary memory. Panic even in release builds.
    if (header.magic != LARGE_MAGIC) @panic("zap.arc: release_sized large path: corrupt LargeHeader magic");
    const prev = atomicAddU32(&header.refcount, @bitCast(@as(i32, -1)), .acq_rel);
    std.debug.assert(prev > 0);
    if (prev == 1) {
        if (deep_walk) |walk| walk(object);
        const byte_ptr: [*]u8 = @ptrCast(object);
        largeFree(byte_ptr);
    }
}

inline fn releaseSlabClass(
    slab_pool: *SlabPool,
    object: *anyopaque,
    class_index: u32,
    deep_walk: ?ZapDeepWalkFn,
) void {
    const slab = slabFromSlotPtr(object);
    std.debug.assert(slab.magic == SLAB_MAGIC);
    std.debug.assert(slab.class_index == class_index);
    const slot_index = slotIndexInSlab(slab, object);
    const refcount_ptr = slabRefcountPtr(slab, slot_index);
    const prev = atomicAddU32(refcount_ptr, @bitCast(@as(i32, -1)), .acq_rel);
    // Spec §8.2: a release that drops to zero is the sole owner.
    // A prev == 0 result means the caller released a cell with
    // rc=0 already — a double-release. Catch in debug.
    std.debug.assert(prev > 0);
    if (prev == 1) {
        // Children walk runs BEFORE the slot returns to the free
        // list — `deep_walk` may dereference fields of the cell to
        // recursively release children, and the side-table layout
        // guarantees the slot's bytes are still valid at this point.
        if (deep_walk) |walk| walk(object);
        slabFreeSlot(slab_pool, slab, slot_index);
    }
}

/// First-party direct-call release helper for generic `Arc(T)` cells
/// whose `(size, alignment)` pair maps to a slab class at comptime.
pub inline fn releaseSizedClass(
    ctx: *anyopaque,
    object: *anyopaque,
    comptime class_index: u32,
    deep_walk: ?ZapDeepWalkFn,
) void {
    validateSlabClassIndex(class_index);
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    releaseSlabClass(&arc_ctx.slab_pool, object, class_index, deep_walk);
}

/// REFCOUNT_V1 `refcount_sized` (Phase 4.x extension). Reads the
/// side-table refcount for the slot at `object`. Used by the runtime's
/// `resetAny` / Perceus reuse path so a uniquely-owned Arc(T) cell can
/// be reused in place rather than freed and reallocated. Single-load
/// `.acquire` semantics — the read pairs with prior retains so the
/// observed count is up to date with the value the caller would see
/// after their own `retain`.
fn arcRefcountSized(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    if (size == 0) return 0;
    if (lookupClass(size, alignment)) |class_index| {
        return refcountSlabClass(object, class_index);
    }
    const header = largeHeader(object);
    if (header.magic != LARGE_MAGIC) @panic("zap.arc: refcount_sized large path: corrupt LargeHeader magic");
    return @atomicLoad(u32, &header.refcount, .acquire);
}

inline fn refcountSlabClass(object: *anyopaque, class_index: u32) u32 {
    const slab = slabFromSlotPtr(object);
    std.debug.assert(slab.magic == SLAB_MAGIC);
    std.debug.assert(slab.class_index == class_index);
    const slot_index = slotIndexInSlab(slab, object);
    const refcount_ptr = slabRefcountPtr(slab, slot_index);
    return @atomicLoad(u32, refcount_ptr, .acquire);
}

/// First-party direct-call refcount helper for generic `Arc(T)` cells
/// whose `(size, alignment)` pair maps to a slab class at comptime.
pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    validateSlabClassIndex(class_index);
    return refcountSlabClass(object, class_index);
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 capability tables
// ---------------------------------------------------------------------------

const refcount_vtable: ZapRefcountCapabilityV1 = .{
    .retain = arcRetain,
    .release = arcRelease,
    .retain_sized = arcRetainSized,
    .release_sized = arcReleaseSized,
    .allocate_refcounted = arcAllocateRefcounted,
    .refcount_sized = arcRefcountSized,
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

const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// The section payload. Exported so the linker does not dead-strip it.
///
/// `abi_minor = 1` because this manager exposes the v1.1 extended
/// `ZapRefcountCapabilityV1` vtable (6 slots / 48 bytes — see spec
/// section 8). A consumer that only knows v1.0 reads the vtable's
/// `desc.size = 48` and ignores the trailing four slots per spec
/// section 2.3.
pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 1,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_REFCOUNT_V1_BIT,
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 1,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_REFCOUNT_V1_BIT,
        .init = arcInit,
        .deinit = arcDeinit,
        .allocate = arcAllocate,
        .deallocate = arcDeallocate,
        .get_capability_desc = arcGetCapabilityDesc,
    },
};

// ---------------------------------------------------------------------------
// Uniform first-party manager interface (Phase 4)
//
// Phase 4's comptime dispatch in `src/runtime.zig` calls into the active
// first-party manager through `@import("zap_active_manager")` rather than
// through the vtable, so LLVM can inline the manager's hot paths across
// the module boundary. The dispatch path requires every first-party
// manager to expose the SAME set of `pub` names — listed below — so the
// runtime's `active_manager.<fn>(...)` call sites compile against a
// uniform shape regardless of which manager the build resolved to.
//
// The aliases below are not redundant with the vtable's function-pointer
// fields: the vtable still routes third-party managers and the runtime's
// fallback path. These aliases give the runtime a direct symbol to call,
// without an indirect load through `core.allocate`/`cap.retain_sized`/...
// — which is the exact construct LLVM needs to inline through.
//
// ARC implements the REFCOUNT_V1 capability fully, so every alias below
// resolves to a real function. Managers that do not declare REFCOUNT_V1
// (Arena, NoOp, Leak, Tracking) expose the same interface but stub the
// refcount entries with panicking bodies — codegen elides those call
// sites under no-REFCOUNT_V1 builds, so the stubs are never invoked in
// practice.
// ---------------------------------------------------------------------------

pub const init = arcInit;
pub const deinit = arcDeinit;
pub const allocate = arcAllocate;
pub const deallocate = arcDeallocate;
pub const allocateRefcounted = arcAllocateRefcounted;
pub const retain = arcRetain;
pub const release = arcRelease;
pub const retainSized = arcRetainSized;
pub const releaseSized = arcReleaseSized;
pub const refcountSized = arcRefcountSized;
pub const getCapabilityDesc = arcGetCapabilityDesc;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock
//
// The uniform-interface aliases declared above must match the canonical
// AbiV1 slot types so the runtime's comptime dispatch (in `runtime.zig`'s
// host stub OR a user-binary build that selects `Memory.ARC`) sees
// the right calling shape. ARC declares REFCOUNT_V1, so every ABI slot
// alias plus every first-party class-specialized helper MUST resolve to
// real implementations with matching signatures; a drift between the
// alias arrow and the underlying impl (e.g. an extra parameter, a typo'd
// return type) would surface at user-binary link time rather than here.
// Pinning each alias against its canonical slot type at module scope
// catches that drift at the host build site instead.
comptime {
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

test "ARC refcount slab class helper maps small Tree-like payloads" {
    try std.testing.expectEqual(@as(?u32, 0), refcountSlabClassIndex(16, 8));
}

test "ARC refcount slab class helper rejects generic-path requests" {
    try std.testing.expectEqual(@as(?u32, null), refcountSlabClassIndex(0, 8));
    try std.testing.expectEqual(@as(?u32, null), refcountSlabClassIndex(4097, 8));
    try std.testing.expectEqual(@as(?u32, null), refcountSlabClassIndex(16, 8192));
}

test "ARC class-specialized helpers interoperate with generic sized refcount slots" {
    const ctx = init(null) orelse return error.OutOfMemory;
    defer deinit(ctx);

    const Payload = extern struct {
        left: ?*const anyopaque,
        right: ?*const anyopaque,
    };
    const class_index = comptime refcountSlabClassIndex(@sizeOf(Payload), @alignOf(Payload)).?;
    const slot_bytes = allocateRefcountedClass(ctx, class_index) orelse return error.OutOfMemory;
    const slot_ptr: *Payload = @ptrCast(@alignCast(slot_bytes));
    slot_ptr.* = .{ .left = null, .right = null };

    try std.testing.expectEqual(@as(u32, 1), refcountSized(ctx, slot_ptr, @sizeOf(Payload), @alignOf(Payload)));

    retainSizedClass(ctx, slot_ptr, class_index);
    try std.testing.expectEqual(@as(u32, 2), refcountSized(ctx, slot_ptr, @sizeOf(Payload), @alignOf(Payload)));

    releaseSizedClass(ctx, slot_ptr, class_index, null);
    try std.testing.expectEqual(@as(u32, 1), refcountSizedClass(ctx, slot_ptr, class_index));

    releaseSized(ctx, slot_ptr, @sizeOf(Payload), @alignOf(Payload), null);
}
