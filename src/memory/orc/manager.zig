//! ORC — ORC-over-ARC cyclic reclamation memory manager (plan item 3.4, P3-J6).
//!
//! ORC is Zap's cyclic reclamation model: **ARC plus a Bacon–Rajan
//! trial-deletion cycle collector**, exactly as Nim's ORC is "ARC + a cycle
//! collector". It is a per-spawn manager option (`Memory.ORC`) that reclaims
//! reference cycles ARC alone cannot — a struct/closure that references itself,
//! or a set of cells with mutual references — while preserving ARC's prompt,
//! deterministic reclamation for acyclic data.
//!
//! ## The Zap-specific advantage this manager proves (the P3-J6 hypothesis)
//!
//! Nim inlines its refcount ops, so ORC changes Nim's *generated code* ("orc
//! produces more machine code than arc"). Zap's refcount ops are **manager ABI
//! entry points** (`retain`/`release`/`retain_sized`/`release_sized` — real
//! `callconv(.c)` vtable slots, not inlined). The Bacon–Rajan cycle-root
//! candidate buffering — a decrement that does *not* reach zero buffers the
//! cell as a cycle-root candidate — therefore lives **entirely inside this
//! manager's `release` implementation** (`noteDecrement` → `possibleRoot`).
//!
//! The consequence, verified by P3-J6: an ORC manager declares **REFCOUNTED on
//! Axis A** (`declared_caps` bit 0, `CAP_REFCOUNT_V1_BIT`) exactly like ARC, so
//! it **shares the REFCOUNTED codegen specialization** — the compiler emits the
//! same `retain`/`release` call sites for an ARC process and an ORC process
//! (`src/monomorphize.zig` keys a specialization on the reclamation *model*,
//! and ORC's model *is* `.refcounted`). Cycle collection is entirely
//! manager-internal: it adds only the runtime machinery below plus one new
//! **capability descriptor** (`CYCL`, the per-type cell-shape registration the
//! collector traces through) — never a new Axis-A model, never a codegen
//! divergence from ARC.
//!
//! ## Deeply per-process, no stack scanning
//!
//! Unlike the conservative mark-sweep collector (`src/memory/gc/manager.zig`,
//! `Memory.GC`, TRACED), ORC works on the **refcount graph**, not the stack:
//! it needs *no* conservative scan of a fiber's saved register context or
//! private stack. Each spawned process owns its own ORC context (thread-local
//! candidate buffer, thread-local collection); collection runs at the owning
//! process's yield points / teardown, never a global stop-the-world. This is
//! why ORC ships regardless of experiment E8's fiber-stack-scan verdict — E8
//! only decides whether conservative mark-sweep *also* ships.
//!
//! ## The Bacon–Rajan trial-deletion algorithm (Bacon & Rajan 2001, §3)
//!
//! The synchronous algorithm, mapped onto the ARC ABI:
//!
//!   * `Decrement` = this manager's `release`/`release_sized`. On a decrement
//!     to zero the ARC fast path runs (deep-walk teardown, prompt free) unless
//!     the cell is a buffered root (then the free defers to the collector). On
//!     a decrement to non-zero, `possibleRoot` colours the cell purple and
//!     appends it to the roots buffer — *iff* it has children (a `deep_walk`),
//!     since a leaf can never anchor a cycle.
//!   * `CollectCycles` = `MarkRoots` (trial-decrement the subgraph reachable
//!     from each purple root, colouring gray), `ScanRoots` (a root whose
//!     trial refcount survived at > 0 is externally reachable → repaint its
//!     subgraph black and restore the trial decrements; else paint white),
//!     `CollectRoots` (free every still-white cell — a genuinely unreachable
//!     cycle).
//!
//! Per-cell colour and the buffered flag live in **manager-side maps** keyed by
//! the cell pointer — never in the cell header — so the ORC cell layout is
//! byte-identical to ARC's (a 4-byte refcount at offset 0 for inline-header
//! cells; a manager side-table refcount for `allocate_refcounted` cells). That
//! byte-identical layout is what lets ORC share ARC's codegen.
//!
//! ## Determinism
//!
//! Acyclic data is reclaimed with the same prompt, deterministic ARC timing
//! (the fast path in `noteDecrement` frees at the zero-transition, untouched by
//! the collector). Only genuine cycles wait for a collection point — bounded,
//! thread-local, and free of the stop-the-world unpredictability mark-sweep
//! carries.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// Manager ABI (spec: docs/memory-manager-abi.md). Self-contained copies of the
// wire structs — the production-manager rule forbids a manager (compiled by the
// driver as a standalone object, `builtin.output_mode == .Obj`) from importing
// sibling compiler or manager modules, so these mirror `src/memory/arc/
// manager.zig` byte-for-byte. The comptime layout asserts below guard ORC's OWN
// copies against the spec's fixed byte sizes (they compare these local structs
// to literal sizes, so they catch a unilateral edit to ORC's copy — but not a
// drift on ARC's side, which they never inspect). Cross-manager layout drift
// (ORC vs ARC vs the runtime's test-only slab pool) is caught by
// `tools/slab_pool_drift_test.zig`, which reads all three source files and
// cross-checks their slab-pool constants byte-for-byte (P3-R1a extended it to
// include ORC's copy).
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

/// Per-type destructive teardown callback (spec §8): releases the cell's
/// children and frees its backing storage. ORC invokes it on the ARC fast path
/// (acyclic zero-transition) and when a buffered cell independently reaches
/// zero — never inside cycle `CollectWhite` (which frees the cycle shallowly).
const ZapDeepWalkFn = *const fn (object: *anyopaque) callconv(.c) void;

