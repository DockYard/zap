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
    // v1.2 relocate extension (slots 6–7; the same-model O(1) region-move send,
    // plan item 6.1 / P3-J5). `desc.size` advertises their presence per spec
    // §2.3, so a consumer that predates them reads the smaller size and ignores
    // the tail (falling back to the copy send).
    detach_region: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) bool,
    adopt_region: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
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
    if (@sizeOf(ZapRefcountCapabilityV1) != 8 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1 (v1.2 relocate-extended) must be eight pointer slots wide",
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
    if (@offsetOf(ZapRefcountCapabilityV1, "detach_region") != 6 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.detach_region must be the seventh pointer slot",
    );
    if (@offsetOf(ZapRefcountCapabilityV1, "adopt_region") != 7 * PTR) @compileError(
        "arc: ZapRefcountCapabilityV1.adopt_region must be the eighth pointer slot",
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
    /// retained on the class's bounded empty-slab cache (for hot
    /// reuse) or returned to `page_allocator`.
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
    /// Null on both ends when the slab is not on any list (i.e., when
    /// it is `current` or full). The class's empty-slab cache reuses
    /// `next` alone as its singly-linked stack link (`prev` stays null
    /// while a slab is cached).
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

/// Fraction divisor and absolute bounds for the per-class empty-slab
/// cache cap (see `emptyCacheCap`). The cap is
///
///   clamp(live_slab_peak / EMPTY_CACHE_PEAK_DIVISOR,
///         EMPTY_CACHE_RETAIN_FLOOR, EMPTY_CACHE_RETAIN_CEILING)
///
/// * `EMPTY_CACHE_PEAK_DIVISOR = 2` — retain at most half the class's
///   historical live-slab peak. Idle retention is therefore bounded by
///   half of what the workload itself demonstrably demanded, while an
///   oscillation whose amplitude is any fraction up to half of peak is
///   absorbed entirely (binarytrees N=21: peak ≈ 2560 class-0 slabs
///   during the stretch tree, per-band teardown amplitude ≤ ~650 slabs
///   — comfortably inside peak/2 ≈ 1280).
/// * `EMPTY_CACHE_RETAIN_FLOOR = 2` — small working sets whose peak/2
///   rounds to 0 or 1 may still retain two empties (128 KiB per class),
///   covering the tiniest oscillations. The floor can never push mapped
///   memory past the peak: the cache only ever receives slabs that were
///   just live, so `live + cached <= peak` holds regardless (see the
///   invariant note on `emptyCacheCap`).
/// * `EMPTY_CACHE_RETAIN_CEILING = 1024` — bounds worst-case idle
///   retention at 64 MiB per class (1024 × 64 KiB) for programs whose
///   live peak was enormous in an early phase but that later shrink
///   permanently. Large enough that benchmark-scale oscillations
///   (tens of MiB per class) are still fully absorbed.
const EMPTY_CACHE_PEAK_DIVISOR: u32 = 2;
const EMPTY_CACHE_RETAIN_FLOOR: u32 = 2;
const EMPTY_CACHE_RETAIN_CEILING: u32 = 1024;

/// Per-size-class state. Each class owns its own bank of slabs; the
/// `current` slab is the most-recently-used allocation target (slot
/// bumps come from here first), the `partials` list holds slabs with
/// both live cells AND free slots (a freed slot in a previously-full
/// slab pushes it to the front), and the `empty_head` stack retains a
/// bounded number of fully-empty slabs to absorb mmap/munmap thrash
/// from hot/cold oscillation.
///
/// ## Empty-slab cache policy (history and rationale)
///
/// The cache began life as a single `cached_empty` slot: workloads that
/// oscillated around exactly one slab's working set avoided syscall
/// thrash, but larger oscillations (binarytrees N=21 tears down and
/// rebuilds hundreds of slabs per band) still paid an mmap + munmap +
/// page-fault-zeroing round trip per slab per cycle — ~18% of profile
/// samples. The slot was therefore generalized into a bounded LIFO
/// stack whose cap derives from the class's live-slab high-watermark
/// (`live_slab_peak`, see `emptyCacheCap`).
///
/// The watermark is tracked PER CLASS, not globally, because the pool
/// itself is keyed per class: slabs are class-typed (slot geometry and
/// capacity are functions of `class_index`) and never migrate between
/// classes, so a global watermark would let one class's peak justify
/// retaining empties in a class that never demonstrated that demand.
/// The per-class bound `live + cached <= peak` sums to the same bound
/// globally, which keeps the no-RSS-regression argument structural.
const SizeClass = extern struct {
    /// The active slab — allocations pop from this slab's free list
    /// first, then bump-allocate. Switched out only when full (rotated
    /// to the partial list) or when zero-live in `release_sized` (moved
    /// to the empty-slab cache).
    current: ?*SlabHeader,

    /// Head of an intrusive doubly-linked list of slabs with both live
    /// cells AND free slots. Slabs migrate full→partial on `release_sized`
    /// and partial→current on `acquireSlab` (no allocator call). Empty
    /// slabs leave the partial list (either to the empty-slab cache or
    /// back to the OS via `unmapSlab`).
    partials: ?*SlabHeader,

    /// LIFO stack of fully-empty slabs retained for reuse, singly
    /// linked through `SlabHeader.next` (`prev` stays null). LIFO order
    /// keeps the hottest — most recently touched, most likely still
    /// resident — slab on top. Bounded by `emptyCacheCap`; excess
    /// empties unmap immediately, exactly as every empty slab did
    /// under the single-slot design.
    empty_head: ?*SlabHeader,

    /// Number of slabs on the `empty_head` stack. Compared against
    /// `emptyCacheCap` on every slab-empty transition.
    empty_count: u32,

    /// Number of mapped slabs currently in service (current + partial
    /// + full floaters) — i.e., every slab owned by this class that is
    /// NOT on the empty stack. Incremented when a slab enters service
    /// (fresh mmap or reuse from the empty stack), decremented when a
    /// slab empties out of service.
    live_slab_count: u32,

    /// High-watermark of `live_slab_count` — the most slabs this class
    /// ever had simultaneously in service. The empty-cache cap derives
    /// from this so cached empties can only exist strictly below a
    /// live-slab level the process already reached while the slabs
    /// held payload: peak RSS is set by live demand, never by caching.
    live_slab_peak: u32,
};

/// Maximum number of empty slabs `class` may retain, derived from its
/// live-slab high-watermark (see the constant block above for the
/// clamp rationale).
///
/// Structural invariant — mapped slabs never exceed the live peak:
/// `acquireSlab` reuses a cached empty before it ever maps a fresh
/// slab, so a fresh mmap only happens while `empty_count == 0` (mapped
/// total == live count <= peak after the watermark update), and an
/// empty transition merely moves a slab from live to cached (mapped
/// total unchanged) or unmaps it (mapped total shrinks). Therefore
/// `live_slab_count + empty_count <= live_slab_peak` at all times, no
/// matter what this function returns — the cap only tunes how much of
/// that already-reached headroom is retained versus returned to the OS.
inline fn emptyCacheCap(class: *const SizeClass) u32 {
    const peak_fraction = class.live_slab_peak / EMPTY_CACHE_PEAK_DIVISOR;
    return @min(@max(peak_fraction, EMPTY_CACHE_RETAIN_FLOOR), EMPTY_CACHE_RETAIN_CEILING);
}

/// Record that a slab entered service (fresh mmap or reuse from the
/// empty stack): bump the live count and advance the high-watermark.
inline fn noteSlabEnteredService(class: *SizeClass) void {
    class.live_slab_count += 1;
    if (class.live_slab_count > class.live_slab_peak) {
        class.live_slab_peak = class.live_slab_count;
    }
}

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
            .empty_head = null,
            .empty_count = 0,
            .live_slab_count = 0,
            .live_slab_peak = 0,
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
/// Test-only slab map/unmap accounting. The in-file empty-slab-cache
/// tests use these totals for an accounting-based leak check (every
/// mapped slab — cached empties included — must be unmapped by
/// `deinit`) and to prove cache reuse maps no fresh slab. The
/// increments below compile away entirely outside `zig build test`
/// (`builtin.is_test` is comptime-false in production manager objects).
/// `pub` so the cross-thread ARC stress test (`arc_cross_thread_stress.zig`)
/// can baseline/verify slab mapping traffic for leak-exactness; incremented
/// atomically (below) so concurrent per-thread contexts do not race the
/// instrumentation. Production (`!is_test`) never touches them.
pub var test_slab_mmap_total: usize = 0;
pub var test_slab_unmap_total: usize = 0;

/// Test-only counters for LARGE (page_allocator-backed) allocations —
/// mirror `test_slab_*`, letting the P3-J1 per-process wholesale-free test
/// assert every large cell is reclaimed at `arcDeinit` (allocs == frees).
/// Compile away outside `zig build test`.
pub var test_large_alloc_total: usize = 0;
pub var test_large_free_total: usize = 0;

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

    if (builtin.is_test) _ = @atomicRmw(usize, &test_slab_mmap_total, .Add, 1, .monotonic);
    return @alignCast(base);
}

/// Counterpart to `mmapAlignedSlab`: release a `SLAB_SIZE`-aligned
/// `SLAB_SIZE` region back to `page_allocator` (POSIX `munmap` /
/// Windows `NtFreeVirtualMemory`).
fn unmapSlab(base: [*]align(std.heap.page_size_min) u8) void {
    const page_size = std.heap.page_size_min;
    const slab_alignment: std.mem.Alignment =
        .fromByteUnits(@max(SLAB_ALIGN, @as(usize, page_size)));
    if (builtin.is_test) _ = @atomicRmw(usize, &test_slab_unmap_total, .Add, 1, .monotonic);
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

/// Debug-only invariant check: an empty slab's side-table refcount
/// array is all-zero. `slabFreeSlot` zeroes each entry as the slot is
/// freed and `slabInit` zeroed every entry past the bump cursor, so a
/// slab whose `live_count` reached zero holds no non-zero entry — the
/// load-bearing fact that lets `acquireSlab` reuse a cached empty slab
/// without re-memsetting the side table.
fn verifyEmptySlabSideTableZeroed(slab: *SlabHeader) void {
    var slot_index: u32 = 0;
    while (slot_index < slab.capacity) : (slot_index += 1) {
        std.debug.assert(slabRefcountPtr(slab, slot_index).* == 0);
    }
}

/// Acquire a slab for `class` to make active. Pulls from the empty-
/// slab cache if non-empty, then the partial list, then mmaps fresh —
/// strictly in that order, which is what makes the mapped-slabs-
/// never-exceed-live-peak invariant structural (see `emptyCacheCap`).
/// Returns null on OOM.
///
/// ## Reuse re-initializes metadata only
///
/// A slab reused from the empty cache does NOT get the fresh-mmap
/// zero-page guarantee back, and deliberately does not emulate it:
///
/// * Header allocation state (`live_count`, `free_list_head`,
///   `bump_index`, list links) is re-initialized explicitly below.
///   The identity fields (`magic`, `class_index`, `capacity`,
///   `allocation_base`, `owner`) survive from the original `slabInit`
///   unchanged — a cached slab never changes class.
/// * The side-table refcount array is already all-zero: `slabFreeSlot`
///   zeroes each entry on free, and entries past the bump cursor were
///   zeroed by `slabInit` and never handed out, so an empty slab holds
///   no stale count (verified in safety-checked builds below). This is
///   exactly the state `slabInit`'s memset establishes on a fresh
///   mapping.
/// * Slot payload bytes are left dirty. The allocation contract never
///   promised zeroed payload — free-list recycling inside a live slab
///   already returns dirty slots — so no caller may depend on it.
///
/// Skipping the wholesale re-zero is where the old oscillation cost
/// went: a fresh mmap pays the kernel zero-page fault for all 64 KiB
/// on first touch, while reuse touches only the header.
fn acquireSlab(pool: *SlabPool, class_index: u32) ?*SlabHeader {
    const class = &pool.classes[class_index];

    if (class.empty_head) |cached| {
        class.empty_head = cached.next;
        std.debug.assert(class.empty_count > 0);
        class.empty_count -= 1;
        noteSlabEnteredService(class);
        cached.live_count = 0;
        cached.free_list_head = NULL_SLOT;
        cached.bump_index = 0;
        cached.prev = null;
        cached.next = null;
        if (std.debug.runtime_safety) verifyEmptySlabSideTableZeroed(cached);
        return cached;
    }

    if (class.partials) |partial| {
        unlinkPartial(class, partial);
        return partial;
    }

    const aligned_base = mmapAlignedSlab() orelse return null;
    const slab: *SlabHeader = @ptrCast(@alignCast(aligned_base));
    slabInit(slab, class_index, @ptrCast(class), aligned_base);
    noteSlabEnteredService(class);
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
    // Reset the side-table refcount. This zeroing is LOAD-BEARING for
    // the empty-slab cache: because every freed slot's entry returns
    // to zero here (and entries past the bump cursor were zeroed by
    // `slabInit`), a slab that empties out carries an all-zero side
    // table, which is what lets `acquireSlab` reuse a cached empty
    // slab with a metadata-only re-init instead of a side-table memset.
    slabRefcountPtr(slab, slot_index).* = 0;

    if (slab == class.current) return;

    if (slab.live_count == 0) {
        // Drain the slab from the partial list if it was on it; the
        // slab is leaving service either way.
        if (slabOnPartialList(class, slab)) {
            unlinkPartial(class, slab);
        }
        std.debug.assert(class.live_slab_count > 0);
        class.live_slab_count -= 1;
        // Retain the empty slab for reuse while the cache is below its
        // watermark-derived cap; past the cap, excess empties unmap
        // immediately — the exact pre-cache behaviour.
        if (class.empty_count < emptyCacheCap(class)) {
            slab.prev = null;
            slab.next = class.empty_head;
            class.empty_head = slab;
            class.empty_count += 1;
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
    /// Intrusive links in the OWNING CONTEXT's large-allocation list
    /// (P3-J1). Large allocations (> `MAX_SLAB_CLASS_SIZE`) bypass the slab
    /// pool and go straight to `page_allocator`, so the per-process wholesale
    /// free (`arcDeinit`) would leak every one of them unless it can walk
    /// them — this list is that walk. A cleanly-exiting process unlinks each
    /// large cell as its refcount hits zero (`largeFree`); a killed process's
    /// still-live large cells are reclaimed by `arcDeinit` walking `large_head`.
    /// Owner-only, mutated on alloc/free within the owning process's quantum
    /// (no atomics — same single-owner discipline as the slab pool).
    prev: ?*LargeHeader,
    next: ?*LargeHeader,
};

comptime {
    // Internal large-allocation header (not a cross-tooling ABI type),
    // so the assert is pointer-width relative: a `u32` magic + `u32`
    // pad, then a `usize` size, then `u32` alignment + `u32` refcount,
    // then two intrusive `?*LargeHeader` list links — `16 + @sizeOf(usize)
    // + 2 * @sizeOf(pointer)` bytes (40 on 64-bit, 28 on wasm32).
    if (@sizeOf(LargeHeader) != 16 + @sizeOf(usize) + 2 * @sizeOf(?*LargeHeader)) @compileError(
        "arc: LargeHeader must be its two u32 prefix + usize + two u32 + two list-link pointers",
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

fn largeAlloc(arc_ctx: *ArcContext, size: usize, alignment: u32, init_refcount: u32) ?[*]u8 {
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
        // Link at the head of the owning context's large-allocation list so
        // `arcDeinit` can wholesale-free it (P3-J1 leak-exactness).
        .prev = null,
        .next = arc_ctx.large_head,
    };
    if (arc_ctx.large_head) |old_head| old_head.prev = header_ptr;
    arc_ctx.large_head = header_ptr;
    if (builtin.is_test) _ = @atomicRmw(usize, &test_large_alloc_total, .Add, 1, .monotonic);
    return base + leading;
}

/// Return a large allocation's backing page to the OS. Assumes `header_ptr`
/// has already been validated (`magic == LARGE_MAGIC`) and unlinked from any
/// context list. Shared by the individual-free path (`largeFree`) and the
/// wholesale per-process teardown (`arcDeinit`).
fn largeFreePage(header_ptr: *LargeHeader) void {
    const alignment = header_ptr.alignment;
    const leading = largeLeadingFor(alignment);
    const total = leading + header_ptr.size;
    // The allocation base sits `leading` bytes before the user pointer, which
    // is `@sizeOf(LargeHeader)` bytes past the header.
    const base: [*]u8 = @ptrFromInt(@intFromPtr(header_ptr) + @sizeOf(LargeHeader) - leading);
    const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(alignment, @as(u32, @intCast(std.heap.page_size_min))));
    std.heap.page_allocator.rawFree(base[0..total], inner_alignment, @returnAddress());
    if (builtin.is_test) _ = @atomicRmw(usize, &test_large_free_total, .Add, 1, .monotonic);
}

fn largeFree(arc_ctx: *ArcContext, ptr: [*]u8) void {
    const header_ptr: *LargeHeader = @ptrCast(@alignCast(ptr - @sizeOf(LargeHeader)));
    // Magic mismatch is fatal corruption — the pointer either does
    // not belong to this manager or its header was overwritten.
    // Continuing would `munmap` an arbitrary memory range and bring
    // down the process with a SEGV at the next access. Panic loudly
    // even in release builds so the diagnostic surfaces with the
    // failing pointer rather than as a downstream memory corruption.
    if (header_ptr.magic != LARGE_MAGIC) @panic("zap.arc: largeFree: corrupt LargeHeader magic (pointer not owned by this manager or double-free)");
    // Unlink from the owning context's large-allocation list before freeing.
    if (header_ptr.prev) |prev| {
        prev.next = header_ptr.next;
    } else {
        arc_ctx.large_head = header_ptr.next;
    }
    if (header_ptr.next) |next| next.prev = header_ptr.prev;
    largeFreePage(header_ptr);
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
    /// Head of the intrusive list of this context's LIVE large allocations
    /// (> `MAX_SLAB_CLASS_SIZE`, `page_allocator`-backed, outside the slab
    /// pool). `arcDeinit` walks it to wholesale-free them — the per-process
    /// leak-exactness contract (P3-J1): a killed process's live large cells
    /// are bulk-reclaimed here, not leaked.
    large_head: ?*LargeHeader = null,
};

// ---------------------------------------------------------------------------
// Region relocation — the same-model O(1) region-move send (plan item 6.1,
// P3-J5). `Memory.ARC` is REFCOUNTED, so a message value proven uniquely
// owned (rc == 1) and region-closed by the compiler's region-closure verifier
// can be transferred to a same-model receiver WITHOUT copying its bytes: the
// sender detaches the backing block from its own heap, the block travels by
// pointer through the neutral envelope, and the receiver adopts it into its
// own heap. No refcount is touched cross-thread (rc == 1 means the mover holds
// the sole reference; only the receiver touches it post-move — the sacred
// scheduler-local-refcount invariant holds by construction).
//
// ## The R4 constraint this confronts (honest)
//
// Under the concurrency gate a `List`/`String` container buffer is routed
// through this manager's `allocate` (P3-J1), landing in one of two disciplines:
//
//   * SLAB-backed (≤ `MAX_SLAB_CLASS_SIZE`): the buffer is one slot interleaved
//     with UNRELATED cells in a shared 64 KiB slab whose free-list/partial-list
//     bookkeeping is per-context. Re-parenting a single slot to another
//     context is NOT possible without dragging its co-tenants (and would race
//     the sender's own slab mutation). `detachRegion` returns `false` for these
//     — the caller MUST fall back to the copy send. Small buffers copy cheaply,
//     so this degradation is on the cheap side of the E6 crossover.
//
//   * LARGE (> `MAX_SLAB_CLASS_SIZE`): a standalone `page_allocator` (mmap)
//     block, tracked ONLY by intrusive membership in the owning context's
//     `large_head` list (`LargeHeader.prev/next`); `munmap` is process-global.
//     Such a block CAN be re-parented in O(1): unlink from the sender's
//     `large_head`, relink into the receiver's. This is the sound O(1) subset —
//     the mechanism that eliminates the E6 reconstruct cost for large payloads.
//
// Both operations touch ONLY a per-context `large_head` and the block's own
// `LargeHeader`, each mutated exclusively within the owning process's quantum
// (no atomics — the same single-owner discipline as `largeAlloc`/`largeFree`).
// ---------------------------------------------------------------------------

/// Detach a container buffer previously returned by `arcAllocate` from THIS
/// context's ownership so a same-model receiver can adopt it without copying
/// (sender side of the O(1) region-move send). Returns `true` when the buffer
/// was a LARGE (`page_allocator`-backed) allocation and is now an orphaned,
/// independently-`munmap`-freeable block owned by neither context — safe to
/// hand to another process's `adoptRegion`. Returns `false` when the buffer is
/// SLAB-backed (the R4 degradation): the caller must copy instead. O(1): a
/// single intrusive-list unlink, scheduler-local, refcount untouched.
fn arcDetachRegion(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) bool {
    // Mirror `arcAllocate`'s EXACT slab-vs-large decision: a request that maps
    // to a slab class is slab-backed and not relocatable per-cell.
    if (lookupClass(size, alignment) != null) return false;
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    const byte_ptr: [*]u8 = @ptrCast(object);
    const header_ptr: *LargeHeader = @ptrCast(@alignCast(byte_ptr - @sizeOf(LargeHeader)));
    // Corruption is fatal — the pointer is not a large allocation of this
    // manager (mismatched size, double-detach, or memory corruption).
    if (header_ptr.magic != LARGE_MAGIC) @panic("zap.arc: detachRegion: corrupt LargeHeader magic (pointer not a large allocation of this manager)");
    // Unlink from the owning context's large-allocation list so the sender's
    // teardown (`arcDeinit`) no longer reclaims it — the receiver owns it now.
    if (header_ptr.prev) |prev| {
        prev.next = header_ptr.next;
    } else {
        arc_ctx.large_head = header_ptr.next;
    }
    if (header_ptr.next) |next| next.prev = header_ptr.prev;
    // Mark orphaned (in-flight, owned by neither context).
    header_ptr.prev = null;
    header_ptr.next = null;
    return true;
}

/// Adopt a detached LARGE buffer (from another same-model context's
/// `detachRegion`) into THIS context's ownership, so THIS context's teardown
/// (`arcDeinit`) and the buffer's eventual individual free (`largeFree`)
/// reclaim it correctly (receiver side of the O(1) region-move send). The
/// buffer's own refcount is untouched (it remains the sole reference the mover
/// proved unique). O(1): a single intrusive-list link, scheduler-local.
/// `size`/`alignment` must match the original request (asserts large-path).
fn arcAdoptRegion(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    // Adopt is large-path only — the caller only detaches large buffers.
    std.debug.assert(lookupClass(size, alignment) == null);
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    const byte_ptr: [*]u8 = @ptrCast(object);
    const header_ptr: *LargeHeader = @ptrCast(@alignCast(byte_ptr - @sizeOf(LargeHeader)));
    if (header_ptr.magic != LARGE_MAGIC) @panic("zap.arc: adoptRegion: corrupt LargeHeader magic (pointer not a detached large allocation)");
    // Link at the head of the adopting context's large-allocation list.
    header_ptr.prev = null;
    header_ptr.next = arc_ctx.large_head;
    if (arc_ctx.large_head) |old_head| old_head.prev = header_ptr;
    arc_ctx.large_head = header_ptr;
}

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
/// Spec §4.4 makes `deinit` best-effort. The slab pool's bounded
/// unmap-on-zero-live policy keeps the deinit-time slab count modest
/// in well-behaved programs; the loop below handles the residual
/// (current + partial + every cached empty slab of every class).
fn arcDeinit(ctx: *anyopaque) callconv(.c) void {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    // Wholesale-free every LIVE large allocation (P3-J1 leak-exactness):
    // large cells (> MAX_SLAB_CLASS_SIZE) bypass the slab pool and would
    // otherwise leak on a killed process's teardown. Walk the intrusive list
    // and return each backing page to the OS.
    while (arc_ctx.large_head) |header_ptr| {
        arc_ctx.large_head = header_ptr.next;
        std.debug.assert(header_ptr.magic == LARGE_MAGIC);
        largeFreePage(header_ptr);
    }
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
        while (class.empty_head) |slab| {
            class.empty_head = slab.next;
            unmapSlab(slab.allocation_base);
        }
        class.empty_count = 0;
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
    return largeAlloc(arc_ctx, size, alignment, 0);
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
    largeFree(arc_ctx, ptr);
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
    return largeAlloc(arc_ctx, size, alignment, 1);
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
        largeFree(arc_ctx, byte_ptr);
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
    .detach_region = arcDetachRegion,
    .adopt_region = arcAdoptRegion,
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

/// The section payload. Kept `pub` so the Phase-4 source-registered
/// dispatch path (`runtime.zig`'s `bindSourceActiveManager`) can read it
/// directly as `active_manager.zap_memory_section`, and `@export`ed (below)
/// in non-test builds so the linker symbol the weak-extern/driver path
/// discovers is present and not dead-stripped.
///
/// `abi_minor = 1` because this manager exposes the v1.1 extended
/// `ZapRefcountCapabilityV1` vtable (6 slots / 48 bytes — see spec
/// section 8). A consumer that only knows v1.0 reads the vtable's
/// `desc.size = 48` and ignores the trailing four slots per spec
/// section 2.3.
pub const zap_memory_section: ZapMemorySection = .{
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

// Emit the mandatory `zap_memory_section` LINKER SYMBOL only when this manager
// is compiled as a STANDALONE OBJECT (`builtin.output_mode == .Obj`). (The
// `pub const` above always stays visible as a Zig decl — see below — so this
// gates ONLY the exported symbol, not the value.)
//
// `zap_memory_section` is the manager's `.zapmem` payload (spec §3.2). It is
// read through the linker symbol in exactly two places, BOTH of which compile
// the manager as a standalone `.Obj`:
//   1. The build driver's validation object (`zap_fork_compile_zig_to_object`,
//      which emits an object) — the driver parses `.zapmem` from it and its
//      post-link check (`assertExportsManagerSymbol`) enforces the symbol's
//      presence.
//   2. An object-linked host that links a pre-compiled manager `.o` and binds
//      it through `runtime.zig`'s weak `externalMemorySection` extern.
//
// In a COMPILER-DRIVEN binary (`.Exe`/`.Lib`) the manager is instead registered
// as a sibling SOURCE MODULE (`zap_active_manager`, or a per-spawn
// `zap_spawn_manager_<index>`; docs/memory-manager-abi.md §10.5) and the runtime
// binds it through that module's DECL — `@import("...").zap_memory_section` —
// NOT the linker symbol (`RUNTIME_ACTIVE_MANAGER_SOURCE_DEFAULT` is rewritten to
// true for every user binary, so the weak-extern path is dead there). Gating
// emission on `.Obj` is therefore what lets N managers coexist as sibling
// modules in ONE binary (per-spawn managers) — each keeps its own `pub const`
// storage while NONE emits the colliding `zap_memory_section` symbol. It also
// subsumes the old `!builtin.is_test` gate: a `zig build test` binary is an
// `.Exe`, so no manager exports the symbol into the aggregated test binary.
//
// `.linkage = .weak` is retained as defence-in-depth for the object-linked
// shape: it keeps two independently-compiled manager `.o`s (each an `.Obj`
// export) from hard-colliding if both are ever linked. `.section` reproduces
// the prior `linksection(SECTION_NAME)` byte-for-byte.
comptime {
    if (builtin.output_mode == .Obj) {
        @export(&zap_memory_section, .{ .name = "zap_memory_section", .section = SECTION_NAME, .linkage = .weak });
    }
}

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
pub const detachRegion = arcDetachRegion;
pub const adoptRegion = arcAdoptRegion;
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
    const DetachRegionFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) bool;
    const AdoptRegionFn = *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void;
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
    _ = @as(DetachRegionFn, detachRegion);
    _ = @as(AdoptRegionFn, adoptRegion);
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

// ---------------------------------------------------------------------------
// Empty-slab cache tests
//
// These tests exercise the bounded empty-slab cache through the public
// allocate/deallocate surface and verify its internal accounting through
// the in-file `ArcContext` view. They use the largest slab class
// (4096-byte slots) so a slab fills after only a handful of allocations
// and multi-slab scenarios stay small and fast.
// ---------------------------------------------------------------------------

/// Slab class used by the empty-slab cache tests: the 4096-byte class
/// has the smallest per-slab capacity, keeping multi-slab workloads to
/// a few dozen allocations.
const test_empty_cache_class_index: u32 = lookupClass(4096, 8).?;
const test_empty_cache_slab_capacity: u32 = capacityForClass(test_empty_cache_class_index);

fn testEmptyCacheClass(ctx: *anyopaque) *SizeClass {
    const arc_ctx: *ArcContext = @ptrCast(@alignCast(ctx));
    return &arc_ctx.slab_pool.classes[test_empty_cache_class_index];
}

fn testAllocEmptyCacheSlot(ctx: *anyopaque) ![*]u8 {
    return allocate(ctx, 4096, 8) orelse error.OutOfMemory;
}

fn testFreeEmptyCacheSlot(ctx: *anyopaque, slot: [*]u8) void {
    deallocate(ctx, slot, 4096, 8);
}

test "ARC empty-slab cache: live-slab watermark rises on growth and falls on teardown" {
    const ctx = init(null) orelse return error.OutOfMemory;
    defer deinit(ctx);
    const class = testEmptyCacheClass(ctx);

    const slab_capacity = test_empty_cache_slab_capacity;
    var slots: [2 * test_empty_cache_slab_capacity][*]u8 = undefined;

    // Fill one slab plus one slot of a second slab: two live slabs.
    for (&slots) |*slot| slot.* = try testAllocEmptyCacheSlot(ctx);
    try std.testing.expectEqual(@as(u32, 2), class.live_slab_count);
    try std.testing.expectEqual(@as(u32, 2), class.live_slab_peak);
    try std.testing.expectEqual(@as(u32, 0), class.empty_count);

    // Free the first slab's slots: it empties and moves live -> cached,
    // so the live count falls while the watermark holds.
    for (slots[0..slab_capacity]) |slot| testFreeEmptyCacheSlot(ctx, slot);
    try std.testing.expectEqual(@as(u32, 1), class.live_slab_count);
    try std.testing.expectEqual(@as(u32, 2), class.live_slab_peak);
    try std.testing.expectEqual(@as(u32, 1), class.empty_count);

    // Rebuild the working set: the cached slab returns to service, so
    // the live count rises WITHOUT raising the watermark (reuse is not
    // new peak demand).
    for (slots[0..slab_capacity]) |*slot| slot.* = try testAllocEmptyCacheSlot(ctx);
    try std.testing.expectEqual(@as(u32, 2), class.live_slab_count);
    try std.testing.expectEqual(@as(u32, 2), class.live_slab_peak);
    try std.testing.expectEqual(@as(u32, 0), class.empty_count);

    for (&slots) |slot| testFreeEmptyCacheSlot(ctx, slot);
}

test "ARC empty-slab cache: cache is bounded by the watermark cap and excess slabs unmap" {
    const ctx = init(null) orelse return error.OutOfMemory;
    defer deinit(ctx);
    const class = testEmptyCacheClass(ctx);

    const slab_count = 8;
    var slots: [slab_count * test_empty_cache_slab_capacity][*]u8 = undefined;
    for (&slots) |*slot| slot.* = try testAllocEmptyCacheSlot(ctx);
    try std.testing.expectEqual(@as(u32, slab_count), class.live_slab_count);
    try std.testing.expectEqual(@as(u32, slab_count), class.live_slab_peak);

    // Free everything. Seven non-current slabs empty out; the cap
    // (peak/2 = 4) retains four of them and the excess three unmap.
    // The eighth slab stays `current` and is never cached.
    for (&slots) |slot| testFreeEmptyCacheSlot(ctx, slot);
    try std.testing.expectEqual(@as(u32, slab_count / 2), class.empty_count);
    try std.testing.expectEqual(@as(u32, 1), class.live_slab_count);
    try std.testing.expectEqual(@as(u32, slab_count), class.live_slab_peak);

    // Structural RSS bound: mapped slabs (live + cached) never exceed
    // the class's historical live peak.
    try std.testing.expect(class.live_slab_count + class.empty_count <= class.live_slab_peak);
}

test "ARC empty-slab cache: reused slabs are metadata-reinitialized and serve valid slots" {
    const ctx = init(null) orelse return error.OutOfMemory;
    defer deinit(ctx);
    const class = testEmptyCacheClass(ctx);

    const slab_capacity = test_empty_cache_slab_capacity;
    var slots: [2 * test_empty_cache_slab_capacity][*]u8 = undefined;
    for (&slots) |*slot| slot.* = try testAllocEmptyCacheSlot(ctx);

    // Empty the first slab so it lands on the empty cache; remember its
    // base so reuse can be proven by address identity.
    const first_slab = slabFromSlotPtr(slots[0]);
    for (slots[0..slab_capacity]) |slot| testFreeEmptyCacheSlot(ctx, slot);
    try std.testing.expectEqual(@as(u32, 1), class.empty_count);

    const mmap_before_reuse = test_slab_mmap_total;

    // The current (second) slab is full, so the next allocation must
    // rotate to a fresh slab — which must come from the empty cache,
    // not a new mapping.
    var reused_slots: [test_empty_cache_slab_capacity][*]u8 = undefined;
    for (&reused_slots) |*slot| {
        const slot_bytes = allocateRefcounted(ctx, 4096, 8) orelse return error.OutOfMemory;
        slot.* = slot_bytes;
        try std.testing.expectEqual(first_slab, slabFromSlotPtr(slot_bytes));
        try std.testing.expectEqual(@as(u32, 1), refcountSized(ctx, slot_bytes, 4096, 8));
    }
    try std.testing.expectEqual(mmap_before_reuse, test_slab_mmap_total);
    try std.testing.expectEqual(@as(u32, 0), class.empty_count);

    // Header invariants after reuse: magic and geometry intact, the
    // bump cursor consumed the whole slab, every slot live.
    try std.testing.expectEqual(SLAB_MAGIC, first_slab.magic);
    try std.testing.expectEqual(test_empty_cache_class_index, first_slab.class_index);
    try std.testing.expectEqual(slab_capacity, first_slab.capacity);
    try std.testing.expectEqual(slab_capacity, first_slab.live_count);
    try std.testing.expectEqual(slab_capacity, first_slab.bump_index);
    try std.testing.expectEqual(NULL_SLOT, first_slab.free_list_head);

    // Retain/release cycles on reused slots behave normally.
    retainSized(ctx, reused_slots[0], 4096, 8);
    try std.testing.expectEqual(@as(u32, 2), refcountSized(ctx, reused_slots[0], 4096, 8));
    releaseSized(ctx, reused_slots[0], 4096, 8, null);
    try std.testing.expectEqual(@as(u32, 1), refcountSized(ctx, reused_slots[0], 4096, 8));

    for (&reused_slots) |slot| releaseSized(ctx, slot, 4096, 8, null);
    for (slots[slab_capacity..]) |slot| testFreeEmptyCacheSlot(ctx, slot);
}

test "ARC empty-slab cache: deinit returns every cached slab to the OS" {
    const mmap_baseline = test_slab_mmap_total;
    const unmap_baseline = test_slab_unmap_total;

    {
        const ctx = init(null) orelse return error.OutOfMemory;
        defer deinit(ctx);
        const class = testEmptyCacheClass(ctx);

        // Oscillate: build four slabs, tear them down, leaving cached
        // empties plus the current slab for deinit to reclaim.
        var slots: [4 * test_empty_cache_slab_capacity][*]u8 = undefined;
        for (&slots) |*slot| slot.* = try testAllocEmptyCacheSlot(ctx);
        for (&slots) |slot| testFreeEmptyCacheSlot(ctx, slot);
        try std.testing.expect(class.empty_count > 0);
    }

    // Accounting-based leak check: every slab mapped during the block
    // (including all cached empties) was unmapped by teardown.
    try std.testing.expectEqual(
        test_slab_mmap_total - mmap_baseline,
        test_slab_unmap_total - unmap_baseline,
    );
}

test "ARC empty-slab cache: a workload that never oscillates caches no empties" {
    const ctx = init(null) orelse return error.OutOfMemory;
    defer deinit(ctx);
    const class = testEmptyCacheClass(ctx);

    const slab_count = 5;
    var slots: [slab_count * test_empty_cache_slab_capacity][*]u8 = undefined;
    for (&slots) |*slot| {
        slot.* = try testAllocEmptyCacheSlot(ctx);
        // Growth-only allocation never produces an empty slab, so the
        // cache stays empty for the entire run.
        try std.testing.expectEqual(@as(u32, 0), class.empty_count);
    }
    try std.testing.expectEqual(@as(u32, slab_count), class.live_slab_count);
    try std.testing.expectEqual(@as(u32, slab_count), class.live_slab_peak);
}

test "ARC large allocations: wholesale deinit reclaims every live large cell (P3-J1 leak-exactness)" {
    const alloc_baseline = test_large_alloc_total;
    const free_baseline = test_large_free_total;

    const ctx = init(null) orelse return error.OutOfMemory;
    // Above every slab class (> MAX_SLAB_CLASS_SIZE) so these take the
    // page_allocator large-allocation path, outside the slab pool.
    const large_size: usize = MAX_SLAB_CLASS_SIZE + 4096;
    const align_bytes: u32 = 16;

    // Three refcounted large cells; individually release ONE, leave TWO live
    // — the killed-process shape whose live large cells must be bulk-reclaimed
    // by the wholesale teardown rather than leaked.
    const first = arcAllocateRefcounted(ctx, large_size, align_bytes) orelse return error.OutOfMemory;
    const second = arcAllocateRefcounted(ctx, large_size, align_bytes) orelse return error.OutOfMemory;
    const third = arcAllocateRefcounted(ctx, large_size, align_bytes) orelse return error.OutOfMemory;
    // Touch the storage to prove it is valid and distinct.
    first[0] = 0xAA;
    second[large_size - 1] = 0xBB;
    third[0] = 0xCC;
    try std.testing.expectEqual(@as(usize, 3), test_large_alloc_total - alloc_baseline);

    // Individually release the second (rc 1 -> 0): it unlinks from the
    // context list and frees its page.
    arcReleaseSized(ctx, @ptrCast(second), large_size, align_bytes, null);
    try std.testing.expectEqual(@as(usize, 1), test_large_free_total - free_baseline);

    // Wholesale teardown reclaims the two still-live large cells — leak-exact:
    // every large allocation of this context is freed, none leaked.
    deinit(ctx);
    try std.testing.expectEqual(@as(usize, 3), test_large_free_total - free_baseline);
    try std.testing.expectEqual(
        test_large_alloc_total - alloc_baseline,
        test_large_free_total - free_baseline,
    );
}

// ---------------------------------------------------------------------------
// Region-move (detach / adopt) tests — the same-model O(1) region-move send
// (plan item 6.1, P3-J5; E5 gate). These prove the R4 mechanism at the manager
// level: a LARGE buffer moves between two contexts of the same model WITHOUT
// copying (pointer identity preserved), in O(1) (pure list surgery independent
// of size), and leak-exact (the sender no longer frees it, the receiver does).
// ---------------------------------------------------------------------------

test "ARC region-move: a large buffer detaches from the sender and adopts into the receiver without copying" {
    const alloc_baseline = test_large_alloc_total;
    const free_baseline = test_large_free_total;

    const sender = init(null) orelse return error.OutOfMemory;
    const receiver = init(null) orelse return error.OutOfMemory;

    // A large (page_allocator-backed) container buffer — the shape the O(1)
    // move is sound for. Fill it with a sentinel so we can prove the bytes are
    // NEVER copied (the same physical block ends up owned by the receiver).
    const large_size: usize = MAX_SLAB_CLASS_SIZE + 4096;
    const align_bytes: u32 = 16;
    const buffer = arcAllocate(sender, large_size, align_bytes) orelse return error.OutOfMemory;
    buffer[0] = 0x42;
    buffer[large_size - 1] = 0x99;
    const original_address = @intFromPtr(buffer);
    try std.testing.expectEqual(@as(usize, 1), test_large_alloc_total - alloc_baseline);

    // Detach from the sender: the block is now orphaned (owned by neither).
    // `true` == it was large-backed and is relocatable (not a copy-fallback).
    try std.testing.expect(arcDetachRegion(sender, buffer, large_size, align_bytes));

    // The sender's teardown MUST NOT free the detached block (it is no longer
    // in the sender's `large_head`) — else it would double-free / dangle.
    deinit(sender);
    try std.testing.expectEqual(@as(usize, 0), test_large_free_total - free_baseline);

    // Adopt into the receiver: same physical block, no copy — pointer identity
    // and the sentinel bytes are preserved.
    arcAdoptRegion(receiver, buffer, large_size, align_bytes);
    try std.testing.expectEqual(original_address, @intFromPtr(buffer));
    try std.testing.expectEqual(@as(u8, 0x42), buffer[0]);
    try std.testing.expectEqual(@as(u8, 0x99), buffer[large_size - 1]);

    // The receiver now owns it: its wholesale teardown reclaims exactly this
    // one block (leak-exact — moved once, freed once).
    deinit(receiver);
    try std.testing.expectEqual(@as(usize, 1), test_large_free_total - free_baseline);
    try std.testing.expectEqual(
        test_large_alloc_total - alloc_baseline,
        test_large_free_total - free_baseline,
    );
}

test "ARC region-move: the receiver can individually free an adopted large buffer" {
    const alloc_baseline = test_large_alloc_total;
    const free_baseline = test_large_free_total;

    const sender = init(null) orelse return error.OutOfMemory;
    const receiver = init(null) orelse return error.OutOfMemory;
    defer deinit(receiver);
    defer deinit(sender);

    const large_size: usize = MAX_SLAB_CLASS_SIZE + 4096;
    const align_bytes: u32 = 16;
    // Use the refcounted large path so the receiver can release it by rc.
    const buffer = arcAllocateRefcounted(sender, large_size, align_bytes) orelse return error.OutOfMemory;

    try std.testing.expect(arcDetachRegion(sender, buffer, large_size, align_bytes));
    arcAdoptRegion(receiver, buffer, large_size, align_bytes);

    // The receiver frees it individually (rc 1 -> 0). `largeFree` unlinks from
    // the RECEIVER's `large_head` (where adopt placed it) — the list surgery is
    // consistent, so the free is clean and leak-exact.
    arcReleaseSized(receiver, @ptrCast(buffer), large_size, align_bytes, null);
    try std.testing.expectEqual(@as(usize, 1), test_large_free_total - free_baseline);
    try std.testing.expectEqual(
        test_large_alloc_total - alloc_baseline,
        test_large_free_total - free_baseline,
    );
}

test "ARC region-move: a slab-backed buffer is NOT relocatable (detach returns false, copy-fallback)" {
    const ctx = init(null) orelse return error.OutOfMemory;
    defer deinit(ctx);

    // A small buffer maps to a slab class — interleaved with unrelated cells in
    // a shared slab, so it cannot be re-parented per-cell. `detachRegion` must
    // report `false` so the send path falls back to copy (the R4 degradation).
    const small_size: usize = 64;
    const align_bytes: u32 = 8;
    const buffer = arcAllocate(ctx, small_size, align_bytes) orelse return error.OutOfMemory;
    defer deallocate(ctx, buffer, small_size, align_bytes);
    try std.testing.expect(!arcDetachRegion(ctx, buffer, small_size, align_bytes));
}

test "ARC region-move: detach/adopt is O(1) — cost is independent of buffer size" {
    // The move touches only the block's `LargeHeader` links and each context's
    // `large_head`; it never reads or writes the payload. Proven structurally
    // here by moving buffers across three orders of magnitude and asserting the
    // SAME constant work each time (one detach + one adopt, pointer preserved).
    const align_bytes: u32 = 16;
    const sizes = [_]usize{
        MAX_SLAB_CLASS_SIZE + 1,
        MAX_SLAB_CLASS_SIZE * 16,
        MAX_SLAB_CLASS_SIZE * 256, // ~1 MiB — the E6 catastrophe scale
    };
    for (sizes) |size| {
        const sender = init(null) orelse return error.OutOfMemory;
        const receiver = init(null) orelse return error.OutOfMemory;
        const buffer = arcAllocate(sender, size, align_bytes) orelse return error.OutOfMemory;
        const address_before = @intFromPtr(buffer);
        try std.testing.expect(arcDetachRegion(sender, buffer, size, align_bytes));
        arcAdoptRegion(receiver, buffer, size, align_bytes);
        // Pointer identity across every size == no relocation == O(1).
        try std.testing.expectEqual(address_before, @intFromPtr(buffer));
        deinit(sender); // must not touch the moved block
        deinit(receiver); // reclaims the moved block
    }
}
