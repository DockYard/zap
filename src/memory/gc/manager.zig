//! `Memory.GC` — production conservative stop-the-world mark-sweep collector.
//!
//! Phase 5 of the capability-driven memory model (see
//! `docs/capability-driven-memory-model-plan.md`). This file is the canonical
//! first-party tracing-GC backend. It is compiled by the Zig-fork primitive
//! `zap_fork_compile_zig_to_object` into a standalone object file that the Zap
//! build pipeline links into every Zap binary whose manifest (or `-Dmemory`)
//! selects `Memory.GC`.
//!
//! Like every first-party manager backend, this file is intentionally
//! self-contained — it imports only `std` and `builtin` — because the fork
//! primitive compiles it with `link_libc = false` and accepts no Zig-package
//! dependencies (spec §11.1.1). All ABI extern shapes are redeclared locally;
//! the `comptime` size/offset asserts below tripwire any drift from the
//! canonical Zig-side definitions in `src/memory/abi.zig`.
//!
//! ## Capability: TRACED (Axis A = 0b10) — codegen reuses BULK_OR_NEVER
//!
//! The manager declares `declared_caps == 0x4` (the TRACED reclamation model).
//! From the compiler's view a TRACED build is byte-identical to a
//! BULK_OR_NEVER build: every `retain`/`release`/individual-`free` is elided,
//! no inline `ArcHeader` is laid out, and every allocation routes through this
//! manager's `core.allocate` slot. No refcount op is ever emitted or
//! dispatched — the refcount vtable slots below are `@panic` stubs that the
//! uniform first-party interface requires but codegen never reaches.
//!
//! Two language properties make a tracing collector sound with ZERO
//! garbage-collection codegen, so accepting TRACED needed no new compiler
//! emission:
//!
//!   * **Immutability ⇒ no write barriers, ever.** A heap object's outgoing
//!     pointers are fixed at construction. A tracing collector needs write
//!     barriers only to observe mutations of the object graph between
//!     collections; Zap has none, so the collector never instruments stores.
//!   * **Conservative roots ⇒ no root maps or safepoints.** The collector
//!     treats every word-aligned value on the stack, in the flushed registers,
//!     and in the global data/bss segments as a POTENTIAL pointer and pins any
//!     tracked object it lands inside (interior pointers honoured). No
//!     compiler-emitted stack map or safepoint poll is required.
//!
//! ## Collector architecture
//!
//! Single-threaded, stop-the-world, conservative mark-sweep.
//!
//! ### Managed heap
//!
//! Allocations are served from size-segregated **slabs**. A slab is a single
//! `mmap` region (`page_allocator`) carved into fixed-size cells for one size
//! class; allocations larger than the biggest class get a dedicated `mmap`
//! region (a "large object"). Every live cell is recorded in a metadata table
//! sorted by base address, so an arbitrary (possibly interior) pointer is
//! resolved to its owning object by binary search in O(log n). Freed slab
//! cells return to a per-class free list and are reused, so resident memory
//! tracks the high-water LIVE set — not the cumulative allocation count. A
//! slab whose cells all become free is unmapped, returning the pages to the
//! OS; large objects are unmapped immediately on sweep.
//!
//! ### Trigger
//!
//! `allocate` runs a full collection before satisfying a request whenever the
//! live-byte total has grown past a multiplicative threshold since the last
//! collection (`next_collect_bytes`). After a collection the threshold is reset
//! to `max(MIN_HEAP_BYTES, live_bytes * HEAP_GROWTH_NUMERATOR /
//! HEAP_GROWTH_DENOMINATOR)`, giving amortised-linear collection cost while
//! keeping a long allocate-and-drop loop bounded in resident memory.
//!
//! ### Roots
//!
//! The stack bottom (the highest stack address the program will use) is
//! captured at `init` as the **OS thread stack base** — the fixed high end of
//! the thread's mapped stack region (`pthread_get_stackaddr_np` on darwin;
//! `pthread_getattr_np` + `pthread_attr_getstack` on linux). This is the
//! nesting-independent true base: it is identical no matter which frame queries
//! it, so it covers the program's entry frame (`main`'s body) and the C-runtime
//! frames below it, even though `init` itself runs several frames BELOW `main`.
//! Capturing `init`'s own stack pointer instead (the original RT-05 defect)
//! would place the bottom below `main`'s frame and exclude every entry-frame
//! root from the scan, freeing still-live objects. At collection time the
//! collector flushes callee-saved registers to a stack-resident buffer and
//! scans: the flushed registers, the live stack span `[current SP,
//! stack_bottom)`, and the global `__DATA`/bss segments.
//!
//! ### Mark / sweep
//!
//! Marking uses an explicit worklist (never deep native recursion, which would
//! overflow on a deep object graph): each greyed object's bytes are scanned
//! word-by-word for further tracked-heap pointers. Sweep frees every tracked,
//! unmarked object and clears the marks for the next cycle.
//!
//! ### Conservatism
//!
//! Safe-by-over-retention: a non-pointer word that happens to look like a heap
//! address keeps an object alive for one extra cycle. This never frees a live
//! object — program behaviour is always correct — it can only delay
//! reclamation. `core.deallocate` is therefore a no-op; the collector owns all
//! reclamation.
//!
//! ### Platform scope (v1)
//!
//! v1 targets a single-threaded program on the host platform
//! (darwin/aarch64 and linux/x86_64 are exercised). The register flush and the
//! global-segment bounds are arch/OS-specific; unsupported targets fall back to
//! scanning only the stack (still sound — registers are flushed to the stack on
//! any normal call, and globals that hold the sole reference to a live object
//! are rare). Precise/generational collection is a future enhancement on the
//! same TRACED capability. Multi-threaded shared-heap collection is an explicit
//! NON-GOAL: Zap's concurrency direction is a BEAM-style per-process model where
//! each process owns its heap and its own memory manager and collects
//! independently — one collector instance per private heap — so cross-thread
//! root scanning / global stop-the-world is not planned.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// ABI v1.0 extern types — redeclared locally per the self-contained manager
// convention (spec §11.1.1). The `comptime` asserts below catch drift from the
// canonical Zig-side definitions in `src/memory/abi.zig`.
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
        "gc: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "gc: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    // Vtable structs carry pointers; their layout checks are RELATIVE
    // to `PTR` (mirroring `src/memory/abi.zig`). On 64-bit (`PTR == 8`)
    // these reduce to the original 24/56-byte layout. The GC backend
    // stays linkable on wasm32 (so a binary monomorphising a different
    // manager links), though SELECTING it on wasm is rejected by the
    // driver's capability gate.
    const PTR: usize = @sizeOf(*const anyopaque);
    if (@sizeOf(ZapCapabilityDescV1) != std.mem.alignForward(usize, 12, PTR) + PTR) @compileError(
        "gc: ZapCapabilityDescV1 size must be its integer prefix plus one pointer",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != std.mem.alignForward(usize, 16 + 5 * PTR, @alignOf(ZapMemoryManagerCoreV1))) @compileError(
        "gc: ZapMemoryManagerCoreV1 size must be its 16-byte prefix plus five pointers (aligned)",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16 + 0 * PTR) @compileError(
        "gc: ZapMemoryManagerCoreV1.init must follow the 16-byte prefix",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 16 + 1 * PTR) @compileError(
        "gc: ZapMemoryManagerCoreV1.deinit must be the second pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 16 + 2 * PTR) @compileError(
        "gc: ZapMemoryManagerCoreV1.allocate must be the third pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 16 + 3 * PTR) @compileError(
        "gc: ZapMemoryManagerCoreV1.deallocate must be the fourth pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 16 + 4 * PTR) @compileError(
        "gc: ZapMemoryManagerCoreV1.get_capability_desc must be the fifth pointer slot",
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

/// GC's declared capabilities — **Axis A == TRACED** (`declared_caps == 0x4`).
///
/// TRACED is bit 0 clear with the Axis-A field (bits 1..2) at the TRACED
/// encoding `0b10`, i.e. `0b10 << 1 == 0x4`. The compiler reads this, decodes
/// `ReclamationModel.traced`, and reuses the BULK_OR_NEVER codegen contract:
/// it elides every retain/release/free and lays out no `ArcHeader`. The Zap-
/// side abi module exposes the same value as
/// `(RECLAMATION_TRACED << RECLAMATION_MODEL_SHIFT)`; this backend redeclares
/// it locally because the production-manager rule forbids importing sibling
/// compiler modules.
const CAP_DECLARED_CAPS: u64 = 0x0000_0000_0000_0004;

/// Object-format-conditional section name. Mach-O places the section inside
/// the `__DATA` segment; ELF and COFF use a top-level `.zapmem` section
/// (spec §3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    // WebAssembly custom sections are named directly (no segment
    // prefix). The GC backend stays LINKABLE on wasm so a future binary
    // that monomorphises a different manager can still link this object,
    // but SELECTING the GC on wasm is rejected by the driver's
    // capability gate (`enforceManagerTargetSupport`): conservative
    // stack/global scanning is architecturally impossible on wasm's
    // linear-memory model (no raw stack, no register flush), so a
    // TRACED manager there would silently mis-collect.
    .wasm => ".zapmem",
    else => @compileError("gc: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Collector tuning constants
// ---------------------------------------------------------------------------

/// Word size used for the conservative scan stride. Roots and object interiors
/// are scanned at this granularity; a candidate pointer must be aligned to it.
const WORD = @sizeOf(usize);

/// Byte size of a slab `mmap` region. One slab serves many cells of a single
/// size class. 64 KiB amortises the syscall cost across many small objects and
/// is a multiple of every supported page size.
const SLAB_BYTES: usize = 64 * 1024;

/// Largest object served from a segregated slab. Requests above this get a
/// dedicated `mmap` region (a "large object"), unmapped immediately on sweep.
const MAX_SLAB_CLASS_BYTES: usize = 8 * 1024;

/// Minimum heap size before the first collection, and the floor for the
/// post-collection threshold. Keeps tiny programs from collecting on every
/// allocation.
const MIN_HEAP_BYTES: usize = 256 * 1024;

/// Multiplicative heap-growth threshold: after a collection the next collection
/// triggers once live bytes have grown to `live * NUM / DEN`. A 2x growth
/// factor bounds collection frequency to amortised O(1) per allocated byte.
const HEAP_GROWTH_NUMERATOR: usize = 2;
const HEAP_GROWTH_DENOMINATOR: usize = 1;

/// Segregated size classes (in bytes). A request rounds up to the smallest
/// class that fits. Chosen to balance internal fragmentation against the number
/// of classes; covers the common Zap cell sizes (List/Map/String/struct cells)
/// up to `MAX_SLAB_CLASS_BYTES`.
const SIZE_CLASSES = [_]usize{
    16,   32,   48,   64,   96,   128,  192,
    256,  384,  512,  768,  1024, 1536, 2048,
    3072, 4096, 6144, 8192,
};

comptime {
    if (SIZE_CLASSES[SIZE_CLASSES.len - 1] != MAX_SLAB_CLASS_BYTES) @compileError(
        "gc: the largest size class must equal MAX_SLAB_CLASS_BYTES",
    );
}

// ---------------------------------------------------------------------------
// Object record + interior-pointer table
// ---------------------------------------------------------------------------

/// One tracked live allocation. Records the object's `[base, base + size)`
/// interval (for interior-pointer resolution), the size CLASS index that owns
/// its slab cell (or `large_object_class` for a dedicated region), the slab the
/// cell belongs to (for free-list return), and the mark bit.
const ObjectRecord = struct {
    base: usize,
    size: usize,
    /// Index into `SIZE_CLASSES`, or `large_object_class` for a large object.
    class_index: u16,
    /// Owning slab for a slab cell; ignored for large objects.
    slab: ?*Slab,
    marked: bool,

    /// Sentinel `class_index` for a large object (dedicated `mmap` region).
    const large_object_class: u16 = std.math.maxInt(u16);
};

/// A single `mmap`'d slab serving one size class. Cells are handed out
/// sequentially from `bump` until the slab is full, after which freed cells are
/// recycled from `free_head` (an intrusive singly-linked free list threaded
/// through the first word of each free cell). `live_cells` lets sweep unmap a
/// fully-free slab.
const Slab = struct {
    /// Base address of the `mmap` region.
    base: [*]u8,
    /// Total region size (`SLAB_BYTES`).
    region_size: usize,
    /// Size class this slab serves.
    class_index: u16,
    /// Cell stride (== `SIZE_CLASSES[class_index]`).
    cell_size: usize,
    /// Number of cells the region holds.
    cell_capacity: usize,
    /// Next never-yet-allocated cell index (bump pointer).
    bump: usize,
    /// Head of the intrusive free list (recycled cells), or null.
    free_head: ?*FreeCell,
    /// Count of cells currently handed out (live or awaiting sweep).
    live_cells: usize,
    /// Intrusive list link for the manager's per-class slab chain.
    next: ?*Slab,

    const FreeCell = struct {
        next: ?*FreeCell,
    };
};

// ---------------------------------------------------------------------------
// Manager context — all collector state lives here, reached via the `ctx`
// pointer the runtime threads through every vtable call.
// ---------------------------------------------------------------------------

const GcContext = struct {
    /// Backing allocator for slabs, large objects, and bookkeeping. The fork
    /// primitive forbids `c_allocator` (no libc), so we use the page allocator,
    /// which `mmap`s directly. All reclamation returns pages here, which
    /// `munmap`s them — so freed memory is genuinely returned to the OS.
    backing: std.mem.Allocator,

    /// Per-size-class slab chains. `slabs[c]` heads the list of slabs serving
    /// class `c`; `partial[c]` points at a slab with a free cell, when known.
    slabs: [SIZE_CLASSES.len]?*Slab,
    partial: [SIZE_CLASSES.len]?*Slab,

    /// The live-object table, kept sorted by `base` for binary-search interior-
    /// pointer resolution. Owned/grown via `backing`.
    records: std.ArrayListUnmanaged(ObjectRecord),
    /// `true` when `records` is sorted by `base`. Cleared on insert (an insert
    /// appends out of order), re-established lazily before a lookup-heavy phase
    /// (the mark phase). Sweep preserves sortedness.
    records_sorted: bool,

    /// Explicit mark worklist (indices into `records`), reused across cycles to
    /// avoid per-collection allocation churn.
    worklist: std.ArrayListUnmanaged(usize),

    /// Total bytes currently tracked as live (sum of `ObjectRecord.size`).
    live_bytes: usize,
    /// Collect when `live_bytes` next reaches this threshold.
    next_collect_bytes: usize,

    /// Highest stack address the program uses (captured at `init`). The live
    /// stack span scanned at collection time is `[current SP, stack_bottom)`.
    stack_bottom: usize,

    /// Re-entrancy guard: a collection must never recurse into `allocate`
    /// (it does not, but a future bug would be caught here rather than
    /// corrupting state).
    collecting: bool,
};

// ---------------------------------------------------------------------------
// Size-class selection
// ---------------------------------------------------------------------------

/// Smallest size class index whose cell holds `size` bytes, or null when the
/// request exceeds `MAX_SLAB_CLASS_BYTES` (caller serves it as a large object).
fn classIndexForSize(size: usize) ?u16 {
    for (SIZE_CLASSES, 0..) |class_bytes, index| {
        if (size <= class_bytes) return @intCast(index);
    }
    return null;
}

// ---------------------------------------------------------------------------
// Slab management
// ---------------------------------------------------------------------------

/// Allocate a fresh slab for `class_index` from the backing allocator and push
/// it onto the class's slab chain. Returns null on OOM.
fn newSlab(ctx: *GcContext, class_index: u16) ?*Slab {
    const cell_size = SIZE_CLASSES[class_index];
    const region = ctx.backing.alignedAlloc(u8, .fromByteUnits(WORD), SLAB_BYTES) catch return null;
    const slab = ctx.backing.create(Slab) catch {
        ctx.backing.free(region);
        return null;
    };
    slab.* = .{
        .base = region.ptr,
        .region_size = SLAB_BYTES,
        .class_index = class_index,
        .cell_size = cell_size,
        .cell_capacity = SLAB_BYTES / cell_size,
        .bump = 0,
        .free_head = null,
        .live_cells = 0,
        .next = ctx.slabs[class_index],
    };
    ctx.slabs[class_index] = slab;
    ctx.partial[class_index] = slab;
    return slab;
}

/// Hand out one cell from `slab` (free list first, then bump). Caller has
/// ensured the slab has capacity. Returns the cell base pointer.
fn slabTakeCell(slab: *Slab) [*]u8 {
    if (slab.free_head) |free_cell| {
        slab.free_head = free_cell.next;
        slab.live_cells += 1;
        return @ptrCast(free_cell);
    }
    // Bump a never-allocated cell.
    const offset = slab.bump * slab.cell_size;
    slab.bump += 1;
    slab.live_cells += 1;
    return slab.base + offset;
}

/// Returns true when `slab` can satisfy another cell request without growth.
fn slabHasCapacity(slab: *Slab) bool {
    return slab.free_head != null or slab.bump < slab.cell_capacity;
}

/// Return a swept cell to its slab's free list (intrusive link in the cell's
/// first word). Decrements the slab's live-cell count so a fully-free slab can
/// be unmapped by the caller.
fn slabReturnCell(slab: *Slab, cell_base: usize) void {
    const free_cell: *Slab.FreeCell = @ptrFromInt(cell_base);
    free_cell.next = slab.free_head;
    slab.free_head = free_cell;
    slab.live_cells -= 1;
}

/// Unlink `slab` from its class chain and unmap its region + descriptor.
fn destroySlab(ctx: *GcContext, slab: *Slab) void {
    const class_index = slab.class_index;
    // Unlink from the per-class chain.
    if (ctx.slabs[class_index] == slab) {
        ctx.slabs[class_index] = slab.next;
    } else {
        var prev = ctx.slabs[class_index];
        while (prev) |p| : (prev = p.next) {
            if (p.next == slab) {
                p.next = slab.next;
                break;
            }
        }
    }
    if (ctx.partial[class_index] == slab) ctx.partial[class_index] = null;
    ctx.backing.free(slab.base[0..slab.region_size]);
    ctx.backing.destroy(slab);
}

// ---------------------------------------------------------------------------
// Object-record table
// ---------------------------------------------------------------------------

/// Append a new live object record. Marks the table unsorted (the append may be
/// out of base order); the mark phase re-sorts lazily before its lookups.
fn recordObject(ctx: *GcContext, record: ObjectRecord) bool {
    ctx.records.append(ctx.backing, record) catch return false;
    ctx.records_sorted = false;
    ctx.live_bytes += record.size;
    return true;
}

fn recordLessThan(_: void, a: ObjectRecord, b: ObjectRecord) bool {
    return a.base < b.base;
}

/// Ensure `records` is sorted by `base` so `findOwningRecord` can binary-search.
fn ensureRecordsSorted(ctx: *GcContext) void {
    if (ctx.records_sorted) return;
    std.sort.pdq(ObjectRecord, ctx.records.items, {}, recordLessThan);
    ctx.records_sorted = true;
}

/// Resolve an arbitrary (possibly interior) address to the index of the tracked
/// object whose `[base, base + size)` interval contains it, or null. Requires
/// `records` sorted (the mark phase ensures this once up front). Binary search
/// for the greatest `base <= addr`, then a containment check.
fn findOwningRecord(ctx: *const GcContext, addr: usize) ?usize {
    const items = ctx.records.items;
    var low: usize = 0;
    var high: usize = items.len;
    // Find the insertion point: first index whose base > addr.
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (items[mid].base <= addr) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    if (low == 0) return null;
    const candidate = low - 1;
    const record = items[candidate];
    if (addr >= record.base and addr < record.base + record.size) return candidate;
    return null;
}

// ---------------------------------------------------------------------------
// Conservative root + interior scanning
// ---------------------------------------------------------------------------

/// Scan a word-aligned byte range `[start, end)` for values that point into a
/// tracked object, greying each newly-discovered object onto the worklist.
/// `start`/`end` need not themselves be aligned — the scan begins at the first
/// `WORD`-aligned address at or after `start` and steps by `WORD`.
fn scanRange(ctx: *GcContext, start: usize, end: usize) void {
    if (end <= start) return;
    var addr = std.mem.alignForward(usize, start, WORD);
    while (addr + WORD <= end) : (addr += WORD) {
        const word = @as(*const usize, @ptrFromInt(addr)).*;
        if (word == 0) continue;
        if (findOwningRecord(ctx, word)) |index| {
            greyObject(ctx, index);
        }
    }
}

/// Mark object `index` reachable and push it onto the worklist if it was not
/// already marked. Marking before pushing makes the worklist a true grey set
/// (no object is pushed twice) and tolerates cyclic graphs.
fn greyObject(ctx: *GcContext, index: usize) void {
    if (ctx.records.items[index].marked) return;
    ctx.records.items[index].marked = true;
    // The worklist push cannot fail-fast the collection: if it OOMs we fall
    // back to scanning the object immediately (depth-bounded by the natural
    // recursion the worklist replaced). In practice the worklist is pre-grown
    // and reused, so this path is not taken.
    ctx.worklist.append(ctx.backing, index) catch {
        scanObjectInterior(ctx, index);
    };
}

/// Scan the interior bytes of a marked object for tracked-heap pointers,
/// greying each referent. Conservative: every word-aligned slot is treated as a
/// candidate pointer regardless of the object's actual field layout.
fn scanObjectInterior(ctx: *GcContext, index: usize) void {
    const record = ctx.records.items[index];
    scanRange(ctx, record.base, record.base + record.size);
}

/// Drain the mark worklist, scanning each greyed object's interior. This is the
/// transitive-closure mark loop; using an explicit worklist (rather than native
/// recursion) bounds stack use to O(1) regardless of object-graph depth.
fn drainWorklist(ctx: *GcContext) void {
    while (ctx.worklist.pop()) |index| {
        scanObjectInterior(ctx, index);
    }
}

// ---------------------------------------------------------------------------
// Register flush — spill callee-saved registers to a stack buffer so a heap
// pointer held only in a register is discovered by the stack/buffer scan.
// ---------------------------------------------------------------------------

/// A buffer large enough to hold the integer register file of any supported
/// target. The flush routine writes the live registers into it; the collector
/// then scans it as an additional root range. Sized generously (32 words) so it
/// covers aarch64 (x0..x30 + sp) and x86_64 (16 GPRs) with headroom.
const RegisterBuffer = [32]usize;

/// Spill the callee-saved (and, on the architectures below, all general-purpose)
/// integer registers into `buffer`. Caller passes a zeroed buffer; unused slots
/// stay zero and are skipped by the scan.
///
/// Correctness requirement: any heap pointer that is live across the collection
/// must be observable to the scan. The C calling convention guarantees
/// callee-saved registers are preserved across the `collect` call, so spilling
/// them here captures every pointer the mutator is keeping in a register.
/// Caller-saved registers holding a live pointer must, by the same convention,
/// also be live on the stack of the caller (or in a callee-saved register), so
/// the stack scan covers them. We nonetheless spill the full GPR file on the
/// supported arches for maximum conservatism.
/// Read the current stack pointer directly. Used for both stack-span bounds:
/// the stack BOTTOM (highest live address, captured at `init`) and the stack
/// TOP (lowest live address, captured inside `collect`).
///
/// `@frameAddress()` is unsuitable here: it returns the frame-pointer register,
/// which the optimiser is free to omit (`-fomit-frame-pointer`, the default
/// under `ReleaseFast`/`ReleaseSmall`), yielding a stale or wrong value. The
/// stack pointer, by contrast, is always live and accurate regardless of
/// frame-pointer elision, so reading it via inline asm gives a correct
/// conservative bound in every optimisation mode. On architectures without an
/// asm form below, the address of a stack local is used — also a true stack
/// address (it is conservative as a bound even if it omits a few words of the
/// current frame, because mutator roots live in frames above it).
inline fn currentStackPointer() usize {
    switch (builtin.target.cpu.arch) {
        .aarch64, .aarch64_be => {
            return asm volatile ("mov %[out], sp"
                : [out] "=r" (-> usize),
            );
        },
        .x86_64 => {
            return asm volatile ("movq %%rsp, %[out]"
                : [out] "=r" (-> usize),
            );
        },
        else => {
            var marker: usize = 0;
            marker = @intFromPtr(&marker);
            return marker;
        },
    }
}

// ---------------------------------------------------------------------------
// OS thread stack base (the conservative scan's stack BOTTOM)
//
// The collector's stack BOTTOM must be the highest address the program's stack
// will ever reach, so the collection-time scan span `[current SP, stack_bottom)`
// covers EVERY mutator frame — including the program's entry frame (`main`'s
// body), where a Zap `main/1` local can hold the sole live reference to a heap
// object.
//
// `init` is invoked several frames BELOW `main` (`main` →
// `memoryStartupForEntry` → `zapMemoryStartup` → indirect vtable `core.init` →
// `gcInit`), and the indirect vtable call prevents inlining in every
// optimisation mode, so `gcInit`'s own stack pointer is STRICTLY BELOW `main`'s
// frame. Capturing that nested SP as the bottom (the original defect, RT-05 /
// memory-managers--01) would exclude every entry-frame root from the scan and
// free still-live objects.
//
// The correct, nesting-independent bottom is the OS thread's stack base — the
// fixed high end of the thread's mapped stack region, identical no matter which
// frame queries it. This manager object is compiled `link_libc = false`, but it
// is linked into a final user binary built with `link_libc = true` (see
// `src/main.zig`'s `.link_libc = true`), so a libc `extern` declared here
// resolves at the final link step — exactly as `runtime.zig` declares
// `extern "c" fn atexit`. The externs and pthread types are redeclared locally
// per this file's self-contained-manager convention (the same reason the ABI
// structs above are local).
//
// GC selection is gated to ELF (linux) and Mach-O (darwin) by the driver's
// `enforceManagerTargetSupport`; both expose a reliable thread-stack-base query
// below. Any other target (and the rare case where the OS query fails) falls
// back to `currentStackPointer()`, preserving the prior behaviour rather than
// regressing — but on the GC-supported targets the OS query is authoritative.
// ---------------------------------------------------------------------------

/// Opaque pthread handle. `pthread_t` is `*opaque {}` on every libc this
/// manager targets; redeclared locally (self-contained-manager convention).
const PthreadT = *opaque {};

/// Darwin libc: returns the stack BASE — the highest address of the calling
/// thread's stack (the stack grows down from here). For the main thread this is
/// at or above the C runtime frames below `main`, hence above every Zap root.
extern "c" fn pthread_self() callconv(.c) PthreadT;
extern "c" fn pthread_get_stackaddr_np(thread: PthreadT) callconv(.c) ?*anyopaque;

/// Linux glibc: `pthread_getattr_np` fills an attribute object describing the
/// calling thread; `pthread_attr_getstack` reads the LOWEST stack address and
/// the size, so the base (highest address) is `stackaddr + stacksize`.
/// `pthread_attr_t` is an opaque blob; we redeclare a layout-compatible local
/// (56-byte payload + alignment word matches glibc's `sizeof(pthread_attr_t)`
/// on the LP64 targets GC supports).
const PthreadAttrT = extern struct {
    __size: [56]u8,
    __align: c_long,
};
extern "c" fn pthread_getattr_np(thread: PthreadT, attr: *PthreadAttrT) callconv(.c) c_int;
extern "c" fn pthread_attr_getstack(
    attr: *const PthreadAttrT,
    stackaddr: *?*anyopaque,
    stacksize: *usize,
) callconv(.c) c_int;
extern "c" fn pthread_attr_destroy(attr: *PthreadAttrT) callconv(.c) c_int;

/// Capture the conservative scan's stack BOTTOM: the highest address the
/// thread's stack reaches. Queries the OS thread stack base so the value is
/// independent of how deeply nested the calling frame is. Falls back to the
/// current SP only when no OS query is available for the target or the query
/// fails (never on the GC-supported darwin/linux targets in normal operation).
///
/// The returned address is the EXCLUSIVE upper bound of the live stack span:
/// `pthread_get_stackaddr_np` (darwin) and `stackaddr + stacksize` (linux) both
/// denote the address one-past the top of the usable stack, so scanning
/// `[SP, base)` reads only mapped, live stack words and never past the region.
fn currentStackBase() usize {
    switch (builtin.target.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Darwin returns the base (high end) directly.
            const base = pthread_get_stackaddr_np(pthread_self());
            if (base) |ptr| {
                const base_addr = @intFromPtr(ptr);
                // Sanity: the base must be at or above this frame's SP (stack
                // grows down). If a future libc ever returned the low end
                // instead, fall back rather than scan a backwards range.
                if (base_addr >= currentStackPointer()) return base_addr;
            }
            return currentStackPointer();
        },
        .linux => {
            var attr: PthreadAttrT = undefined;
            if (pthread_getattr_np(pthread_self(), &attr) != 0) {
                return currentStackPointer();
            }
            defer _ = pthread_attr_destroy(&attr);
            var stackaddr: ?*anyopaque = null;
            var stacksize: usize = 0;
            if (pthread_attr_getstack(&attr, &stackaddr, &stacksize) != 0) {
                return currentStackPointer();
            }
            if (stackaddr) |low| {
                // glibc reports the LOWEST stack address; the base is the high
                // end. Use checked addition so a malformed (size, addr) pair
                // can never wrap to a small bottom that would truncate the scan.
                const low_addr = @intFromPtr(low);
                const sum = @addWithOverflow(low_addr, stacksize);
                if (sum[1] == 0 and sum[0] >= currentStackPointer()) return sum[0];
            }
            return currentStackPointer();
        },
        else => return currentStackPointer(),
    }
}

inline fn flushRegisters(buffer: *RegisterBuffer) void {
    switch (builtin.target.cpu.arch) {
        .aarch64, .aarch64_be => {
            // Store x0..x29 (the GPRs excluding the platform/zero/sp encodings)
            // as 15 consecutive register pairs into the buffer. `stp` writes a
            // pair; the base register is updated by `, #16` post-index.
            asm volatile (
                \\stp x0,  x1,  [%[buf], #0]
                \\stp x2,  x3,  [%[buf], #16]
                \\stp x4,  x5,  [%[buf], #32]
                \\stp x6,  x7,  [%[buf], #48]
                \\stp x8,  x9,  [%[buf], #64]
                \\stp x10, x11, [%[buf], #80]
                \\stp x12, x13, [%[buf], #96]
                \\stp x14, x15, [%[buf], #112]
                \\stp x16, x17, [%[buf], #128]
                \\stp x18, x19, [%[buf], #144]
                \\stp x20, x21, [%[buf], #160]
                \\stp x22, x23, [%[buf], #176]
                \\stp x24, x25, [%[buf], #192]
                \\stp x26, x27, [%[buf], #208]
                \\stp x28, x29, [%[buf], #224]
                :
                : [buf] "r" (buffer),
                : .{ .memory = true });
        },
        .x86_64 => {
            asm volatile (
                \\movq %%rax, 0(%[buf])
                \\movq %%rbx, 8(%[buf])
                \\movq %%rcx, 16(%[buf])
                \\movq %%rdx, 24(%[buf])
                \\movq %%rsi, 32(%[buf])
                \\movq %%rdi, 40(%[buf])
                \\movq %%rbp, 48(%[buf])
                \\movq %%r8,  56(%[buf])
                \\movq %%r9,  64(%[buf])
                \\movq %%r10, 72(%[buf])
                \\movq %%r11, 80(%[buf])
                \\movq %%r12, 88(%[buf])
                \\movq %%r13, 96(%[buf])
                \\movq %%r14, 104(%[buf])
                \\movq %%r15, 112(%[buf])
                :
                : [buf] "r" (buffer),
                : .{ .memory = true });
        },
        else => {
            // Unsupported arch: rely on the stack scan alone. Any pointer held
            // only in a register and nowhere on the stack would be missed, but
            // the normal C calling convention spills live values across calls,
            // so this is sound for the common case and is documented as a v1
            // platform limitation.
        },
    }
}

// ---------------------------------------------------------------------------
// Global (data + bss) segment bounds
// ---------------------------------------------------------------------------

/// Scan the program's global mutable segments (initialised data + bss) for
/// roots. A Zap global that holds the sole reference to a heap object must be
/// scanned so that object is not reclaimed. The segment bounds are platform-
/// specific; unsupported platforms skip this scan (sound: such globals are rare
/// and, in immutable Zap, a global referencing a heap object is itself reached
/// through the stack root that constructed it in the common case).
fn scanGlobals(ctx: *GcContext) void {
    switch (builtin.target.ofmt) {
        .macho => scanMachoGlobals(ctx),
        .elf => scanElfGlobals(ctx),
        else => {},
    }
}

/// The main executable's Mach-O header. The static linker always emits this
/// symbol for the main executable image (it is not a libc symbol), so it is
/// available in a `link_libc = false` manager object. We walk its load commands
/// at collection time to find the writable segments to scan for roots.
extern const _mh_execute_header: std.macho.mach_header_64;

/// Mach-O: walk the main executable's load commands and scan every **writable**
/// segment (the conservative superset of `__DATA`, `__DATA_DIRTY`, bss, and
/// `__common` — every mutable global). Read-only segments (`__TEXT`,
/// `__DATA_CONST`, `__LINKEDIT`) are skipped: an immutable global there cannot
/// hold a runtime-assigned heap pointer.
///
/// Each segment's load-command `vmaddr` is the *static* (pre-ASLR) address; the
/// runtime address is `vmaddr + slide`, where `slide` is the ASLR displacement
/// of the loaded image. We recover `slide` from the `__TEXT` segment, whose
/// `vmaddr` corresponds to the runtime address of the mach header itself.
fn scanMachoGlobals(ctx: *GcContext) void {
    const header = &_mh_execute_header;
    if (header.magic != std.macho.MH_MAGIC_64) return;

    // The load commands follow the header contiguously in memory.
    const header_addr = @intFromPtr(header);
    var command_addr = header_addr + @sizeOf(std.macho.mach_header_64);

    // Load commands are emitted with 1-byte alignment relative to the header,
    // so each command is read through an `align(1)` pointer and copied to a
    // naturally-aligned local before its fields are used.

    // First pass: recover the ASLR slide from the __TEXT segment.
    var slide: usize = 0;
    {
        var cursor = command_addr;
        var index: u32 = 0;
        while (index < header.ncmds) : (index += 1) {
            const lc = (@as(*align(1) const std.macho.load_command, @ptrFromInt(cursor))).*;
            if (lc.cmd == .SEGMENT_64) {
                const seg = (@as(*align(1) const std.macho.segment_command_64, @ptrFromInt(cursor))).*;
                if (segmentNameEquals(seg.segname, "__TEXT")) {
                    slide = header_addr -% @as(usize, @intCast(seg.vmaddr));
                    break;
                }
            }
            cursor += lc.cmdsize;
        }
    }

    // Second pass: scan every writable segment's live range.
    var index: u32 = 0;
    while (index < header.ncmds) : (index += 1) {
        const lc = (@as(*align(1) const std.macho.load_command, @ptrFromInt(command_addr))).*;
        if (lc.cmd == .SEGMENT_64) {
            const seg = (@as(*align(1) const std.macho.segment_command_64, @ptrFromInt(command_addr))).*;
            // A segment is mutable when its initial VM protection grants write
            // access. (We read the `initprot.WRITE` bit directly rather than via
            // `segment_command_64.isWriteable`, whose body references a
            // lower-cased field name absent from this std revision's
            // `vm_prot_t`.)
            if (seg.initprot.WRITE and seg.vmsize > 0) {
                const start = @as(usize, @intCast(seg.vmaddr)) +% slide;
                const end = start +% @as(usize, @intCast(seg.vmsize));
                scanRange(ctx, start, end);
            }
        }
        command_addr += lc.cmdsize;
    }
}

/// Compare a fixed-width Mach-O `segname` (NUL-padded 16-byte field) to a
/// name literal. Mach-O segment names are at most 16 bytes and NUL-padded; a
/// match requires every byte of `name` to be present and the field to be NUL
/// (or end) immediately after.
fn segmentNameEquals(segname: [16]u8, name: []const u8) bool {
    if (name.len > segname.len) return false;
    for (name, 0..) |byte, i| {
        if (segname[i] != byte) return false;
    }
    return name.len == segname.len or segname[name.len] == 0;
}

/// ELF: `__data_start` bounds the start of the initialised data section and
/// `_end` bounds the end of bss; both are provided by the standard crt/linker.
/// We scan `[__data_start, _end)` as the conservative superset of the mutable-
/// global ranges (initialised data + bss).
fn scanElfGlobals(ctx: *GcContext) void {
    const data_start = @extern(*const u8, .{ .name = "__data_start" });
    const end = @extern(*const u8, .{ .name = "_end" });
    scanRange(ctx, @intFromPtr(data_start), @intFromPtr(end));
}

// ---------------------------------------------------------------------------
// Stop-the-world collection
// ---------------------------------------------------------------------------

/// Run one full stop-the-world conservative mark-sweep collection.
///
/// Phases:
///   1. Clear all marks; sort the record table for O(log n) interior lookups.
///   2. Flush registers; scan registers, the live stack span, and globals for
///      roots (greying each discovered object).
///   3. Drain the worklist (transitive mark).
///   4. Sweep: free every unmarked object back to its slab / unmap large
///      objects, compacting the record table in place (preserving sort order).
///   5. Reset the next-collection threshold from the surviving live bytes.
///
/// The collector captures the live stack TOP (lowest live address) itself via
/// `currentStackPointer()` at entry, rather than trusting a frame address from
/// the caller — `@frameAddress()` is unreliable under frame-pointer elision
/// (the default in `ReleaseFast`). Every mutator frame holding a root sits at a
/// higher address than this frame's SP (the stack grows down through
/// `gcAllocate` → `collect`), so scanning `[sp, stack_bottom)` covers them all.
fn collect(ctx: *GcContext) void {
    if (ctx.collecting) return; // defensive; collection never re-enters allocate
    ctx.collecting = true;
    defer ctx.collecting = false;

    // Capture the live stack top FIRST, before any helper-call frame is pushed,
    // so the scanned span includes every mutator frame and this frame's spills.
    const stack_top = currentStackPointer();

    // Phase 1: clear marks + sort for lookup.
    for (ctx.records.items) |*record| record.marked = false;
    ensureRecordsSorted(ctx);
    ctx.worklist.clearRetainingCapacity();

    // Phase 2: roots. Registers first (so a pointer live only in a register is
    // captured before the stack scan, which also covers spilled copies). The
    // mutator's callee-saved registers are preserved across the call into
    // `collect`, so flushing here captures them; caller-saved registers holding
    // a live root were spilled to the mutator stack (covered by the stack scan).
    var registers: RegisterBuffer = [_]usize{0} ** 32;
    flushRegisters(&registers);
    const reg_start = @intFromPtr(&registers);
    scanRange(ctx, reg_start, reg_start + @sizeOf(RegisterBuffer));

    // Live stack span: [stack_top, stack_bottom). The stack grows down, so the
    // captured `stack_bottom` (highest address) is the exclusive upper bound and
    // `stack_top` (this frame's SP, the lowest live address) is the inclusive
    // lower bound.
    if (ctx.stack_bottom > stack_top) {
        scanRange(ctx, stack_top, ctx.stack_bottom);
    }

    // Globals (mutable data + bss).
    scanGlobals(ctx);

    // Phase 3: transitive mark.
    drainWorklist(ctx);

    // Phase 4: sweep. Walk the (sorted) record table; free unmarked objects and
    // keep marked ones, compacting in place so the table stays sorted and dense.
    var write_index: usize = 0;
    var read_index: usize = 0;
    while (read_index < ctx.records.items.len) : (read_index += 1) {
        const record = ctx.records.items[read_index];
        if (record.marked) {
            ctx.records.items[write_index] = record;
            write_index += 1;
        } else {
            freeObject(ctx, record);
            ctx.live_bytes -= record.size;
        }
    }
    ctx.records.shrinkRetainingCapacity(write_index);
    // Sweep preserved relative order, so the table is still sorted by base.
    ctx.records_sorted = true;

    // Phase 5: reset the growth threshold from the surviving live set.
    setNextCollectThreshold(ctx);
}

/// Return one swept object's storage to the heap: a slab cell goes back on its
/// slab's free list (and the slab is unmapped if it becomes wholly free); a
/// large object's dedicated region is unmapped immediately.
fn freeObject(ctx: *GcContext, record: ObjectRecord) void {
    if (record.class_index == ObjectRecord.large_object_class) {
        const ptr: [*]u8 = @ptrFromInt(record.base);
        ctx.backing.free(ptr[0..record.size]);
        return;
    }
    const slab = record.slab.?;
    slabReturnCell(slab, record.base);
    // Make a freshly-freed slab the preferred partial for fast reuse.
    ctx.partial[slab.class_index] = slab;
    if (slab.live_cells == 0) destroySlab(ctx, slab);
}

/// Set `next_collect_bytes` to `max(MIN_HEAP_BYTES, live * NUM / DEN)`,
/// saturating the multiply so an enormous live set never wraps the threshold to
/// a small value (which would force a collection on every allocation).
fn setNextCollectThreshold(ctx: *GcContext) void {
    const product = @mulWithOverflow(ctx.live_bytes, HEAP_GROWTH_NUMERATOR);
    const grown: usize = if (product[1] != 0) std.math.maxInt(usize) else product[0];
    const threshold = grown / HEAP_GROWTH_DENOMINATOR;
    ctx.next_collect_bytes = @max(MIN_HEAP_BYTES, threshold);
}

// ---------------------------------------------------------------------------
// Allocation
// ---------------------------------------------------------------------------

/// Serve `size` bytes (at least `WORD`-aligned cell granularity) from the GC
/// heap, recording the object as live. A slab cell for the rounded size class,
/// or a dedicated large-object region above `MAX_SLAB_CLASS_BYTES`. Returns the
/// cell base, or null on OOM (after one collection attempt).
fn gcHeapAlloc(ctx: *GcContext, size: usize, alignment: u32) ?[*]u8 {
    if (classIndexForSize(size)) |class_index| {
        // The slab cell base is `WORD`-aligned (the region is `WORD`-aligned and
        // cell sizes are word multiples). The runtime never requests an
        // alignment stronger than the cell's natural alignment for these small
        // cells; assert that holds so a stronger request is not silently
        // mis-served. Stronger alignments fall through to the large-object path.
        if (SIZE_CLASSES[class_index] % alignment == 0 or alignment <= WORD) {
            const slab = pickSlabForClass(ctx, class_index) orelse return null;
            const cell = slabTakeCell(slab);
            if (!recordObject(ctx, .{
                .base = @intFromPtr(cell),
                .size = SIZE_CLASSES[class_index],
                .class_index = class_index,
                .slab = slab,
                .marked = false,
            })) {
                // Record-table OOM: return the cell so the slab stays consistent.
                slabReturnCell(slab, @intFromPtr(cell));
                if (slab.live_cells == 0) destroySlab(ctx, slab);
                return null;
            }
            return cell;
        }
    }
    return largeObjectAlloc(ctx, size, alignment);
}

/// Pick a slab for `class_index` that has a free cell, allocating a new slab if
/// the cached partial is full. Returns null on OOM.
fn pickSlabForClass(ctx: *GcContext, class_index: u16) ?*Slab {
    if (ctx.partial[class_index]) |slab| {
        if (slabHasCapacity(slab)) return slab;
    }
    // Search the chain for any slab with capacity.
    var node = ctx.slabs[class_index];
    while (node) |slab| : (node = slab.next) {
        if (slabHasCapacity(slab)) {
            ctx.partial[class_index] = slab;
            return slab;
        }
    }
    return newSlab(ctx, class_index);
}

/// Serve a request larger than `MAX_SLAB_CLASS_BYTES` (or with an alignment a
/// slab cell cannot satisfy) from its own `mmap` region, recorded as a large
/// object. Swept large objects are unmapped immediately.
fn largeObjectAlloc(ctx: *GcContext, size: usize, alignment: u32) ?[*]u8 {
    const region_alignment: std.mem.Alignment = .fromByteUnits(@max(alignment, WORD));
    const region = ctx.backing.rawAlloc(size, region_alignment, @returnAddress()) orelse return null;
    if (!recordObject(ctx, .{
        .base = @intFromPtr(region),
        .size = size,
        .class_index = ObjectRecord.large_object_class,
        .slab = null,
        .marked = false,
    })) {
        ctx.backing.rawFree(region[0..size], region_alignment, @returnAddress());
        return null;
    }
    return region;
}

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Allocates a `GcContext` on `page_allocator`,
/// initialises empty slab chains and the record table, and **captures the
/// stack bottom** as the OS thread stack base (`currentStackBase`).
///
/// `init` is invoked by the runtime's startup prologue (`memoryStartupForEntry`,
/// called from the compiler-emitted entry in `main`) before any user
/// allocation, or — in the lazy-fallback runtime — at the first allocation. In
/// BOTH cases `init` runs several frames BELOW `main` (through the indirect
/// `core.init` vtable call, which never inlines), so this frame's stack pointer
/// is strictly below `main`'s frame. The stack bottom must therefore be the OS
/// thread stack base — the fixed high end of the thread's stack, at or above
/// every frame including `main` — not this frame's SP (the original RT-05
/// defect, which excluded entry-frame roots from the scan). `currentStackBase`
/// reads the base via the platform pthread query and is independent of init
/// nesting. Spec §4.2 forbids a manager from triggering compiler-emitted
/// allocation during `init`; this manager only uses `page_allocator` and a
/// pthread stack-base query here, satisfying the constraint.
fn gcInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const backing = std.heap.page_allocator;
    const ctx = backing.create(GcContext) catch return null;
    ctx.* = .{
        .backing = backing,
        .slabs = [_]?*Slab{null} ** SIZE_CLASSES.len,
        .partial = [_]?*Slab{null} ** SIZE_CLASSES.len,
        .records = .empty,
        .records_sorted = true,
        .worklist = .empty,
        .live_bytes = 0,
        .next_collect_bytes = MIN_HEAP_BYTES,
        // Capture the stack bottom: the highest address the live stack reaches.
        //
        // This MUST be the OS thread stack base, NOT this frame's SP. `gcInit`
        // runs several frames BELOW the program's entry (`main` →
        // `memoryStartupForEntry` → `zapMemoryStartup` → indirect vtable
        // `core.init` → `gcInit`), and the indirect vtable call prevents
        // inlining in every optimisation mode, so this frame's SP is strictly
        // below `main`'s frame. Capturing the SP here (the original RT-05
        // defect) excluded every entry-frame root from the scan span
        // `[current SP, stack_bottom)` and freed still-live objects. The OS
        // thread base is the fixed high end of the thread's stack — at or above
        // every frame including `main` — so the scan covers all roots
        // regardless of init nesting. (`currentStackBase` falls back to the SP
        // only on targets with no OS query / on query failure, never on the
        // GC-supported darwin/linux targets in normal operation.)
        .stack_bottom = currentStackBase(),
        .collecting = false,
    };
    return @ptrCast(ctx);
}

/// Deinitialise the manager. Unmaps every slab and large object, frees the
/// bookkeeping arrays, and returns the context struct to `page_allocator`.
/// Spec §4.4 makes `deinit` best-effort (normal-exit only); on abnormal exit
/// the OS reclaims every `mmap`'d region. The collector therefore needs no
/// explicit cleanup for correctness beyond what the OS already does — this path
/// exists so a normal-exit run returns to a clean slate (and so leak-checking
/// tools see the manager's own allocations released).
fn gcDeinit(ctx: *anyopaque) callconv(.c) void {
    const gc: *GcContext = @ptrCast(@alignCast(ctx));
    // Unmap large objects.
    for (gc.records.items) |record| {
        if (record.class_index == ObjectRecord.large_object_class) {
            const ptr: [*]u8 = @ptrFromInt(record.base);
            gc.backing.free(ptr[0..record.size]);
        }
    }
    // Unmap every slab in every class chain.
    for (gc.slabs) |head| {
        var node = head;
        while (node) |slab| {
            const next = slab.next;
            gc.backing.free(slab.base[0..slab.region_size]);
            gc.backing.destroy(slab);
            node = next;
        }
    }
    gc.records.deinit(gc.backing);
    gc.worklist.deinit(gc.backing);
    gc.backing.destroy(gc);
}

/// Raw allocation slot — `core.allocate` (spec §4.2). Runs a collection first
/// when the live-byte total has crossed the growth threshold, then serves the
/// request from the GC heap and records it as live.
///
/// `collect` captures the live stack span bounds itself (reading the stack
/// pointer directly), so it needs no frame hint from this caller. Because it is
/// called from inside `gcAllocate`, every mutator frame holding a live root sits
/// at a higher address than the collector frame's SP, so the scanned span
/// `[stack_top, stack_bottom)` covers them all.
fn gcAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const gc: *GcContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));

    if (gc.live_bytes >= gc.next_collect_bytes) {
        collect(gc);
    }

    if (gcHeapAlloc(gc, size, alignment)) |ptr| return ptr;

    // Allocation failed. If we have not just collected, a collection may free
    // enough to satisfy the request; try once more after a forced collection.
    collect(gc);
    return gcHeapAlloc(gc, size, alignment);
}

/// Raw deallocation slot — `core.deallocate` (spec §4.2). No-op: the collector
/// owns all reclamation. Spec §4.2 explicitly endorses a no-op deallocate for a
/// manager that reclaims by another mechanism; the runtime still calls it for
/// every raw block to permit accounting in diagnostic wrappers.
fn gcDeallocate(ctx: *anyopaque, ptr: [*]u8, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = ptr;
    _ = size;
    _ = alignment;
}

/// Capability descriptor lookup. GC declares no REFCOUNT_V1 capability (its
/// reclamation is tracing, not refcounting), so every query returns null
/// (spec §5.5).
fn gcGetCapabilityDesc(ctx: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
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

/// The section payload. Kept `pub` so the source-registered dispatch path
/// (`runtime.zig`'s `bindSourceActiveManager`) can read it directly as
/// `active_manager.zap_memory_section`, and `@export`ed (below) in non-test
/// builds so the linker symbol the weak-extern/driver path discovers is
/// present and not dead-stripped.
///
/// **`zap_memory_section` is a MANDATORY exported symbol name for every memory
/// manager.** The runtime's bootstrap (`src/runtime.zig`'s
/// `externalMemorySection`) discovers the payload via a weak `@extern` on this
/// name; the driver enforces the contract at build time
/// (`assertExportsManagerSymbol`). GC declares the TRACED reclamation model in
/// both the meta header and the core vtable's `declared_caps`.
pub const zap_memory_section: ZapMemorySection = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_DECLARED_CAPS, // Axis A == TRACED (0x4).
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_DECLARED_CAPS,
        .init = gcInit,
        .deinit = gcDeinit,
        .allocate = gcAllocate,
        .deallocate = gcDeallocate,
        .get_capability_desc = gcGetCapabilityDesc,
    },
};

// Emit the mandatory `zap_memory_section` LINKER SYMBOL only in non-test
// builds. (The `pub const` above always stays visible as a Zig decl, so this
// gates ONLY the exported symbol, not the value.)
//
// `zap_memory_section` is a MANDATORY exported symbol (spec §3.2): the
// runtime's `externalMemorySection` discovers it via a weak `@extern`, and the
// driver's post-link check (`assertExportsManagerSymbol`) enforces its presence
// in every standalone-compiled manager object. Production manager objects are
// built by `zap_fork_compile_zig_to_object`, which is never a test build, so
// the symbol is always present where the contract requires it.
//
// Emission is gated on `builtin.output_mode == .Obj` — a standalone-object
// compile (the driver's validation object + object-linked hosts), the only
// readers of the linker symbol. In a compiler-driven `.Exe`/`.Lib`, GC is bound
// via its sibling-module decl (`active_manager.zap_memory_section`), so it must
// not emit the colliding symbol; gating on `.Obj` lets N managers coexist as
// sibling modules in one binary (manifest + per-spawn `zap_spawn_manager_*`,
// docs/memory-manager-abi.md §10.5) and subsumes the old `!is_test` gate (a test
// binary is an `.Exe`). See `src/memory/arc/manager.zig` for the full rationale.
// `.section` reproduces the prior `linksection(SECTION_NAME)` byte-for-byte.
comptime {
    if (builtin.output_mode == .Obj) {
        @export(&zap_memory_section, .{ .name = "zap_memory_section", .section = SECTION_NAME, .linkage = .weak });
    }
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs.
//
// GC declares no REFCOUNT_V1 capability — TRACED reuses the BULK_OR_NEVER
// codegen, which elides every retain/release/free, so these stubs are never
// invoked. They exist solely to give the uniform first-party manager interface
// a complete set of symbols: the runtime's comptime dispatch calls into
// `@import("zap_active_manager").<fn>` through the same alias surface for every
// first-party manager, and a missing symbol would break the user-binary
// compile even though codegen would never emit a call to it. Each stub
// `@panic`s with a diagnostic that names the manager and the missing capability
// so a hypothetical regression that bypassed codegen elision surfaces the bug
// at the call site.
// ---------------------------------------------------------------------------

fn gcRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn gcReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn gcRetainSizedStub(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn gcReleaseSizedStub(
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
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn gcAllocateRefcountedStub(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn gcRefcountSizedStub(ctx: *anyopaque, object: *anyopaque, size: usize, alignment: u32) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
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
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.GC does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface.
//
// Every first-party manager exposes the same set of `pub` names so the
// runtime's comptime dispatch can call into the active manager's hot paths
// through `@import("zap_active_manager")` uniformly. See the matching section
// in `src/memory/arena/manager.zig` for the full rationale.
// ---------------------------------------------------------------------------

pub const init = gcInit;
pub const deinit = gcDeinit;
pub const allocate = gcAllocate;
pub const deallocate = gcDeallocate;
pub const allocateRefcounted = gcAllocateRefcountedStub;
pub const retain = gcRetainStub;
pub const release = gcReleaseStub;
pub const retainSized = gcRetainSizedStub;
pub const releaseSized = gcReleaseSizedStub;
pub const refcountSized = gcRefcountSizedStub;
pub const getCapabilityDesc = gcGetCapabilityDesc;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock
//
// `Memory.GC` does NOT declare REFCOUNT_V1, so the refcount aliases point at
// panic-stub bodies. The bodies are never invoked (codegen elides those call
// sites under TRACED ≡ BULK_OR_NEVER), but the signatures still MUST match the
// canonical AbiV1 slot types because the runtime source compiles uniformly
// across first-party and third-party builds. Pinning each alias against its
// canonical slot type at module scope catches drift at the manager build site
// rather than at user-binary link time.
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

// ---------------------------------------------------------------------------
// Tests — conservative stack-base capture (memory-managers--01 / RT-05)
//
// These run host-side under `zig build test`: `src/root.zig` aggregates this
// manager (its `zap_memory_section` export is gated behind `!builtin.is_test`,
// so it does not collide with the ARC/Tracking managers in the same binary).
// They exercise the real `gcInit`/`gcAllocate`/`collect` paths on the host
// target (darwin/aarch64 and linux/x86_64 are the exercised, GC-supported
// targets).
// ---------------------------------------------------------------------------

/// Call `gcInit` through a non-inlined boundary so the manager's init frame is
/// pushed strictly BELOW the caller's frame on the (downward-growing) stack,
/// reproducing the real startup nesting (`main` → `memoryStartupForEntry` →
/// `zapMemoryStartup` → vtable `core.init` → `gcInit`). Without the boundary an
/// optimiser could inline `gcInit` into the test frame, equalising the two
/// stack pointers and masking the defect.
fn initThroughNestedFrame() ?*GcContext {
    const raw = gcInit(null) orelse return null;
    return @ptrCast(@alignCast(raw));
}

test "gcInit captures a stack bottom that covers the caller's entry frame" {
    // A heap root lives in THIS frame (the stand-in for a `main/1` local that
    // holds the only live reference to a heap object). The conservative scan
    // span is `[current SP, stack_bottom)`; for this root to be scanned (and
    // the object it points at kept alive), the captured `stack_bottom` must be
    // at an address >= this local's address.
    var entry_frame_root: usize = 0xA5A5_A5A5_A5A5_A5A5;
    // Force the local to be a real, address-taken stack slot the optimiser
    // cannot fold into a register or constant.
    const entry_frame_root_addr = @intFromPtr(&entry_frame_root);
    std.mem.doNotOptimizeAway(&entry_frame_root);

    const ctx = initThroughNestedFrame() orelse return error.GcInitReturnedNull;
    defer gcDeinit(@ptrCast(ctx));

    // The defect (RT-05): `stack_bottom` was captured as `gcInit`'s own SP,
    // which — because `gcInit` runs in a frame BELOW this one — is a LOWER
    // address than `entry_frame_root_addr`. That excluded this frame's roots
    // from `[SP, stack_bottom)`, so an entry-frame-only heap reference was
    // swept while live (use-after-free). The fix captures the true OS thread
    // stack base (the highest live address), which is at or above every frame
    // including this one and the `main` frame above it.
    try std.testing.expect(ctx.stack_bottom >= entry_frame_root_addr);

    // The captured bottom must also be a plausible stack address: at or above
    // the current SP (the stack grows down, so the bottom is the high end).
    try std.testing.expect(ctx.stack_bottom >= currentStackPointer());
}

test "conservative scan keeps an object referenced only from the caller's frame alive across a forced collection" {
    // End-to-end witness: allocate a heap object, keep its ONLY live reference
    // in this (entry-stand-in) frame, force enough allocation to cross the
    // collection threshold, and assert the object's storage was not reclaimed.
    //
    // Pre-fix, with `stack_bottom` below this frame, the reference word here is
    // outside `[SP, stack_bottom)` and the object is swept; the record table no
    // longer contains it. Post-fix the scan covers this frame, so the object
    // survives. (Conservative scanning can also incidentally find the pointer
    // in a register or a lower frame, so this test is a positive witness that
    // complements the deterministic base-capture assertion above.)
    const ctx = initThroughNestedFrame() orelse return error.GcInitReturnedNull;
    defer gcDeinit(@ptrCast(ctx));

    // Allocate one tracked object and write a recognisable pattern into it. Its
    // address is the sole live root we keep in this frame.
    const live = gcAllocate(@ptrCast(ctx), 64, @alignOf(usize)) orelse return error.AllocFailed;
    const live_words: [*]usize = @ptrCast(@alignCast(live));
    live_words[0] = 0xC0FFEE_1234_5678;
    const live_addr = @intFromPtr(live);
    std.mem.doNotOptimizeAway(live);

    // Lower the threshold so a modest amount of churn forces a real collection
    // without allocating hundreds of KiB in the test.
    ctx.next_collect_bytes = 0;

    // Churn: allocate-and-drop many objects whose references do NOT survive,
    // each crossing the (now-zero) threshold so `gcAllocate` runs `collect`.
    // The churned objects are unreachable and should be swept; `live` must not.
    var churn: usize = 0;
    while (churn < 256) : (churn += 1) {
        const tmp = gcAllocate(@ptrCast(ctx), 64, @alignOf(usize)) orelse return error.AllocFailed;
        // Immediately forget `tmp` — no live reference is retained.
        std.mem.doNotOptimizeAway(tmp);
        ctx.next_collect_bytes = 0;
    }

    // Run one final explicit collection for good measure.
    collect(ctx);

    // The live object's record must still be present (it was kept alive by the
    // conservative scan finding `live_addr` on this frame's stack) and its
    // payload intact.
    try std.testing.expect(findOwningRecord(ctx, live_addr) != null);
    try std.testing.expectEqual(@as(usize, 0xC0FFEE_1234_5678), live_words[0]);
}