/// REFCOUNT_V1 capability vtable (spec §8; v1.2 relocate-extended). ORC exposes
/// the identical nine-slot shape as ARC so the runtime's REFCOUNTED dispatch —
/// the *shared* specialization — calls ORC exactly as it calls ARC.
const ZapRefcountCapabilityV1 = extern struct {
    retain: *const fn (ctx: *anyopaque, object: *anyopaque) callconv(.c) void,
    release: *const fn (ctx: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
    retain_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
    release_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32, deep_walk: ?ZapDeepWalkFn) callconv(.c) void,
    allocate_refcounted: *const fn (ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8,
    refcount_sized: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32,
    detach_region: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) bool,
    adopt_region: *const fn (ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void,
    free_detached_region: *const fn (object: *anyopaque) callconv(.c) void,
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
    const PTR: usize = @sizeOf(*const anyopaque);
    if (@sizeOf(ZapMemoryManagerMetaV1) != 32) @compileError(
        "orc: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "orc: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != std.mem.alignForward(usize, 12, PTR) + PTR) @compileError(
        "orc: ZapCapabilityDescV1 size must be its integer prefix plus one pointer",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != std.mem.alignForward(usize, 16 + 5 * PTR, @alignOf(ZapMemoryManagerCoreV1))) @compileError(
        "orc: ZapMemoryManagerCoreV1 size must be its 16-byte prefix plus five pointers (aligned)",
    );
    if (@sizeOf(ZapRefcountCapabilityV1) != 9 * PTR) @compileError(
        "orc: ZapRefcountCapabilityV1 (v1.2 relocate-extended) must be nine pointer slots wide",
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

/// `REFC` FourCC capability tag (spec §7.1).
const REFC_TAG: u32 = std.mem.readInt(u32, "REFC", builtin.target.cpu.arch.endian());

/// `CYCL` FourCC capability tag — the ORC cycle-collection capability
/// descriptor. This is the "at most a new capability descriptor" §2.5 permits:
/// it carries the per-type cell-shape registration (`register_cell_type`) the
/// collector traces through and the `collect_cycles` trigger, all
/// manager-internal. Managers that do not declare it (ARC) are untouched.
const CYCL_TAG: u32 = std.mem.readInt(u32, "CYCL", builtin.target.cpu.arch.endian());

/// `REFCOUNT_V1` bit in `declared_caps` (spec §7.1 — bit 0). ORC's reclamation
/// model is **Axis A == REFCOUNTED**, byte-identical to ARC's `0x1` — this is
/// the load-bearing fact behind the shares-the-specialization hypothesis. The
/// cycle collector is NOT an Axis-A bit; it is the separate `CYCL` descriptor.
const CAP_REFCOUNT_V1_BIT: u64 = 0x0000_0000_0000_0001;

/// Object-format-conditional `.zapmem` section name (spec §3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    .wasm => ".zapmem",
    else => @compileError("orc: unsupported object format for .zapmem section"),
};

/// The roots buffer high-watermark that triggers an opportunistic collection
/// from inside `allocate`, keeping a long allocate-buffer-drop loop bounded in
/// candidate memory (Bacon–Rajan collects when the buffer fills). Teardown
/// always runs a final collection regardless of this threshold.
const ROOTS_COLLECT_THRESHOLD: usize = 256;

// ---------------------------------------------------------------------------
// Cycle-collection types — the `CYCL` capability surface
// ---------------------------------------------------------------------------

/// Visitor the collector hands to a cell's trace callback. The trace calls it
/// once per Arc'd child, reporting the child cell pointer and the child's own
/// `deep_walk` (the stable per-type key under which the child's cell descriptor
/// is registered — how the collector recurses into the child).
const OrcVisitFn = *const fn (visitor_ctx: *anyopaque, child: *anyopaque, child_deep_walk: ?ZapDeepWalkFn) callconv(.c) void;

/// Per-type non-destructive child enumerator (the Bacon–Rajan `children(S)`).
/// Analogous to `deep_walk` but it *visits* rather than releases: for each
/// Arc'd child of `cell` it calls `visit(visitor_ctx, child, child_deep_walk)`.
/// Generated per type by the runtime (`ArcRuntime.OrcTraceFnFor`) from the same
/// field walk that generates `deep_walk`; supplied by tests for test cells.
const OrcTraceFn = *const fn (cell: *anyopaque, visitor_ctx: *anyopaque, visit: OrcVisitFn) callconv(.c) void;

/// Per-type "shallow finalize" for `CollectWhite`: free the cell's owned
/// *non-cell* storage (e.g. a `List`'s element buffer) WITHOUT releasing its
/// Arc'd children (the collector frees those by recursion). Null for
/// self-contained cells whose entire footprint is the `[base, cell_size)` the
/// manager allocated (mutually-referencing structs / closures — the canonical
/// cycle shape). Runs before the manager returns the cell's storage.
const OrcFinalizeFn = *const fn (cell: *anyopaque) callconv(.c) void;

/// The per-type "cell shape" the collector needs to trial-delete and reclaim a
/// cell — Zap's analogue of Nim's `TNimType` marker. Registered once per cyclic
/// type, keyed by the type's `deep_walk` pointer (a stable per-type identity).
const OrcCellDescriptor = struct {
    /// Enumerate the cell's Arc'd children.
    trace: OrcTraceFn,
    /// Byte footprint of the cell's own storage (what the manager allocated).
    cell_size: usize,
    /// Alignment the cell's storage was allocated with.
    cell_align: u32,
    /// True when the refcount is the 4-byte inline header at offset 0
    /// (Map/List/MapIter, `core.allocate` cells); false when it lives in the
    /// manager side-table (`allocate_refcounted` cells).
    is_inline: bool,
    /// Optional shallow non-cell-storage free; see `OrcFinalizeFn`.
    finalize: ?OrcFinalizeFn,
};

/// Bacon–Rajan tri-(quad-)colour marking state. Absent from the colour map ⇒
/// `black` (the "in use / freshly incremented" default), so only cells that
/// enter the collector's consideration ever get a map entry.
const Color = enum(u8) { black, gray, white, purple };

/// One buffered cycle-root candidate: the cell plus the `deep_walk` under which
/// its `OrcCellDescriptor` is registered (how the collector traces it).
const RootEntry = struct {
    cell: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
};

/// Manager-side side-table entry for an `allocate_refcounted` cell: its
/// refcount (kept out-of-band so the payload slot stays 100% payload, matching
/// the ARC side-table layout `reusableCellFootprint` assumes) plus its extent.
const SideCell = struct {
    refcount: u32,
    size: usize,
    alignment: u32,
};

// ---------------------------------------------------------------------------
// Production per-process heap — the page-backed size-class slab pool (G7).
//
// A VERBATIM structural copy of `src/memory/arc/manager.zig`'s slab pool. The
// production-manager rule (spec §11.1.1) forbids a standalone-object manager
// from importing sibling files — its only dependencies are `std` and `builtin`
// — so a shared slab-pool module is impossible; the duplication is structural,
// not accidental (exactly as `runtime.zig`'s `TestOnlyArcSlabPool` duplicates
// it for test builds). `tools/slab_pool_drift_test.zig` cross-checks the layout
// CONSTANTS across all three copies byte-for-byte so no copy can drift.
//
// ORC keeps its OWN refcounts (inline header at offset 0 for `core.allocate`
// cells; the manager `side_table` for `allocate_refcounted` cells), so it never
// reads the slab's per-slot side-table refcount — the geometry is identical to
// ARC's only so the copy stays verbatim and the drift check stays trivial. The
// heap serves prompt individual free (the ARC fast path), wholesale teardown
// (per-process leak-exactness, P3-J1), and a page-backed large path (the
// substrate a future O(1) ORC region move needs — Phase-6 follow-up).
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

fn largeAlloc(self: *SlabHeap, size: usize, alignment: u32, init_refcount: u32) ?[*]u8 {
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
        .next = self.large_head,
    };
    if (self.large_head) |old_head| old_head.prev = header_ptr;
    self.large_head = header_ptr;
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

fn largeFree(self: *SlabHeap, ptr: [*]u8) void {
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
        self.large_head = header_ptr.next;
    }
    if (header_ptr.next) |next| next.prev = header_ptr.prev;
    largeFreePage(header_ptr);
}

inline fn largeHeader(ptr: *anyopaque) *LargeHeader {
    const byte_ptr: [*]u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(byte_ptr - @sizeOf(LargeHeader)));
}

/// The production per-process backing heap: the size-class slab pool plus the
/// intrusive list of live large (`page_allocator`-backed) allocations. Mirrors
/// `ArcContext`'s `{ slab_pool, large_head }` and ARC's `arcAllocate` /
/// `arcDeallocate` / `arcDeinit` routing, but exposes a raw-bytes seam
/// (`rawAlloc` / `rawFree` / `deinit`) that `OrcContext.gpa` drives through the
/// `BackingHeap` comptime seam. `init` is comptime — an all-empty pool — so
/// `orcInit`'s `.gpa = .init` works for both this and the test DebugAllocator.
const SlabHeap = struct {
    slab_pool: SlabPool,
    large_head: ?*LargeHeader = null,

    const init: SlabHeap = .{ .slab_pool = slabPoolInit(), .large_head = null };

    /// Raw allocation (`core.allocate` semantics): slab-backed for sizes that
    /// map to a class, the large `page_allocator` path otherwise. `init_refcount
    /// = 0` — ORC never uses the slab's side-table refcount.
    fn rawAlloc(self: *SlabHeap, size: usize, alignment: u32) ?[*]u8 {
        std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
        if (size == 0) return null;
        if (lookupClass(size, alignment)) |class_index| {
            return slabAllocSlot(&self.slab_pool, class_index, 0);
        }
        return largeAlloc(self, size, alignment, 0);
    }

    /// Prompt individual free (the ARC fast path): return a slab slot to its
    /// class's free list, or unmap a large allocation. `size`/`alignment` MUST
    /// match the original request (they select slab-vs-large identically).
    fn rawFree(self: *SlabHeap, ptr: [*]u8, size: usize, alignment: u32) void {
        std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
        if (size == 0) return;
        if (lookupClass(size, alignment)) |class_index| {
            const slab = slabFromSlotPtr(ptr);
            std.debug.assert(slab.magic == SLAB_MAGIC);
            std.debug.assert(slab.class_index == class_index);
            const slot_index = slotIndexInSlab(slab, ptr);
            slabFreeSlot(&self.slab_pool, slab, slot_index);
            return;
        }
        largeFree(self, ptr);
    }

    /// Wholesale per-process teardown (P3-J1 leak-exactness): return every live
    /// large allocation and every mapped slab (current + partial + cached empty)
    /// to the OS. A killed process's still-live cells are all reclaimed here.
    fn deinit(self: *SlabHeap) void {
        while (self.large_head) |header_ptr| {
            self.large_head = header_ptr.next;
            std.debug.assert(header_ptr.magic == LARGE_MAGIC);
            largeFreePage(header_ptr);
        }
        var class_index: u32 = 0;
        while (class_index < SLAB_CLASS_COUNT) : (class_index += 1) {
            const class = &self.slab_pool.classes[class_index];
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
    }
};

// ---------------------------------------------------------------------------
// Per-process ORC context
// ---------------------------------------------------------------------------

/// The per-process backing heap type (G7). PRODUCTION uses the page-backed
/// `SlabHeap` (fast, individual-free + wholesale-teardown, page-backed large
/// path) — NOT the leak-detecting DebugAllocator, which is materially slower.
/// TESTS swap in the DebugAllocator so the leak-exactness oracle can observe
/// reclamation exactly; `enable_memory_limit` additionally exposes
/// `total_requested_bytes`, the live-byte counter the negative-control test
/// reads to witness an un-reclaimed cycle WITHOUT the `deinit`-time leak report
/// (whose `log.err` would fail the test runner even for an intentional leak).
///
/// Keyed on `builtin.is_test`: the manager compiled as a standalone object for a
/// real binary (`output_mode == .Obj`, `is_test == false`) always gets the
/// production `SlabHeap`, so the `:test_concurrency` gate-ON acceptance path runs
/// on it. ORC's `rawAlloc`/`rawFree`/`orcDeinitInner` route through this via a
/// matching comptime `is_test` seam (the two heaps expose different APIs).
const BackingHeap = if (builtin.is_test)
    std.heap.DebugAllocator(.{ .enable_memory_limit = true })
else
    SlabHeap;

const OrcContext = struct {
    /// Backing sub-allocator for this process's refcounted cells. A per-instance
    /// general-purpose allocator: it supports the prompt individual free the ARC
    /// fast path needs, the wholesale teardown the per-process leak-exactness
    /// contract needs (P3-J1), and — critically for the leak-exactness proofs —
    /// exact leak accounting at `deinit`. `enable_memory_limit` adds a live-byte
    /// counter (`total_requested_bytes`) the negative-control test reads to
    /// observe an un-reclaimed cycle WITHOUT the `deinit`-time leak report (whose
    /// `log.err` would fail the test runner even for an intentional leak).
    gpa: BackingHeap,

    /// Bookkeeping allocator (roots/colour/registry/side-table maps). Kept
    /// SEPARATE from `gpa` so `gpa`'s leak check reflects only *cells* — the
    /// clean leak-exactness oracle the tests assert on.
    meta: std.mem.Allocator,

    /// The Bacon–Rajan roots buffer: purple cycle-root candidates awaiting a
    /// collection. Appended by `possibleRoot` (a decrement to non-zero), drained
    /// by `collectCycles`.
    roots: std.ArrayListUnmanaged(RootEntry) = .empty,

    /// `buffered(S)` — membership means the cell is currently in `roots`.
    /// Prevents double-buffering and gates the defer-free-while-buffered path.
    buffered: std.AutoHashMapUnmanaged(usize, void) = .empty,

    /// `color(S)` — Bacon–Rajan marking colour (absent ⇒ black).
    color: std.AutoHashMapUnmanaged(usize, Color) = .empty,

    /// Per-type cell-shape registry keyed by `deep_walk` pointer (the `CYCL`
    /// capability's payload). Populated by `registerCellType`.
    descriptors: std.AutoHashMapUnmanaged(usize, OrcCellDescriptor) = .empty,

    /// Side-table refcounts for `allocate_refcounted` cells.
    side_table: std.AutoHashMapUnmanaged(usize, SideCell) = .empty,

    /// Reentrancy guard: true while a collection is in progress, so a `release`
    /// the collector's teardown triggers cannot recursively re-enter.
    collecting: bool = false,
};

/// Read a cell's refcount uniformly across the inline-header and side-table
/// layouts, given whether it is inline.
fn cellRefcount(ctx: *OrcContext, cell: *anyopaque, is_inline: bool) u32 {
    if (is_inline) {
        const rc_ptr: *const u32 = @ptrCast(@alignCast(cell));
        return @atomicLoad(u32, rc_ptr, .monotonic);
    }
    const entry = ctx.side_table.getPtr(@intFromPtr(cell)) orelse return 0;
    return entry.refcount;
}

/// Trial-mutate a cell's refcount by `delta` (Bacon–Rajan `MarkGray` decrements
/// / `ScanBlack` restores). Single-threaded per-process at a collection point,
/// so a plain read-modify-write is sound.
fn cellRefcountAdjust(ctx: *OrcContext, cell: *anyopaque, is_inline: bool, delta: i64) void {
    if (is_inline) {
        const rc_ptr: *u32 = @ptrCast(@alignCast(cell));
        const cur: i64 = @intCast(@atomicLoad(u32, rc_ptr, .monotonic));
        @atomicStore(u32, rc_ptr, @intCast(cur + delta), .monotonic);
        return;
    }
    if (ctx.side_table.getPtr(@intFromPtr(cell))) |entry| {
        const cur: i64 = @intCast(entry.refcount);
        entry.refcount = @intCast(cur + delta);
    }
}

fn getColor(ctx: *OrcContext, cell: *anyopaque) Color {
    return ctx.color.get(@intFromPtr(cell)) orelse .black;
}

fn setColor(ctx: *OrcContext, cell: *anyopaque, c: Color) void {
    if (c == .black) {
        _ = ctx.color.remove(@intFromPtr(cell));
        return;
    }
    ctx.color.put(ctx.meta, @intFromPtr(cell), c) catch {};
}

fn isBuffered(ctx: *OrcContext, cell: *anyopaque) bool {
    return ctx.buffered.contains(@intFromPtr(cell));
}

// ---------------------------------------------------------------------------
// Core vtable — init / deinit / allocate / deallocate / get_capability_desc
// ---------------------------------------------------------------------------

fn orcInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const bootstrap = std.heap.page_allocator;
    const ctx = bootstrap.create(OrcContext) catch return null;
    ctx.* = .{
        .gpa = .init,
        .meta = std.heap.page_allocator,
    };
    return @ptrCast(ctx);
}

