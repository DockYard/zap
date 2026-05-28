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
//! captured at `init`, which the runtime calls from the entry-point prologue
//! (`memoryStartupForEntry`) — the highest frame — or, in the lazy-fallback
//! runtime, at the first allocation. Either is a sound upper bound because the
//! stack grows toward lower addresses on every supported target, so every later
//! frame lives below the captured bottom. At collection time the collector
//! flushes callee-saved registers to a stack-resident buffer and scans: the
//! flushed registers, the live stack span `[current SP, stack_bottom)`, and the
//! global `__DATA`/bss segments.
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
//! are rare). Multi-threaded and precise/generational collection are tracked as
//! future enhancements on the same TRACED capability.

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
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "gc: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "gc: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "gc: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "gc: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "gc: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "gc: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "gc: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
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
    16,   32,   48,   64,    96,    128,  192,
    256,  384,  512,  768,   1024,  1536, 2048,
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

/// Mach-O: ld64 synthesises segment-boundary symbols on demand. A symbol named
/// `segment$start$__DATA` / `segment$end$__DATA` resolves to the inclusive start
/// and exclusive end of the `__DATA` segment (see ld64's `$start$`/`$end$`
/// linker-synthesised symbol feature). These names are not valid Zig
/// identifiers, so they are bound via `@extern` with an explicit `.name`.
/// Scanning the whole `__DATA` segment is the conservative superset of `__data`
/// + `__bss` + `__common` — every mutable global in one range.
fn scanMachoGlobals(ctx: *GcContext) void {
    const seg_start = @extern(*const u8, .{ .name = "segment$start$__DATA" });
    const seg_end = @extern(*const u8, .{ .name = "segment$end$__DATA" });
    scanRange(ctx, @intFromPtr(seg_start), @intFromPtr(seg_end));
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
/// `approx_sp` is the caller's stack pointer (the top of the live stack span);
/// `collect` is always invoked from `allocate`, so `approx_sp` is taken there
/// via `@frameAddress()` and is at a lower (or equal) address than every root
/// frame above it.
fn collect(ctx: *GcContext, approx_sp: usize) void {
    if (ctx.collecting) return; // defensive; collection never re-enters allocate
    ctx.collecting = true;
    defer ctx.collecting = false;

    // Phase 1: clear marks + sort for lookup.
    for (ctx.records.items) |*record| record.marked = false;
    ensureRecordsSorted(ctx);
    ctx.worklist.clearRetainingCapacity();

    // Phase 2: roots. Registers first (so a pointer live only in a register is
    // captured before the stack scan, which also covers spilled copies).
    var registers: RegisterBuffer = [_]usize{0} ** 32;
    flushRegisters(&registers);
    const reg_start = @intFromPtr(&registers);
    scanRange(ctx, reg_start, reg_start + @sizeOf(RegisterBuffer));

    // Live stack span: [current SP, stack_bottom). The stack grows down, so the
    // captured `stack_bottom` (highest address) is the exclusive upper bound and
    // `approx_sp` (lowest live address) is the inclusive lower bound.
    if (ctx.stack_bottom > approx_sp) {
        scanRange(ctx, approx_sp, ctx.stack_bottom);
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
/// stack bottom** from this frame's address.
///
/// `init` is invoked by the runtime's startup prologue (`memoryStartupForEntry`,
/// called from the compiler-emitted entry in `main`) before any user allocation,
/// or — in the lazy-fallback runtime — at the first allocation. Either site is a
/// frame at a higher (or equal) stack address than every subsequent allocation
/// frame, so `@frameAddress()` here is a sound upper bound for the live stack
/// span scanned at every later collection. Spec §4.2 forbids a manager from
/// triggering compiler-emitted allocation during `init`; this manager only uses
/// `page_allocator` here, satisfying the constraint.
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
        // The frame address of `init` is the deepest frame guaranteed to sit
        // below `main`'s prologue caller, and above every later allocation
        // frame (the stack grows down).
        .stack_bottom = @frameAddress(),
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
/// The collection's stack-span upper bound is `stack_bottom`; its lower bound
/// (top of live stack) is this frame's address, captured via `@frameAddress()`.
/// Because `collect` is called from inside `gcAllocate`, every mutator frame
/// holding a live root is at an address >= this frame's, so the span
/// `[approx_sp, stack_bottom)` covers them all.
fn gcAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const gc: *GcContext = @ptrCast(@alignCast(ctx));
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));

    if (gc.live_bytes >= gc.next_collect_bytes) {
        collect(gc, @frameAddress());
    }

    if (gcHeapAlloc(gc, size, alignment)) |ptr| return ptr;

    // Allocation failed. If we have not just collected, a collection may free
    // enough to satisfy the request; try once more after a forced collection.
    collect(gc, @frameAddress());
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

/// The section payload. Exported so the linker does not dead-strip it.
///
/// **`zap_memory_section` is a MANDATORY exported symbol name for every memory
/// manager.** The runtime's bootstrap (`src/runtime.zig`'s
/// `externalMemorySection`) discovers the payload via a weak `@extern` on this
/// name; the driver enforces the contract at build time
/// (`assertExportsManagerSymbol`). GC declares the TRACED reclamation model in
/// both the meta header and the core vtable's `declared_caps`.
pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
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
