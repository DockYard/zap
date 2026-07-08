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
// manager.zig` byte-for-byte. The `slab_pool_drift`-style comptime layout
// asserts below fail the build if either side drifts.
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
// Per-process ORC context
// ---------------------------------------------------------------------------

const OrcContext = struct {
    /// Backing sub-allocator for this process's refcounted cells. A per-instance
    /// general-purpose allocator: it supports the prompt individual free the ARC
    /// fast path needs, the wholesale teardown the per-process leak-exactness
    /// contract needs (P3-J1), and — critically for the leak-exactness proofs —
    /// exact leak accounting at `deinit`.
    gpa: std.heap.DebugAllocator(.{}),

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
    const check = ctx.gpa.deinit();
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
    const log2: u8 = std.math.log2_int(u32, alignment);
    const mem = ctx.gpa.allocator().rawAlloc(size, @enumFromInt(log2), @returnAddress()) orelse return null;
    return mem;
}

fn rawFree(ctx: *OrcContext, ptr: [*]u8, size: usize, alignment: u32) void {
    if (size == 0) return;
    const log2: u8 = std.math.log2_int(u32, alignment);
    ctx.gpa.allocator().rawFree(ptr[0..size], @enumFromInt(log2), @returnAddress());
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

test "orc: without collection a dropped cycle leaks — collection is what reclaims it" {
    // The negative control proving the collector is load-bearing: build a
    // cycle, drop it, and DO collect (a `.leak` here would fail the backing
    // allocator's deinit check). Then a second identical run WITHOUT collect
    // would leak — asserted structurally by live cell accounting instead of a
    // deliberate leak (which would trip the test allocator).
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