fn orcDeinit(ctx_opaque: *anyopaque) callconv(.c) void {
    // Production teardown is best-effort (spec §4.4): the leak status is
    // discarded here. Tests drive `orcDeinitInner` directly to ASSERT
    // leak-exactness (a residual cell ⇒ `.leak`), the cycle-collection oracle.
    _ = orcDeinitInner(ctx_opaque);
}

/// The teardown body, returning the backing allocator's leak check. A final
/// collection reclaims any collectable cycle before wholesale teardown so a
/// normal-exit process leaves a clean slate; the bookkeeping maps are drawn
/// from `meta` (kept OUT of `gpa`'s leak check) so `.leak` reflects ONLY cells.
/// `gpa.deinit` unmaps every backing page, so even an uncollectable /
/// unregistered residual cycle has its memory returned — the per-process
/// leak-exactness contract (P3-J1): a killed process never leaks to the OS.
fn orcDeinitInner(ctx_opaque: *anyopaque) std.heap.Check {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    collectCyclesImpl(ctx);
    ctx.roots.deinit(ctx.meta);
    ctx.buffered.deinit(ctx.meta);
    ctx.color.deinit(ctx.meta);
    ctx.descriptors.deinit(ctx.meta);
    ctx.side_table.deinit(ctx.meta);
    // Wholesale-free the backing heap. The DebugAllocator (test) returns a leak
    // check the oracle asserts on; the production `SlabHeap` unmaps every slab
    // and large allocation and has no per-cell accounting, so it reports `.ok`
    // (its leak-exactness is structural — a killed process's whole heap is
    // returned regardless of live cells).
    const check = if (comptime builtin.is_test) ctx.gpa.deinit() else blk: {
        ctx.gpa.deinit();
        break :blk std.heap.Check.ok;
    };
    std.heap.page_allocator.destroy(ctx);
    return check;
}

fn orcAllocate(ctx_opaque: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    return rawAlloc(ctx, size, alignment);
}

fn orcDeallocate(ctx_opaque: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    rawFree(ctx, ptr, size, alignment);
}

fn orcGetCapabilityDesc(ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    if (id == REFC_TAG) return &refcount_descriptor;
    if (id == CYCL_TAG) return &cycle_descriptor;
    return null;
}

/// Raw allocation through the per-process backing allocator. `alignment` is a
/// power of two (spec §4.2). Returns null on exhaustion or an unrepresentable
/// alignment.
fn rawAlloc(ctx: *OrcContext, size: usize, alignment: u32) ?[*]u8 {
    if (size == 0) return null;
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return null;
    // BackingHeap comptime seam: the test DebugAllocator drives a `std.mem
    // .Allocator` (leak oracle); the production `SlabHeap` exposes a raw-bytes
    // `rawAlloc`. Only the selected branch is analysed, so each build sees the
    // API its `ctx.gpa` actually has.
    if (comptime builtin.is_test) {
        const log2: u8 = std.math.log2_int(u32, alignment);
        return ctx.gpa.allocator().rawAlloc(size, @enumFromInt(log2), @returnAddress());
    }
    return ctx.gpa.rawAlloc(size, alignment);
}

fn rawFree(ctx: *OrcContext, ptr: [*]u8, size: usize, alignment: u32) void {
    if (size == 0) return;
    if (comptime builtin.is_test) {
        const log2: u8 = std.math.log2_int(u32, alignment);
        ctx.gpa.allocator().rawFree(ptr[0..size], @enumFromInt(log2), @returnAddress());
        return;
    }
    ctx.gpa.rawFree(ptr, size, alignment);
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 capability — inline-header path (Map / List / MapIter)
// ---------------------------------------------------------------------------

/// REFCOUNT_V1 `retain`: atomic increment on the 4-byte inline header at offset
/// 0 — byte-identical to ARC's `retain`. `Increment` in Bacon–Rajan additionally
/// paints the cell black, but "absent ⇒ black" makes the common case (a cell
/// never yet a candidate) a no-op; a cell currently coloured non-black is
/// repainted so a live retain cancels a stale purple.
fn orcRetain(ctx_opaque: *anyopaque, object: *anyopaque) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    const rc_ptr: *u32 = @ptrCast(@alignCast(object));
    _ = @atomicRmw(u32, rc_ptr, .Add, 1, .monotonic);
    if (ctx.color.count() != 0 and getColor(ctx, object) != .black) setColor(ctx, object, .black);
}

/// REFCOUNT_V1 `release`: atomic decrement on the inline header, then the
/// Bacon–Rajan `Decrement` branch (`noteDecrement`). The cycle-root buffering
/// lives here — THE hypothesis.
fn orcRelease(ctx_opaque: *anyopaque, object: *anyopaque, deep_walk: ?ZapDeepWalkFn) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    const rc_ptr: *u32 = @ptrCast(@alignCast(object));
    const prev = @atomicRmw(u32, rc_ptr, .Sub, 1, .acq_rel);
    std.debug.assert(prev > 0);
    noteDecrement(ctx, object, prev, deep_walk, true, 0, 0);
}

/// The Bacon–Rajan `Decrement`, shared by the inline and side-table paths.
/// `prev` is the pre-decrement refcount; `is_inline` selects the layout;
/// `size`/`alignment` are the side-table cell extent (ignored when inline).
fn noteDecrement(
    ctx: *OrcContext,
    object: *anyopaque,
    prev: u32,
    deep_walk: ?ZapDeepWalkFn,
    is_inline: bool,
    size: usize,
    alignment: u32,
) void {
    if (prev == 1) {
        // Decrement to zero.
        if (isBuffered(ctx, object)) {
            // Defer: the cell is a buffered root that independently reached
            // zero. `MarkRoots` frees it when it removes it from the buffer
            // (Bacon–Rajan: `color=black; if RC==0: Free` after unbuffering).
            setColor(ctx, object, .black);
            return;
        }
        // ARC fast path: prompt, deterministic teardown.
        freeAtZero(ctx, object, deep_walk, is_inline, size, alignment);
        return;
    }
    // Decrement to non-zero → a possible cycle root. Only a cell WITH children
    // (a `deep_walk`) can anchor a cycle; a leaf never can, so skip buffering
    // it (and skip cells of unregistered types — the collector could not trace
    // them, so keeping them out of the buffer is the safe over-retention).
    if (deep_walk == null) return;
    if (!ctx.descriptors.contains(@intFromPtr(deep_walk.?))) return;
    possibleRoot(ctx, object, deep_walk.?);
}

/// The Bacon–Rajan `PossibleRoot`: colour the cell purple and, if not already
/// buffered, append it to the roots buffer.
fn possibleRoot(ctx: *OrcContext, object: *anyopaque, deep_walk: ZapDeepWalkFn) void {
    if (getColor(ctx, object) == .purple) return;
    setColor(ctx, object, .purple);
    if (isBuffered(ctx, object)) return;
    ctx.buffered.put(ctx.meta, @intFromPtr(object), {}) catch {
        // Out of bookkeeping memory: fall back to safe over-retention (leave
        // the cell unbuffered; it is simply not considered for collection).
        setColor(ctx, object, .black);
        return;
    };
    ctx.roots.append(ctx.meta, .{ .cell = object, .deep_walk = deep_walk }) catch {
        _ = ctx.buffered.remove(@intFromPtr(object));
        setColor(ctx, object, .black);
    };
}

/// The ARC fast-path free at the zero-transition (not buffered): destructive
/// deep-walk teardown for inline cells; side-table removal + deep-walk +
/// storage free for side-table cells.
fn freeAtZero(
    ctx: *OrcContext,
    object: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
    is_inline: bool,
    size: usize,
    alignment: u32,
) void {
    if (is_inline) {
        // The runtime's per-type `deep_walk` owns inline-cell teardown (it
        // releases children and frees the cell's storage through `deallocate`),
        // exactly as under ARC.
        if (deep_walk) |walk| walk(object);
        return;
    }
    // Side-table cell: release children, drop the side-table entry, free slot.
    if (deep_walk) |walk| walk(object);
    _ = ctx.side_table.remove(@intFromPtr(object));
    rawFree(ctx, @ptrCast(object), size, alignment);
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 capability — side-table path (generic `Arc(T)` cells)
// ---------------------------------------------------------------------------

/// REFCOUNT_V1 `allocate_refcounted`: a 100%-payload slot (the payload pointer
/// IS the cell base, matching the ARC side-table contract) with the refcount
/// held out-of-band in the manager side-table, initialised to 1.
fn orcAllocateRefcounted(ctx_opaque: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    if (size == 0) return null;
    const mem = rawAlloc(ctx, size, alignment) orelse return null;
    ctx.side_table.put(ctx.meta, @intFromPtr(mem), .{
        .refcount = 1,
        .size = size,
        .alignment = alignment,
    }) catch {
        rawFree(ctx, mem, size, alignment);
        return null;
    };
    maybeCollect(ctx);
    return mem;
}

fn orcRetainSized(ctx_opaque: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    _ = size;
    _ = alignment;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    if (ctx.side_table.getPtr(@intFromPtr(object))) |entry| {
        entry.refcount += 1;
        if (ctx.color.count() != 0 and getColor(ctx, object) != .black) setColor(ctx, object, .black);
    }
}

fn orcReleaseSized(
    ctx_opaque: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
    deep_walk: ?ZapDeepWalkFn,
) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    const entry = ctx.side_table.getPtr(@intFromPtr(object)) orelse return;
    std.debug.assert(entry.refcount > 0);
    const prev = entry.refcount;
    entry.refcount -= 1;
    noteDecrement(ctx, object, prev, deep_walk, false, size, alignment);
}

fn orcRefcountSized(ctx_opaque: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32 {
    _ = size;
    _ = alignment;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    const entry = ctx.side_table.get(@intFromPtr(object)) orelse return 0;
    return entry.refcount;
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 capability — region relocation (v1.2 detach/adopt/free-detached)
// ---------------------------------------------------------------------------

/// Detach a uniquely-owned cell for a same-model O(1) region-move send (plan
/// item 6.1). ORC **declines** the move (always returns false), so the runtime
/// falls back to the always-sound copy send.
///
/// The reason is a deliberate correctness choice, not an oversight: ORC backs
/// each process's heap with a per-instance general-purpose allocator, so a cell
/// is owned by ITS process's allocator and cannot be soundly re-parented into a
/// different process's allocator (nor freed by one) — unlike ARC's large cells,
/// which are `page_allocator`-backed and globally free-able. The O(1) region
/// move for ORC therefore needs a page-backed large-cell path mirroring ARC's
/// (a documented Phase-6 follow-up); until then, declining is correct and
/// leak-free (copy send serialises + reconstructs into the receiver's own heap).
fn orcDetachRegion(ctx_opaque: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) bool {
    _ = ctx_opaque;
    _ = object;
    _ = size;
    _ = alignment;
    return false;
}

/// Adopt a detached region. Unreachable in practice: `orcDetachRegion` declines
/// every move (same-model moves only ever originate from another ORC process's
/// detach), so no ORC block is ever detached to adopt. Present for ABI
/// completeness; the `put` keeps it sound should the runtime ever call it.
fn orcAdoptRegion(ctx_opaque: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    ctx.side_table.put(ctx.meta, @intFromPtr(object), .{
        .refcount = 1,
        .size = size,
        .alignment = alignment,
    }) catch {};
}

/// Free a detached-but-never-adopted region. Unreachable in practice (ORC never
/// detaches — see `orcDetachRegion`); a safe no-op for ABI completeness.
fn orcFreeDetachedRegion(object: *anyopaque) callconv(.c) void {
    _ = object;
}

// ---------------------------------------------------------------------------
// Bacon–Rajan trial-deletion cycle collector
// ---------------------------------------------------------------------------

/// Run a collection when the roots buffer crosses the opportunistic threshold.
fn maybeCollect(ctx: *OrcContext) void {
    if (ctx.roots.items.len >= ROOTS_COLLECT_THRESHOLD) collectCyclesImpl(ctx);
}

/// Visitor context threaded through a trace: it appends each reported child to
/// `children` for the caller to process (a re-entrant, allocation-bounded way
/// to enumerate `children(S)` without the trace knowing the collector's op).
const ChildCollector = struct {
    ctx: *OrcContext,
    children: *std.ArrayListUnmanaged(RootEntry),
};

fn collectChild(visitor_ctx: *anyopaque, child: *anyopaque, child_deep_walk: ?ZapDeepWalkFn) callconv(.c) void {
    const cc: *ChildCollector = @ptrCast(@alignCast(visitor_ctx));
    cc.children.append(cc.ctx.meta, .{ .cell = child, .deep_walk = child_deep_walk }) catch {};
}

/// Enumerate a cell's Arc'd children into `out`, via its registered trace.
/// A cell whose type is not registered yields no children (safe: it is treated
/// as a leaf, so a cycle through an unregistered type is conservatively
/// retained rather than unsoundly collected).
fn traceChildren(
    ctx: *OrcContext,
    cell: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
    out: *std.ArrayListUnmanaged(RootEntry),
) void {
    out.clearRetainingCapacity();
    const dw = deep_walk orelse return;
    const desc = ctx.descriptors.get(@intFromPtr(dw)) orelse return;
    var collector = ChildCollector{ .ctx = ctx, .children = out };
    desc.trace(cell, @ptrCast(&collector), collectChild);
}

fn descriptorFor(ctx: *OrcContext, deep_walk: ?ZapDeepWalkFn) ?OrcCellDescriptor {
    const dw = deep_walk orelse return null;
    return ctx.descriptors.get(@intFromPtr(dw));
}

/// `CollectCycles` (Bacon–Rajan §3): `MarkRoots`, `ScanRoots`, `CollectRoots`.
fn collectCyclesImpl(ctx: *OrcContext) void {
    if (ctx.collecting) return;
    if (ctx.roots.items.len == 0) return;
    ctx.collecting = true;
    defer ctx.collecting = false;

    // Scratch child buffer reused across every trace in this collection.
    var scratch: std.ArrayListUnmanaged(RootEntry) = .empty;
    defer scratch.deinit(ctx.meta);

    markRoots(ctx, &scratch);
    scanRoots(ctx, &scratch);
    collectRoots(ctx, &scratch);
}

/// `MarkRoots`: for each buffered root, `MarkGray` it if still purple; else
/// unbuffer it, and if it independently reached zero while buffered, free it now.
fn markRoots(ctx: *OrcContext, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    var write: usize = 0;
    const items = ctx.roots.items;
    for (items) |root| {
        if (getColor(ctx, root.cell) == .purple) {
            markGray(ctx, root.cell, root.deep_walk, scratch);
            items[write] = root;
            write += 1;
        } else {
            _ = ctx.buffered.remove(@intFromPtr(root.cell));
            const desc = descriptorFor(ctx, root.deep_walk);
            const is_inline = if (desc) |d| d.is_inline else true;
            if (getColor(ctx, root.cell) == .black and cellRefcount(ctx, root.cell, is_inline) == 0) {
                // Reached zero while buffered — the deferred ARC free runs now.
                freeAtZero(
                    ctx,
                    root.cell,
                    root.deep_walk,
                    is_inline,
                    if (desc) |d| d.cell_size else 0,
                    if (desc) |d| d.cell_align else 0,
                );
            }
        }
    }
    ctx.roots.items.len = write;
}

/// `MarkGray(S)`: paint gray and trial-decrement each child's refcount,
/// recursing. Iterative (explicit stack) to bound native recursion depth.
fn markGray(ctx: *OrcContext, root: *anyopaque, root_dw: ?ZapDeepWalkFn, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    var stack: std.ArrayListUnmanaged(RootEntry) = .empty;
    defer stack.deinit(ctx.meta);
    stack.append(ctx.meta, .{ .cell = root, .deep_walk = root_dw }) catch return;
    while (stack.pop()) |node| {
        if (getColor(ctx, node.cell) == .gray) continue;
        setColor(ctx, node.cell, .gray);
        traceChildren(ctx, node.cell, node.deep_walk, scratch);
        // Copy children out — `scratch` is reused by the next trace.
        var kids: std.ArrayListUnmanaged(RootEntry) = .empty;
        defer kids.deinit(ctx.meta);
        kids.appendSlice(ctx.meta, scratch.items) catch return;
        for (kids.items) |child| {
            const cd = descriptorFor(ctx, child.deep_walk);
            const child_inline = if (cd) |d| d.is_inline else true;
            cellRefcountAdjust(ctx, child.cell, child_inline, -1);
            stack.append(ctx.meta, child) catch return;
        }
    }
}

/// `ScanRoots`: `Scan` each buffered root.
fn scanRoots(ctx: *OrcContext, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    for (ctx.roots.items) |root| {
        scan(ctx, root.cell, root.deep_walk, scratch);
    }
}

/// `Scan(S)`: a gray cell whose trial refcount survived at > 0 is externally
/// reachable → `ScanBlack` (restore); else it is provisionally garbage → white,
/// recurse into children.
fn scan(ctx: *OrcContext, root: *anyopaque, root_dw: ?ZapDeepWalkFn, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    var stack: std.ArrayListUnmanaged(RootEntry) = .empty;
    defer stack.deinit(ctx.meta);
    stack.append(ctx.meta, .{ .cell = root, .deep_walk = root_dw }) catch return;
    while (stack.pop()) |node| {
        if (getColor(ctx, node.cell) != .gray) continue;
        const desc = descriptorFor(ctx, node.deep_walk);
        const is_inline = if (desc) |d| d.is_inline else true;
        if (cellRefcount(ctx, node.cell, is_inline) > 0) {
            scanBlack(ctx, node.cell, node.deep_walk, scratch);
            continue;
        }
        setColor(ctx, node.cell, .white);
        traceChildren(ctx, node.cell, node.deep_walk, scratch);
        var kids: std.ArrayListUnmanaged(RootEntry) = .empty;
        defer kids.deinit(ctx.meta);
        kids.appendSlice(ctx.meta, scratch.items) catch return;
        for (kids.items) |child| stack.append(ctx.meta, child) catch return;
    }
}

/// `ScanBlack(S)`: repaint black and restore the trial decrements down the
/// subgraph (the cell is externally reachable, hence live).
fn scanBlack(ctx: *OrcContext, root: *anyopaque, root_dw: ?ZapDeepWalkFn, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    var stack: std.ArrayListUnmanaged(RootEntry) = .empty;
    defer stack.deinit(ctx.meta);
    stack.append(ctx.meta, .{ .cell = root, .deep_walk = root_dw }) catch return;
    while (stack.pop()) |node| {
        // Idempotence guard (mirrors `markGray`/`scan`): a JOIN NODE reached via
        // ≥2 internal in-edges is pushed once per in-edge. Without this guard it
        // is popped more than once and restores each child's trial decrement
        // that many times — permanently inflating a downstream refcount so the
        // cycle can never be reclaimed. A black node is already fully restored.
        if (getColor(ctx, node.cell) == .black) continue;
        setColor(ctx, node.cell, .black);
        traceChildren(ctx, node.cell, node.deep_walk, scratch);
        var kids: std.ArrayListUnmanaged(RootEntry) = .empty;
        defer kids.deinit(ctx.meta);
        kids.appendSlice(ctx.meta, scratch.items) catch return;
        for (kids.items) |child| {
            const cd = descriptorFor(ctx, child.deep_walk);
            const child_inline = if (cd) |d| d.is_inline else true;
            cellRefcountAdjust(ctx, child.cell, child_inline, 1);
            if (getColor(ctx, child.cell) != .black) stack.append(ctx.meta, child) catch return;
        }
    }
}

/// `CollectRoots`: drain the buffer; every still-white cell is unreachable
/// garbage → `CollectWhite`.
fn collectRoots(ctx: *OrcContext, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    // Snapshot the roots, then clear the buffer (CollectWhite frees cells; a
    // freed cell must not remain a buffered root).
    var snapshot: std.ArrayListUnmanaged(RootEntry) = .empty;
    defer snapshot.deinit(ctx.meta);
    snapshot.appendSlice(ctx.meta, ctx.roots.items) catch return;
    for (snapshot.items) |root| _ = ctx.buffered.remove(@intFromPtr(root.cell));
    ctx.roots.clearRetainingCapacity();

    for (snapshot.items) |root| {
        if (getColor(ctx, root.cell) == .white) {
            collectWhite(ctx, root.cell, root.deep_walk, scratch);
        } else {
            // Survivor: reset to the black default for the next cycle.
            setColor(ctx, root.cell, .black);
        }
    }
}

/// `CollectWhite(S)`: paint black, recurse into children (freeing the whole
/// white cycle), then reclaim S's storage shallowly (finalize its non-cell
/// storage, drop any side-table entry, return the cell to the backing
/// allocator) — NOT via `deep_walk`, whose child releases would double-free
/// cells this recursion already frees.
fn collectWhite(ctx: *OrcContext, root: *anyopaque, root_dw: ?ZapDeepWalkFn, scratch: *std.ArrayListUnmanaged(RootEntry)) void {
    var stack: std.ArrayListUnmanaged(RootEntry) = .empty;
    defer stack.deinit(ctx.meta);
    stack.append(ctx.meta, .{ .cell = root, .deep_walk = root_dw }) catch return;
    while (stack.pop()) |node| {
        if (getColor(ctx, node.cell) != .white) continue;
        if (isBuffered(ctx, node.cell)) continue; // freed via CollectRoots' loop
        setColor(ctx, node.cell, .black);
        traceChildren(ctx, node.cell, node.deep_walk, scratch);
        var kids: std.ArrayListUnmanaged(RootEntry) = .empty;
        defer kids.deinit(ctx.meta);
        kids.appendSlice(ctx.meta, scratch.items) catch return;
        for (kids.items) |child| stack.append(ctx.meta, child) catch return;
        freeCycleCell(ctx, node.cell, node.deep_walk);
    }
}

/// Reclaim one white cycle cell's storage shallowly.
fn freeCycleCell(ctx: *OrcContext, cell: *anyopaque, deep_walk: ?ZapDeepWalkFn) void {
    const desc = descriptorFor(ctx, deep_walk) orelse return;
    if (desc.finalize) |fin| fin(cell);
    _ = ctx.color.remove(@intFromPtr(cell));
    if (desc.is_inline) {
        rawFree(ctx, @ptrCast(cell), desc.cell_size, desc.cell_align);
    } else {
        _ = ctx.side_table.remove(@intFromPtr(cell));
        rawFree(ctx, @ptrCast(cell), desc.cell_size, desc.cell_align);
    }
}

// ---------------------------------------------------------------------------
// `CYCL` capability — per-type cell-shape registration + collection trigger
// ---------------------------------------------------------------------------

/// Register a cyclic type's cell shape, keyed by its `deep_walk` pointer. Called
/// once per type (idempotent — re-registration overwrites). This is how the
/// runtime (for a source-registered ORC build) or a test hands the collector the
/// per-type trace it needs; without a registration a cell is conservatively
/// treated as a leaf (never buffered, never collected — safe over-retention).
fn orcRegisterCellType(
    ctx_opaque: *anyopaque,
    deep_walk: ?ZapDeepWalkFn,
    trace: OrcTraceFn,
    cell_size: usize,
    cell_align: u32,
    is_inline: bool,
    finalize: ?OrcFinalizeFn,
) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    const dw = deep_walk orelse return;
    ctx.descriptors.put(ctx.meta, @intFromPtr(dw), .{
        .trace = trace,
        .cell_size = cell_size,
        .cell_align = cell_align,
        .is_inline = is_inline,
        .finalize = finalize,
    }) catch {};
}

/// `CYCL` capability `collect_cycles`: force a full collection now (the yield-
/// point / teardown trigger; also reachable for tests).
fn orcCollectCycles(ctx_opaque: *anyopaque) callconv(.c) void {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    collectCyclesImpl(ctx);
}

/// The `CYCL` capability vtable — the "new capability descriptor" the ORC
/// hypothesis permits (never a new Axis-A model).
const ZapCycleCollectCapabilityV1 = extern struct {
    register_cell_type: *const fn (ctx: *anyopaque, deep_walk: ?ZapDeepWalkFn, trace: OrcTraceFn, cell_size: usize, cell_align: u32, is_inline: bool, finalize: ?OrcFinalizeFn) callconv(.c) void,
    collect_cycles: *const fn (ctx: *anyopaque) callconv(.c) void,
};

// ---------------------------------------------------------------------------
// Capability tables + `.zapmem` section
// ---------------------------------------------------------------------------

const refcount_vtable: ZapRefcountCapabilityV1 = .{
    .retain = orcRetain,
    .release = orcRelease,
    .retain_sized = orcRetainSized,
    .release_sized = orcReleaseSized,
    .allocate_refcounted = orcAllocateRefcounted,
    .refcount_sized = orcRefcountSized,
    .detach_region = orcDetachRegion,
    .adopt_region = orcAdoptRegion,
    .free_detached_region = orcFreeDetachedRegion,
};

const refcount_descriptor: ZapCapabilityDescV1 = .{
    .id = REFC_TAG,
    .version = 1,
    .size = @sizeOf(ZapRefcountCapabilityV1),
    .flags = 0,
    .vtable = @ptrCast(&refcount_vtable),
};

const cycle_vtable: ZapCycleCollectCapabilityV1 = .{
    .register_cell_type = orcRegisterCellType,
    .collect_cycles = orcCollectCycles,
};

const cycle_descriptor: ZapCapabilityDescV1 = .{
    .id = CYCL_TAG,
    .version = 1,
    .size = @sizeOf(ZapCycleCollectCapabilityV1),
    .flags = 0,
    .vtable = @ptrCast(&cycle_vtable),
};

const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// The `.zapmem` section payload. `declared_caps == CAP_REFCOUNT_V1_BIT` (`0x1`)
/// — ORC declares **REFCOUNTED on Axis A, byte-identical to ARC**. The cycle
/// collector is advertised as the separate `CYCL` capability descriptor
/// (reachable via `get_capability_desc`), NOT an Axis-A bit — so
/// `elision.reclamationModel(declared_caps)` returns `.refcounted` and ORC
/// resolves onto ARC's codegen specialization.
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
        .init = orcInit,
        .deinit = orcDeinit,
        .allocate = orcAllocate,
        .deallocate = orcDeallocate,
        .get_capability_desc = orcGetCapabilityDesc,
    },
};

// Emit the mandatory `zap_memory_section` LINKER SYMBOL only when this manager
// is compiled as a STANDALONE OBJECT (spec §3.2). Gating on `.Obj` is what lets
// N managers (ARC, ORC, …) coexist as sibling source modules in ONE binary —
// each keeps its own `pub const` storage while NONE exports the colliding
// symbol. `.weak` is defence-in-depth for the object-linked shape.
comptime {
    if (builtin.output_mode == .Obj) {
        @export(&zap_memory_section, .{ .name = "zap_memory_section", .section = SECTION_NAME, .linkage = .weak });
    }
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface (Phase 4). Every first-party manager
// exposes the SAME `pub` names so the runtime's comptime dispatch compiles
// against a uniform shape. ORC declares REFCOUNT_V1, so every refcount alias
// resolves to a real implementation (like ARC, unlike the non-refcounted
// managers that stub them). The extra `orcRegisterCellType` / `orcCollectCycles`
// pub decls are the structural `@hasDecl`-discoverable `CYCL` surface the
// runtime uses to auto-register per-type traces under a source-registered ORC
// build.
// ---------------------------------------------------------------------------

pub const init = orcInit;
pub const deinit = orcDeinit;
pub const allocate = orcAllocate;
pub const deallocate = orcDeallocate;
pub const allocateRefcounted = orcAllocateRefcounted;
pub const retain = orcRetain;
pub const release = orcRelease;
pub const retainSized = orcRetainSized;
pub const releaseSized = orcReleaseSized;
pub const refcountSized = orcRefcountSized;
pub const detachRegion = orcDetachRegion;
pub const adoptRegion = orcAdoptRegion;
pub const freeDetachedRegion = orcFreeDetachedRegion;
pub const getCapabilityDesc = orcGetCapabilityDesc;

/// The `CYCL` capability's per-type registration, exposed for the runtime's
/// source-registered auto-registration path and for tests.
pub const registerCellType = orcRegisterCellType;

/// The `CYCL` capability's collection trigger, exposed for the yield-point /
/// teardown wiring and for tests.
pub const collectCycles = orcCollectCycles;

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
    const FreeDetachedRegionFn = *const fn (object: *anyopaque) callconv(.c) void;

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
    _ = @as(FreeDetachedRegionFn, freeDetachedRegion);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// Read the number of side-table cells currently live (test observability).
fn testLiveSideCells(ctx: *OrcContext) usize {
    return ctx.side_table.count();
}

/// Tear down and ASSERT leak-exactness: a cell not reclaimed (an uncollected
/// cycle, a missing free) surfaces as `.leak` from the backing allocator and
/// panics the test. This is the leak-exactness oracle every ORC test runs via
/// `defer`, so it fires on the success path AND any early failure path.
fn testDeinitAssertClean(ctx_opaque: *anyopaque) void {
    if (orcDeinitInner(ctx_opaque) != .ok) {
        @panic("orc: leak detected at teardown — a cell was not reclaimed");
    }
}

/// Test-only teardown that SKIPS the final cycle collection and returns the
/// backing allocator's LIVE-byte count — the negative control proving the
/// Bacon–Rajan collector is load-bearing. It tears down the bookkeeping maps
/// (drawn from `meta`, kept out of `gpa`'s accounting) and destroys the context
/// exactly like `orcDeinitInner`, but deliberately does NOT run
/// `collectCyclesImpl`. A dropped-but-uncollected cycle's cells are therefore
/// never reclaimed and remain live in `gpa`, so `total_requested_bytes` is
/// non-zero — the ARC-alone-leaks half of the proof (ARC's refcounts never reach
/// zero for a cycle). The live-byte counter (`enable_memory_limit`) is the leak
/// oracle here rather than `gpa.deinit() == .leak`, because `deinit`'s leak
/// detection emits `log.err`, which the Zig test runner counts as a failure even
/// for a DELIBERATE leak — so we read the counter, then `deinitWithoutLeakChecks`
/// returns every backing page to the OS with NO leak report (the per-process
/// leak-exactness contract still holds — nothing leaks to the OS; only the
/// accounting witnesses the un-reclaimed cells).
fn testLiveHeapBytesSkipCollect(ctx_opaque: *anyopaque) usize {
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    // NOTE: no `collectCyclesImpl(ctx)` here — that omission IS the control.
    const live_bytes = ctx.gpa.total_requested_bytes;
    ctx.roots.deinit(ctx.meta);
    ctx.buffered.deinit(ctx.meta);
    ctx.color.deinit(ctx.meta);
    ctx.descriptors.deinit(ctx.meta);
    ctx.side_table.deinit(ctx.meta);
    ctx.gpa.deinitWithoutLeakChecks();
    std.heap.page_allocator.destroy(ctx);
    return live_bytes;
}

test "orc: allocate_refcounted / retain_sized / release_sized round-trips like ARC" {
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));

    const mem = orcAllocateRefcounted(ctx_opaque, 64, 8) orelse return error.OutOfMemory;
    try testing.expectEqual(@as(u32, 1), orcRefcountSized(ctx_opaque, mem, 64, 8));
    orcRetainSized(ctx_opaque, mem, 64, 8);
    try testing.expectEqual(@as(u32, 2), orcRefcountSized(ctx_opaque, mem, 64, 8));
    orcReleaseSized(ctx_opaque, mem, 64, 8, null);
    try testing.expectEqual(@as(u32, 1), orcRefcountSized(ctx_opaque, mem, 64, 8));
    try testing.expectEqual(@as(usize, 1), testLiveSideCells(ctx));
    // Final release → prompt ARC-fast-path free (no cycle, no buffering).
    orcReleaseSized(ctx_opaque, mem, 64, 8, null);
    try testing.expectEqual(@as(usize, 0), testLiveSideCells(ctx));
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);

    testDeinitAssertClean(ctx_opaque);
}

test "orc: inline-header retain/release match ARC atomics on the offset-0 refcount" {
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));

    // Inline-header cell: a 4-byte refcount at offset 0 (as codegen lays out
    // Map/List/MapIter). Allocate via core.allocate and initialise rc = 1.
    const cell = orcAllocate(ctx_opaque, 16, 8) orelse return error.OutOfMemory;
    const rc: *u32 = @ptrCast(@alignCast(cell));
    rc.* = 1;

    orcRetain(ctx_opaque, cell);
    try testing.expectEqual(@as(u32, 2), rc.*);
    // deep_walk == null (a flat leaf): a non-zero decrement must NOT buffer.
    orcRelease(ctx_opaque, cell, null);
    try testing.expectEqual(@as(u32, 1), rc.*);
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);

    // The runtime frees inline cells through deep_walk; here we free the raw
    // cell directly to keep the test self-contained and leak-exact.
    orcDeallocate(ctx_opaque, @ptrCast(cell), 16, 8);
    testDeinitAssertClean(ctx_opaque);
}

// --- Cycle-collection proof --------------------------------------------------
//
// A self-contained inline-header cell type used to build genuine reference
// cycles through the ORC ABI. Layout: a 4-byte refcount at offset 0 (the ARC
// inline-header contract) followed by two child pointers. Mutating a child
// pointer to reference an ancestor is exactly the opportunistic-mutation /
// closure cycle shape ORC exists to reclaim.
const CycleNode = extern struct {
    refcount: u32,
    _pad: u32 = 0,
    left: ?*CycleNode = null,
    right: ?*CycleNode = null,
};

/// `deep_walk` for `CycleNode`: the destructive teardown the ARC fast path
/// runs. It releases children (so acyclic graphs are torn down correctly) and
/// frees the cell. Bound per-test to the active context.
var test_active_ctx: ?*anyopaque = null;

fn cycleNodeDeepWalk(object: *anyopaque) callconv(.c) void {
    const node: *CycleNode = @ptrCast(@alignCast(object));
    const ctx = test_active_ctx.?;
    // Release children (each is an inline-header cell with the same deep_walk).
    if (node.left) |l| orcRelease(ctx, @ptrCast(l), cycleNodeDeepWalk);
    if (node.right) |r| orcRelease(ctx, @ptrCast(r), cycleNodeDeepWalk);
    // Free the cell's own storage.
    orcDeallocate(ctx, @ptrCast(object), @sizeOf(CycleNode), @alignOf(CycleNode));
}

/// Non-destructive trace for `CycleNode`: visit each child. This is what a
/// runtime `OrcTraceFnFor(CycleNode)` would generate; the collector uses it.
fn cycleNodeTrace(cell: *anyopaque, visitor_ctx: *anyopaque, visit: OrcVisitFn) callconv(.c) void {
    const node: *CycleNode = @ptrCast(@alignCast(cell));
    if (node.left) |l| visit(visitor_ctx, @ptrCast(l), cycleNodeDeepWalk);
    if (node.right) |r| visit(visitor_ctx, @ptrCast(r), cycleNodeDeepWalk);
}

fn newCycleNode(ctx_opaque: *anyopaque) !*CycleNode {
    const mem = orcAllocate(ctx_opaque, @sizeOf(CycleNode), @alignOf(CycleNode)) orelse return error.OutOfMemory;
    const node: *CycleNode = @ptrCast(@alignCast(mem));
    node.* = .{ .refcount = 1 };
    return node;
}

/// Register `CycleNode`'s cell shape with an ORC context and bind the active
/// context for `deep_walk`.
fn setupCycleType(ctx_opaque: *anyopaque) void {
    test_active_ctx = ctx_opaque;
    orcRegisterCellType(
        ctx_opaque,
        cycleNodeDeepWalk,
        cycleNodeTrace,
        @sizeOf(CycleNode),
        @alignOf(CycleNode),
        true, // inline-header refcount
        null, // self-contained: no non-cell storage to finalize
    );
}

test "orc: a self-referential cycle is collected, not leaked" {
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    defer testDeinitAssertClean(ctx_opaque);
    setupCycleType(ctx_opaque);

    // Build A -> B -> A (a two-node cycle). Each `retain` models a stored
    // reference; `orcAllocate` starts rc = 1 for the local handle.
    const a = try newCycleNode(ctx_opaque);
    const b = try newCycleNode(ctx_opaque);
    // A.right = B  (A now owns a reference to B: retain B)
    a.right = b;
    orcRetain(ctx_opaque, @ptrCast(b)); // b.rc: 1 -> 2
    // B.left = A   (B now owns a reference to A: retain A)
    b.left = a;
    orcRetain(ctx_opaque, @ptrCast(a)); // a.rc: 1 -> 2

    // Drop the two external local handles. Each decrement is to non-zero (the
    // cycle keeps them alive), so BOTH cells buffer as cycle-root candidates —
    // the hypothesis: buffering happens entirely inside `release`.
    orcRelease(ctx_opaque, @ptrCast(a), cycleNodeDeepWalk); // a.rc: 2 -> 1, buffered
    orcRelease(ctx_opaque, @ptrCast(b), cycleNodeDeepWalk); // b.rc: 2 -> 1, buffered
    try testing.expectEqual(@as(usize, 2), ctx.roots.items.len);
    try testing.expectEqual(@as(u32, 1), a.refcount);
    try testing.expectEqual(@as(u32, 1), b.refcount);

    // Collect. Trial deletion finds the cycle externally unreachable → reclaims
    // both cells. The proof is leak-exactness: with the cells freed, the
    // backing allocator's leak check at `deinit` must be clean.
    orcCollectCycles(ctx_opaque);
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.color.count());
    // deinit (via defer) asserts leak-exactness through the backing allocator.
}

test "orc: acyclic data is reclaimed promptly by the ARC base (no collector needed)" {
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    defer testDeinitAssertClean(ctx_opaque);
    setupCycleType(ctx_opaque);

    // A -> B, acyclic. A owns B.
    const a = try newCycleNode(ctx_opaque);
    const b = try newCycleNode(ctx_opaque);
    a.right = b;
    orcRetain(ctx_opaque, @ptrCast(b)); // b.rc: 1 -> 2

    // Drop b's external handle: rc 2 -> 1 (non-zero) — b has a deep_walk so it
    // buffers as a candidate, but it is NOT garbage (a still owns it).
    orcRelease(ctx_opaque, @ptrCast(b), cycleNodeDeepWalk);
    // Drop a's external handle: rc 1 -> 0 → prompt ARC teardown. deep_walk
    // releases b (b.rc 1 -> 0 → b freed too). No collector runs.
    orcRelease(ctx_opaque, @ptrCast(a), cycleNodeDeepWalk);

    // Both freed promptly by ARC; the stale candidate b is skipped at the next
    // collection (its memory is already gone). Collect to drain the buffer.
    orcCollectCycles(ctx_opaque);
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);
    // Leak-exactness asserted at deinit.
}

test "orc: a dropped two-node cycle is reclaimed by collection (positive control)" {
    // Positive control: build a cycle, drop both handles, DO collect, and prove
    // the collection reclaims it (a `.leak` at deinit would fail the oracle).
    // Its exact negative twin below runs the IDENTICAL workload but SKIPS the
    // collection and asserts the leak — together they prove ARC alone leaks the
    // cycle and the collector is what reclaims it.
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    defer testDeinitAssertClean(ctx_opaque);
    setupCycleType(ctx_opaque);

    const a = try newCycleNode(ctx_opaque);
    const b = try newCycleNode(ctx_opaque);
    a.right = b;
    orcRetain(ctx_opaque, @ptrCast(b));
    b.left = a;
    orcRetain(ctx_opaque, @ptrCast(a));
    orcRelease(ctx_opaque, @ptrCast(a), cycleNodeDeepWalk);
    orcRelease(ctx_opaque, @ptrCast(b), cycleNodeDeepWalk);

    // Before collection: both cells are still live (refcount 1 each, held only
    // by the cycle) — ARC alone can never reclaim them.
    try testing.expectEqual(@as(u32, 1), a.refcount);
    try testing.expectEqual(@as(u32, 1), b.refcount);
    try testing.expectEqual(@as(usize, 2), ctx.roots.items.len);

    // Collection reclaims the cycle; deinit's leak check confirms zero leak.
    orcCollectCycles(ctx_opaque);
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);
}

test "orc: WITHOUT collection a dropped cycle leaks — the real negative control" {
    // The negative twin of the positive control above: the IDENTICAL A <-> B
    // cycle is built and both handles dropped, but teardown SKIPS the collection
    // (`testDeinitInnerSkipCollect`). ARC's refcounts stay at 1 (the cycle holds
    // them), so the cells are NEVER reclaimed and the backing allocator's leak
    // check MUST report `.leak`. This is the load-bearing proof that the
    // Bacon–Rajan collector — not ARC — is what reclaims the cycle: run the same
    // workload through the collecting teardown and it is clean; skip the
    // collection and it leaks. (The DebugAllocator prints its leak diagnostic to
    // stderr here BY DESIGN — the named cells are the intentionally-leaked cycle.)
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    setupCycleType(ctx_opaque);

    const a = try newCycleNode(ctx_opaque);
    const b = try newCycleNode(ctx_opaque);
    a.right = b;
    orcRetain(ctx_opaque, @ptrCast(b)); // b.rc: 1 -> 2
    b.left = a;
    orcRetain(ctx_opaque, @ptrCast(a)); // a.rc: 1 -> 2
    orcRelease(ctx_opaque, @ptrCast(a), cycleNodeDeepWalk); // a: 2 -> 1
    orcRelease(ctx_opaque, @ptrCast(b), cycleNodeDeepWalk); // b: 2 -> 1

    // Both cells remain live at refcount 1, held only by the cycle — ARC can
    // never drive either to zero.
    try testing.expectEqual(@as(u32, 1), a.refcount);
    try testing.expectEqual(@as(u32, 1), b.refcount);
    try testing.expectEqual(@as(usize, 2), ctx.roots.items.len);

    // Tear down WITHOUT collecting → the un-reclaimed cycle stays live in `gpa`,
    // so the backing allocator's live-byte count is non-zero (exactly the two
    // CycleNode cells). Under the collecting teardown the positive control above
    // leaves this at 0 — the collector is what makes the difference.
    const live_bytes = testLiveHeapBytesSkipCollect(ctx_opaque);
    try testing.expect(live_bytes >= 2 * @sizeOf(CycleNode));
}

test "orc: a three-node cycle with an external reference survives (not wrongly collected)" {
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    defer testDeinitAssertClean(ctx_opaque);
    setupCycleType(ctx_opaque);

    // A -> B -> C -> A, plus a persistent EXTERNAL owner of A (an extra retain
    // never dropped). The cycle must NOT be collected — it is reachable.
    const a = try newCycleNode(ctx_opaque);
    const b = try newCycleNode(ctx_opaque);
    const c = try newCycleNode(ctx_opaque);
    a.right = b;
    orcRetain(ctx_opaque, @ptrCast(b));
    b.right = c;
    orcRetain(ctx_opaque, @ptrCast(c));
    c.right = a;
    orcRetain(ctx_opaque, @ptrCast(a));
    // Persistent external reference to A: retain once more, never released.
    orcRetain(ctx_opaque, @ptrCast(a)); // a.rc = 3 (B's ref, C's ref, external)

    // Drop the three construction-time local handles (each to non-zero).
    orcRelease(ctx_opaque, @ptrCast(a), cycleNodeDeepWalk); // a.rc 3 -> 2
    orcRelease(ctx_opaque, @ptrCast(b), cycleNodeDeepWalk); // b.rc 2 -> 1
    orcRelease(ctx_opaque, @ptrCast(c), cycleNodeDeepWalk); // c.rc 2 -> 1

    orcCollectCycles(ctx_opaque);
    // Externally reachable → trial deletion restores every refcount, nothing
    // is collected. a.rc = 2 (c.right=a plus the external owner); b.rc = 1
    // (a.right=b); c.rc = 1 (b.right=c).
    try testing.expectEqual(@as(u32, 2), a.refcount);
    try testing.expectEqual(@as(u32, 1), b.refcount);
    try testing.expectEqual(@as(u32, 1), c.refcount);

    // Tear down the external reference so the cycle becomes collectable, then
    // collect again → now reclaimed, leak-exact at deinit.
    orcRelease(ctx_opaque, @ptrCast(a), cycleNodeDeepWalk); // external drop: a.rc 2 -> 1
    orcCollectCycles(ctx_opaque);
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);
}

test "orc: a join-node cycle collects leak-exact (ScanBlack idempotence — the double-restore regression)" {
    // A JOIN NODE has two or more internal in-edges inside ONE strongly-
    // connected cycle (here `j`, reached from both `p1` and `p2`). `ScanBlack`
    // repaints an externally-reachable cycle black and RESTORES the trial
    // decrements `MarkGray` applied. Its iterative worklist pushes a node once
    // per in-edge; without a top-of-loop `black` guard a join node is popped
    // twice and restores its child's refcount TWICE, permanently inflating a
    // downstream cell so the cycle can never be reclaimed. `markGray`/`scan`
    // already carry that guard; `scanBlack` must too.
    //
    // Repro shape: R -> P1 -> {J, P2}, P2 -> J, J -> R. An external reference on
    // R keeps the whole SCC alive across a FIRST collection, forcing the
    // `ScanBlack` survivor path over the join node. The stack discipline pushes
    // J (via P1) BELOW P2, so P2 is popped first and pushes J a SECOND time
    // before J's first pop — the exact double-push the guard absorbs. Dropping
    // the external reference and collecting again must then reclaim the whole
    // cycle leak-exact; with the bug R stays over-inflated and the SCC leaks
    // (the backing-allocator oracle at deinit panics).
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    const ctx: *OrcContext = @ptrCast(@alignCast(ctx_opaque));
    defer testDeinitAssertClean(ctx_opaque);
    setupCycleType(ctx_opaque);

    const r = try newCycleNode(ctx_opaque);
    const p1 = try newCycleNode(ctx_opaque);
    const p2 = try newCycleNode(ctx_opaque);
    const j = try newCycleNode(ctx_opaque);

    r.right = p1;
    orcRetain(ctx_opaque, @ptrCast(p1)); // p1.rc: 1 -> 2
    p1.left = j;
    orcRetain(ctx_opaque, @ptrCast(j)); // j.rc: 1 -> 2
    p1.right = p2;
    orcRetain(ctx_opaque, @ptrCast(p2)); // p2.rc: 1 -> 2
    p2.right = j;
    orcRetain(ctx_opaque, @ptrCast(j)); // j.rc: 2 -> 3 (join node: in-edges from P1 and P2)
    j.right = r;
    orcRetain(ctx_opaque, @ptrCast(r)); // r.rc: 1 -> 2 (back-edge closes the cycle)

    // Persistent EXTERNAL owner of R, dropped only AFTER the first collection.
    orcRetain(ctx_opaque, @ptrCast(r)); // r.rc: 2 -> 3

    // Drop the four construction-time local handles (each to non-zero → buffers).
    orcRelease(ctx_opaque, @ptrCast(r), cycleNodeDeepWalk); // r: 3 -> 2
    orcRelease(ctx_opaque, @ptrCast(p1), cycleNodeDeepWalk); // p1: 2 -> 1
    orcRelease(ctx_opaque, @ptrCast(p2), cycleNodeDeepWalk); // p2: 2 -> 1
    orcRelease(ctx_opaque, @ptrCast(j), cycleNodeDeepWalk); // j: 3 -> 2
    try testing.expectEqual(@as(usize, 4), ctx.roots.items.len);

    // First collection: R is externally reachable, so trial deletion restores
    // the whole SCC via ScanBlack (which traverses the join node). A CORRECT
    // ScanBlack restores each cell to its post-handle-drop count; the buggy
    // double-restore over-inflates R (2 -> 3), which this assertion catches.
    orcCollectCycles(ctx_opaque);
    try testing.expectEqual(@as(u32, 2), r.refcount);
    try testing.expectEqual(@as(u32, 1), p1.refcount);
    try testing.expectEqual(@as(u32, 1), p2.refcount);
    try testing.expectEqual(@as(u32, 2), j.refcount);

    // Drop the external reference — the SCC is now unreachable and collectable.
    orcRelease(ctx_opaque, @ptrCast(r), cycleNodeDeepWalk); // r: 2 -> 1
    orcCollectCycles(ctx_opaque);
    try testing.expectEqual(@as(usize, 0), ctx.roots.items.len);
    // deinit's leak oracle (via defer) asserts the whole cycle was reclaimed.
}

test "orc: zap_memory_section declares REFCOUNTED (Axis A bit 0) — the shared specialization" {
    // The static proof-of-shape behind the shares-the-REFCOUNTED-specialization
    // hypothesis: ORC's declared_caps is byte-identical to ARC's 0x1, so the
    // compiler's `elision.reclamationModel` maps it to `.refcounted` and the
    // monomorphizer keys ORC onto the SAME specialization as ARC.
    try testing.expectEqual(@as(u64, 0x1), zap_memory_section.meta.declared_caps);
    try testing.expectEqual(@as(u64, 0x1), zap_memory_section.core.declared_caps);
    try testing.expectEqual(CAP_REFCOUNT_V1_BIT, zap_memory_section.meta.declared_caps);
    // The cycle collector is a SEPARATE capability descriptor (CYCL), reachable
    // via get_capability_desc — never an Axis-A model bit.
    const ctx_opaque = orcInit(null) orelse return error.OutOfMemory;
    defer testDeinitAssertClean(ctx_opaque);
    try testing.expect(orcGetCapabilityDesc(ctx_opaque, REFC_TAG) != null);
    try testing.expect(orcGetCapabilityDesc(ctx_opaque, CYCL_TAG) != null);
}

test "orc: production SlabHeap serves slab + large allocs and wholesale teardown is leak-exact (G7)" {
    // Exercise the PRODUCTION heap directly. The manager's own `is_test` build
    // selects the DebugAllocator oracle for `BackingHeap`, so `SlabHeap` would
    // otherwise sit in the unanalysed `else` branch; instantiating it explicitly
    // proves the page-backed slab/large heap a real (`!is_test`) binary runs on
    // works — prompt individual free (the ARC fast path), a page-backed large
    // path, and leak-exact wholesale teardown (every mapped slab + large
    // allocation returned to the OS). The `test_slab_*` / `test_large_*` mmap
    // accounting is the leak oracle: at `deinit`, maps must equal unmaps.
    const mmap_before = test_slab_mmap_total;
    const unmap_before = test_slab_unmap_total;
    const large_alloc_before = test_large_alloc_total;
    const large_free_before = test_large_free_total;

    var heap: SlabHeap = .init;
    const small = heap.rawAlloc(16, 8) orelse return error.OutOfMemory; // slab class 0
    const medium = heap.rawAlloc(1024, 8) orelse return error.OutOfMemory; // a larger slab class
    const large = heap.rawAlloc(65536, 16) orelse return error.OutOfMemory; // large path

    // Prompt individual free of a slab slot and of a large allocation (the ARC
    // fast path); `medium` is left LIVE so wholesale teardown must reclaim it.
    heap.rawFree(small, 16, 8);
    heap.rawFree(large, 65536, 16);
    _ = medium;
    heap.deinit();

    // Leak-exact: every mapped slab was unmapped, every large allocation freed,
    // and both paths were actually exercised.
    try testing.expectEqual(test_slab_mmap_total - mmap_before, test_slab_unmap_total - unmap_before);
    try testing.expectEqual(test_large_alloc_total - large_alloc_before, test_large_free_total - large_free_before);
    try testing.expect(test_slab_mmap_total > mmap_before);
    try testing.expect(test_large_alloc_total > large_alloc_before);
}
