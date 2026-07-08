//! `Memory.Arena` — production whole-program arena memory manager.
//!
//! Phase 5 of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` (especially sections 4, 10, and 14) for
//! the normative contract this file implements.
//!
//! This file is the canonical first-party Arena implementation. It is
//! compiled by the Zig-fork primitive `zap_fork_compile_zig_to_object`
//! into a standalone object file that the Zap build pipeline links into
//! every Zap binary whose manifest selects `Memory.Arena`. The
//! manager declares zero capabilities (no REFCOUNT_V1) and exposes the
//! mandatory v1.0 `ZapMemoryManagerCoreV1` vtable with a real allocator
//! backing `core.allocate`.
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
//! `Memory.Arena` is a single-owner bump allocator over
//! geometrically-growing chunks obtained directly from
//! `std.heap.page_allocator`. Every `core.allocate` request is served
//! by aligning the bump cursor, bounds-checking against the current
//! chunk's end, and advancing the cursor — no atomics, no locks, no
//! per-allocation buffer-list traversal. Every `core.deallocate` is a
//! no-op because the manager reclaims its backing chunks in a single
//! bulk teardown at process exit (see `core.deinit`). The
//! whole-program-lifetime semantics match the Erlang/BEAM-style
//! "process heap" model the Arena manager is intended to approximate
//! at the binary level.
//!
//! ### Why not `std.heap.ArenaAllocator` (historical note)
//!
//! Through the Phase 5 rollout this manager wrapped Zig 0.16's
//! `std.heap.ArenaAllocator` (backed by `page_allocator`). The 0.16
//! stdlib arena is lock-free via atomic linked-list operations on its
//! `used_list` / `free_list` chains and per-node `end_index` bumps
//! (see `lib/std/heap/ArenaAllocator.zig` in the pinned fork —
//! `loadFirstNode`, `tryPushNode`, `stealFreeList`, `pushFreeList`,
//! and the `@atomicRmw(.Add, .acquire)` on `end_index` in the alloc
//! hot path). Profiling the binarytrees benchmark (N=21, ReleaseFast)
//! under that wrapper showed ~44% of all samples inside
//! `ArenaAllocator.alloc` — an atomic RMW plus generic
//! alignment/retry logic on every 16-byte node allocation, costing
//! more than the benchmark's own make+check work combined. Zap's
//! concurrency architecture makes those atomics pure waste: managers
//! are per-process by design (BEAM-style — each process owns its
//! manager and heap exclusively; see "Thread safety" below), so the
//! cross-thread safety the stdlib arena pays for on every allocation
//! can never be exercised. The wrapper was replaced with the
//! manager-owned bump path below; chunks now come straight from
//! `page_allocator` (option (a) of the redesign: managing chunks
//! directly, rather than keeping the stdlib arena as a chunk source,
//! avoids carrying two bookkeeping structures for the same memory and
//! keeps teardown a trivial list walk).
//!
//! ### Chunk policy
//!
//! Chunks grow geometrically: the first chunk is
//! `ARENA_FIRST_CHUNK_SIZE` (64 KiB) and each refill doubles the next
//! chunk size up to `ARENA_MAX_CHUNK_SIZE` (8 MiB), so small scripts
//! reserve little and huge workloads pay a bounded, amortized-O(1)
//! refill frequency. A request too large for the standard schedule
//! gets a dedicated, exactly-sized chunk while the current bump chunk
//! keeps filling — an interleaved stream of large and small
//! allocations does not churn the bump chunk. The schedule still
//! advances on dedicated refills so a pure stream of
//! just-over-schedule requests converges onto the bump path after at
//! most `log2(ARENA_MAX_CHUNK_SIZE / ARENA_FIRST_CHUNK_SIZE)`
//! dedicated chunks. Abandoned chunk tails are never written, so they
//! cost virtual address space but no resident pages; peak RSS tracks
//! bytes actually allocated plus one chunk header per chunk.
//!
//! ### Resize / remap contract
//!
//! The core v1.0 ABI exposes exactly two allocation slots —
//! `core.allocate` and `core.deallocate` (spec section 4.2). There is
//! no resize or remap slot, and the runtime never resizes
//! manager-owned memory: the `Allocator.resize` fast paths in
//! `src/runtime.zig` (`tryArenaExtend`, used by `String.concat`)
//! operate on the runtime's own `runtime_arena`, and `List(T)` grow
//! paths reallocate through their own buffer allocator. The previous
//! `std.heap.ArenaAllocator` wrapper likewise never received resize
//! calls — the vtable had no slot to route them through — so dropping
//! the stdlib arena's last-allocation-resize support changes no
//! observable behavior.
//!
//! ### Thread safety — single-owner invariant
//!
//! **This manager is single-owner by architecture.** Zap's planned
//! concurrency model is BEAM-style per-process memory managers: each
//! process owns its manager and heap exclusively, and no arena is
//! ever shared across threads. Today the runtime spawns no threads at
//! all — `core.init` is called once from `ensureMemoryStartup` on the
//! main thread, every `core.allocate` / `core.deallocate` dispatch
//! happens on that same thread, and `core.deinit` runs once on the
//! normal-exit path (spec section 4.4). The bump path below is
//! therefore deliberately non-atomic, including the refill path: there
//! is no current call path that can reach one arena context from two
//! threads, and the future concurrency model keeps it that way by
//! construction (new process => new manager context). If a future
//! runtime change ever shared one arena context across threads it
//! would have to revisit this manager first — the module-level
//! invariant is: ONE OWNING THREAD PER `ArenaContext`, ALWAYS.
//! Spec section 4.7 carried a historical note that `Memory.Arena`
//! would wrap `ArenaAllocator` "with a mutex when called from the
//! multi-threaded allocator path"; that footnote pre-dates both the
//! 0.16 lock-free stdlib rewrite and this single-owner bump redesign,
//! and is not applicable to this implementation.
//!
//! ### No REFCOUNT_V1 capability — Phase 6 codegen elision
//!
//! Arena declares zero capabilities. The runtime's inline-header types
//! (`Map(K,V)`, `List(T)`, `String`, `MapIter`) and the generic
//! `Arc(T)` slab pool path both dispatch through the active manager's
//! REFCOUNT_V1 vtable; under Arena those dispatchers panic at the
//! entry-time capability check (see `headerRetain` / `headerRelease`
//! and `allocAny` / `releaseAny` in `src/runtime.zig`). This is the
//! correct Phase 5 behaviour per spec section 4.5 — a manager that
//! declares no `REFCOUNT_V1` can never service those calls, so the
//! runtime must trap rather than silently miscompile.
//!
//! In practice this means Phase 5 makes `Memory.Arena` usable only
//! for programs whose allocations all flow through `core.allocate`
//! (raw byte allocations from compiler-emitted code, non-refcounted
//! data structures, transient scratch). Any program that constructs a
//! `Map`, `List`, `String`, or `MapIter` under an Arena build will
//! panic on first construction.
//!
//! **Phase 6 (conditional layout + codegen elision)** is the planned
//! follow-up that closes this gap. Under a manager with no
//! REFCOUNT_V1, the compiler will:
//!
//!   1. Drop the inline `ArcHeader` from `Map` / `List` / `String` /
//!      `MapIter` cell layouts (saving 4 bytes per cell).
//!   2. Elide every retain/release call site at codegen, leaving only
//!      direct `core.allocate` calls.
//!
//! After Phase 6, an Arena build will produce a binary with zero
//! refcount overhead — exactly the design the BEAM-style process-arena
//! model promises. Until Phase 6 lands the runtime panic on
//! refcounted-type allocation is the correct, spec-conforming Phase 5
//! behaviour: nothing silently miscompiles, and the diagnostic names
//! the missing capability so users understand the constraint.
//!
//! ### Manager context lifetime
//!
//! The Arena manager allocates a small `ArenaContext` struct on
//! `std.heap.page_allocator` during `core.init` to hold the bump
//! cursor, the current chunk bound, the chunk teardown list, and the
//! geometric growth schedule. The context survives for the lifetime
//! of the process; `core.deinit` (called on the normal-exit path —
//! see spec section 4.4) walks the chunk list, returns every chunk to
//! the backing allocator, and then returns the context struct itself
//! to `page_allocator`. On abnormal-exit paths (`abort`, `panic`,
//! `std.process.exit`) the OS reclaims everything; the Arena manager
//! has no resources that require explicit cleanup beyond the chunks
//! the OS would already reclaim.
//!
//! Why `page_allocator` and not `c_allocator`? The fork primitive
//! `zap_fork_compile_zig_to_object` builds this file with
//! `link_libc = false` (see `~/projects/zig/src/zir_api.zig`'s
//! `compileToObjectImpl` — the `Compilation.Config.resolve` call
//! pins `link_libc = false` for object-mode output). `c_allocator`
//! requires libc; `page_allocator` makes a direct `mmap` syscall on
//! POSIX and `NtAllocateVirtualMemory` on Windows, neither of which
//! depends on libc startup. The previous-phase ARC manager's
//! `c_allocator` aversion documented this same constraint — Phase 5
//! follows the same pattern.

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
        "arena: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "arena: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    // Vtable structs carry pointers; their layout checks are RELATIVE
    // to `PTR` (mirroring `src/memory/abi.zig`). On 64-bit (`PTR == 8`)
    // these reduce to the original 24/56-byte layout; on wasm32 the
    // descriptors are correctly smaller.
    const PTR: usize = @sizeOf(*const anyopaque);
    if (@sizeOf(ZapCapabilityDescV1) != std.mem.alignForward(usize, 12, PTR) + PTR) @compileError(
        "arena: ZapCapabilityDescV1 size must be its integer prefix plus one pointer",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != std.mem.alignForward(usize, 16 + 5 * PTR, @alignOf(ZapMemoryManagerCoreV1))) @compileError(
        "arena: ZapMemoryManagerCoreV1 size must be its 16-byte prefix plus five pointers (aligned)",
    );

    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16 + 0 * PTR) @compileError(
        "arena: ZapMemoryManagerCoreV1.init must follow the 16-byte prefix",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 16 + 1 * PTR) @compileError(
        "arena: ZapMemoryManagerCoreV1.deinit must be the second pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 16 + 2 * PTR) @compileError(
        "arena: ZapMemoryManagerCoreV1.allocate must be the third pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 16 + 3 * PTR) @compileError(
        "arena: ZapMemoryManagerCoreV1.deallocate must be the fourth pointer slot",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 16 + 4 * PTR) @compileError(
        "arena: ZapMemoryManagerCoreV1.get_capability_desc must be the fifth pointer slot",
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

/// Arena's declared capabilities — **Axis A == BULK_OR_NEVER**.
///
/// Arena frees in bulk at `deinit`; individual frees are no-ops. In the
/// capability-axis encoding (see `src/memory/abi.zig`) BULK_OR_NEVER is bit 0
/// clear with the Axis-A field (bits 1..2) at its zero encoding — i.e.
/// `declared_caps == 0x0`. The compiler reads this and elides every
/// retain/release and individual free; no `ArcHeader` is laid out. The Zap-
/// side abi module's `CAPS_BULK_OR_NEVER` constant equals this value; this
/// manager redeclares it locally because the production-manager rule forbids
/// importing sibling compiler modules.
const CAP_DECLARED_CAPS: u64 = 0x0000_0000_0000_0000;

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
    else => @compileError("arena: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Bump-allocation chunk machinery.
//
// The Arena manager owns its chunks directly (see the "Why not
// `std.heap.ArenaAllocator`" architecture note above). The context
// struct is page-allocator-owned because the fork primitive's
// `link_libc = false` configuration forbids `c_allocator`; see the
// architecture note above for the full rationale.
// ---------------------------------------------------------------------------

/// Size of the first backing chunk. Small scripts that make only a
/// handful of `core.allocate` calls reserve a single 64 KiB chunk.
const ARENA_FIRST_CHUNK_SIZE: usize = 64 * 1024;

/// Ceiling of the geometric chunk-growth schedule. Refill frequency
/// for allocation-heavy workloads is amortized to one backing-
/// allocator call per 8 MiB of demand; untouched chunk tails cost no
/// resident pages, so a larger cap would buy nothing except virtual
/// address-space slack per chunk.
const ARENA_MAX_CHUNK_SIZE: usize = 8 * 1024 * 1024;

comptime {
    if (!std.math.isPowerOfTwo(ARENA_FIRST_CHUNK_SIZE)) @compileError(
        "arena: ARENA_FIRST_CHUNK_SIZE must be a power of two so doubling lands exactly on the cap",
    );
    if (!std.math.isPowerOfTwo(ARENA_MAX_CHUNK_SIZE)) @compileError(
        "arena: ARENA_MAX_CHUNK_SIZE must be a power of two so doubling lands exactly on the cap",
    );
    if (ARENA_FIRST_CHUNK_SIZE > ARENA_MAX_CHUNK_SIZE) @compileError(
        "arena: chunk growth schedule requires ARENA_FIRST_CHUNK_SIZE <= ARENA_MAX_CHUNK_SIZE",
    );
    if (ARENA_FIRST_CHUNK_SIZE <= @sizeOf(ChunkHeader)) @compileError(
        "arena: the first chunk must have room for payload beyond its header",
    );
}

/// Intrusive header at the base of every backing chunk. Links the
/// chunk into the context's teardown list and records the exact byte
/// length handed out by the backing allocator so `core.deinit` can
/// return it verbatim (`rawFree` requires the original length and
/// alignment).
const ChunkHeader = struct {
    /// Next chunk in the teardown list (most-recently-allocated first).
    next: ?*ChunkHeader,
    /// Total chunk length in bytes, including this header.
    size: usize,
};

/// Per-process manager state. Field order keeps the two hot-path
/// fields (`bump_cursor`, `chunk_end`) at the front of the struct so
/// the fast path touches a single cache line.
///
/// SINGLE-OWNER INVARIANT: exactly one thread may ever use an
/// `ArenaContext` — see the "Thread safety" module note. No field
/// here is atomic, deliberately.
const ArenaContext = struct {
    /// Address of the next unallocated byte in the current chunk.
    /// Always `<= chunk_end`. Starts at 0 (no chunk yet) — together
    /// with `chunk_end == 0` that makes the very first allocation
    /// take the refill path, so a process that never allocates maps
    /// no chunk at all.
    bump_cursor: usize,
    /// One-past-the-end address of the current chunk (0 before the
    /// first refill). Relies on the platform never mapping the final
    /// page of the address space, so one-past-end cannot wrap to 0 —
    /// the same assumption `std.heap.ArenaAllocator`'s node-end
    /// arithmetic makes.
    chunk_end: usize,
    /// Teardown list of every chunk this context ever allocated,
    /// including dedicated oversize chunks. Walked exactly once, by
    /// `arenaDeinit`.
    chunk_list: ?*ChunkHeader,
    /// Next standard chunk size in the geometric schedule
    /// (`ARENA_FIRST_CHUNK_SIZE` doubling to `ARENA_MAX_CHUNK_SIZE`).
    next_chunk_size: usize,
    /// Backing allocator chunks are carved from. `page_allocator` in
    /// production (`arenaInit`); injectable so the in-file unit tests
    /// can run the identical code paths against
    /// `std.testing.allocator` and inherit its leak detection. Read
    /// only on the refill, init, and teardown paths — never on the
    /// bump fast path.
    backing: std.mem.Allocator,
};

/// Create a fresh context on `backing`. Shared by the production
/// `arenaInit` (which passes `page_allocator`) and the in-file tests
/// (which pass `std.testing.allocator`); both therefore exercise the
/// exact same initialization, refill, and teardown code.
fn arenaContextCreate(backing: std.mem.Allocator) ?*ArenaContext {
    const arena_ctx = backing.create(ArenaContext) catch return null;
    arena_ctx.* = .{
        .bump_cursor = 0,
        .chunk_end = 0,
        .chunk_list = null,
        .next_chunk_size = ARENA_FIRST_CHUNK_SIZE,
        .backing = backing,
    };
    return arena_ctx;
}

/// Allocate one backing chunk of exactly `chunk_size` bytes and push
/// it onto the teardown list. The chunk is requested at
/// `ChunkHeader`'s natural alignment only; callers guarantee payload
/// alignment by reserving `alignment - 1` slack bytes in `chunk_size`
/// (see `arenaAllocateFromNewChunk`), so no backing allocator needs to
/// support over-aligned mappings.
fn arenaChunkAllocate(arena_ctx: *ArenaContext, chunk_size: usize) ?*ChunkHeader {
    const raw = arena_ctx.backing.rawAlloc(
        chunk_size,
        comptime std.mem.Alignment.of(ChunkHeader),
        @returnAddress(),
    ) orelse return null;
    const chunk: *ChunkHeader = @ptrCast(@alignCast(raw));
    chunk.* = .{
        .next = arena_ctx.chunk_list,
        .size = chunk_size,
    };
    arena_ctx.chunk_list = chunk;
    return chunk;
}

/// Refill path — the cold side of `arenaAllocate`, taken only when
/// the current chunk cannot satisfy the request. `noinline` keeps the
/// hot bump path free of the refill machinery's register pressure.
///
/// Two cases:
///
///   * Standard refill: the request fits a schedule-sized chunk. The
///     new chunk becomes the current bump chunk (abandoning the old
///     chunk's untouched tail — no resident-page cost) and the
///     schedule doubles toward `ARENA_MAX_CHUNK_SIZE`.
///   * Dedicated chunk: the request is larger than the next scheduled
///     chunk. It gets an exactly-sized chunk of its own and the
///     current bump chunk is left in place, so interleaved small
///     allocations keep packing densely. The schedule still advances
///     so a stream of just-over-schedule requests converges onto the
///     standard path (see the "Chunk policy" module note).
///
/// Returns null on backing-allocator OOM or arithmetic overflow of
/// the request bounds — the spec's documented OOM signal (§4.3.1).
noinline fn arenaAllocateFromNewChunk(
    arena_ctx: *ArenaContext,
    size: usize,
    alignment: u32,
) ?[*]u8 {
    // Worst-case bytes a fresh chunk must hold: the header, the
    // padding to reach `alignment` from any header end, and the
    // payload itself. Checked arithmetic — a pathological `size` near
    // `maxInt(usize)` must surface as OOM (null), not wrap into a
    // too-small chunk.
    const alignment_slack = @as(usize, alignment) - 1;
    const payload_worst_case = std.math.add(usize, size, alignment_slack) catch return null;
    const needed = std.math.add(usize, payload_worst_case, @sizeOf(ChunkHeader)) catch return null;

    const is_standard_refill = needed <= arena_ctx.next_chunk_size;
    const chunk_size = if (is_standard_refill) arena_ctx.next_chunk_size else needed;
    const chunk = arenaChunkAllocate(arena_ctx, chunk_size) orelse return null;
    arena_ctx.next_chunk_size = @min(arena_ctx.next_chunk_size * 2, ARENA_MAX_CHUNK_SIZE);

    const payload_base = @intFromPtr(chunk) + @sizeOf(ChunkHeader);
    const result_address = std.mem.alignForward(usize, payload_base, alignment);
    std.debug.assert(result_address + size <= @intFromPtr(chunk) + chunk_size);
    if (is_standard_refill) {
        arena_ctx.bump_cursor = result_address + size;
        arena_ctx.chunk_end = @intFromPtr(chunk) + chunk_size;
    }
    return @ptrFromInt(result_address);
}

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Allocates an `ArenaContext` on
/// `page_allocator` with an empty chunk list and returns the pointer
/// as the manager context per spec §4.2. No chunk is mapped until the
/// first allocation.
///
/// Spec §4.2 prohibits the manager from calling its own `allocate`
/// during init in a way that would trigger compiler-emitted allocation
/// paths (`Map`, `List`, `String` constructors, etc.). This manager
/// uses only `page_allocator` during init — never its own
/// `arenaAllocate` — so the prohibition is satisfied. The compiler-
/// emitted allocation surface is reached strictly post-init.
fn arenaInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const arena_ctx = arenaContextCreate(std.heap.page_allocator) orelse return null;
    return @ptrCast(arena_ctx);
}

/// Deinitialise the manager. Walks the chunk teardown list, returns
/// every chunk to the backing allocator, then returns the context
/// struct itself. Spec §4.4 declares `deinit` best-effort — it runs
/// only on the normal-main-return path — so the manager must not
/// depend on this path executing for correctness. The Arena manager
/// trivially satisfies that constraint: on abnormal exit the OS
/// reclaims every `mmap`'d chunk, so the only resource that would
/// "leak" is bookkeeping data the OS would have reclaimed anyway.
///
/// ### Thread-safety of teardown
///
/// The chunk-list walk takes no lock, consistent with the manager's
/// single-owner invariant (see the module "Thread safety" note). Spec
/// §4.4 additionally makes `deinit` a **single-threaded
/// normal-exit-only** call: the runtime invokes `core.deinit` exactly
/// once, from the main thread, after all program work has finished —
/// no concurrent `arenaAllocate` or `arenaDeallocate` can be in
/// flight when this function runs. On abnormal-exit paths (`abort`,
/// `panic`, `std.process.exit`) this function is never invoked at all
/// — the OS reclaims the `mmap`'d chunks directly.
fn arenaDeinit(ctx: *anyopaque) callconv(.c) void {
    const arena_ctx: *ArenaContext = @ptrCast(@alignCast(ctx));
    const backing = arena_ctx.backing;
    var chunk_iter = arena_ctx.chunk_list;
    while (chunk_iter) |chunk| {
        const next = chunk.next;
        const chunk_bytes: [*]u8 = @ptrCast(chunk);
        backing.rawFree(
            chunk_bytes[0..chunk.size],
            comptime std.mem.Alignment.of(ChunkHeader),
            @returnAddress(),
        );
        chunk_iter = next;
    }
    backing.destroy(arena_ctx);
}

/// Raw allocation slot — `core.allocate` (spec §4.2). The single-owner
/// bump fast path: align the cursor, bounds-check against the current
/// chunk end, advance the cursor, return. No atomics, no locks — see
/// the module "Thread safety" note for why that is sound. The cold
/// refill path (`arenaAllocateFromNewChunk`) is the only place backing
/// memory is requested.
///
/// Returning `null` on OOM matches the spec's documented signal
/// (§4.3.1) — the runtime then aborts with the OOM diagnostic. The
/// arena itself never frees the resulting pointer; bulk-free happens
/// in `arenaDeinit`.
fn arenaAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const arena_ctx: *ArenaContext = @ptrCast(@alignCast(ctx));
    // Spec §4.2 contract: `alignment` is "always a power of two and at
    // least `@alignOf(usize)`", and `size > 0`. The runtime is
    // responsible for enforcing both — papering over a contract
    // violation here would hide the bug. Assert the contract directly
    // so a regression surfaces immediately in `Debug` / `ReleaseSafe`
    // builds; both asserts compile to nothing under `ReleaseFast`, so
    // the production fast path pays for neither.
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    std.debug.assert(size > 0);
    // Padding to the next `alignment` boundary, as pure bit math:
    // `(-cursor) mod alignment`. Wrapping negation is well-defined and
    // cannot overflow, unlike `alignForward`'s `cursor + (alignment-1)`
    // form.
    const padding = (0 -% arena_ctx.bump_cursor) & (@as(usize, alignment) - 1);
    // Context invariant `bump_cursor <= chunk_end` makes this
    // subtraction safe; the saturating add keeps a pathological `size`
    // near `maxInt(usize)` from wrapping past the bound check (the
    // refill path re-validates it with checked arithmetic and reports
    // OOM).
    const available = arena_ctx.chunk_end - arena_ctx.bump_cursor;
    if (padding +| size > available) {
        @branchHint(.unlikely);
        return arenaAllocateFromNewChunk(arena_ctx, size, alignment);
    }
    const result_address = arena_ctx.bump_cursor + padding;
    arena_ctx.bump_cursor = result_address + size;
    return @ptrFromInt(result_address);
}

/// Raw deallocation slot — `core.deallocate` (spec §4.2). No-op
/// because Arena reclaims every allocation in a single bulk free at
/// `core.deinit`. Spec §4.2 explicitly endorses this pattern:
///
/// > A manager that performs no individual deallocation (e.g., a pure
/// > arena) provides a no-op implementation; the runtime still calls
/// > it for every raw block to permit accounting in diagnostic wrappers.
fn arenaDeallocate(
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

/// Capability descriptor lookup. The Arena manager declares zero
/// capabilities, so every query returns null (spec §5.5).
fn arenaGetCapabilityDesc(
    ctx: *anyopaque,
    id: u32,
) callconv(.c) ?*const ZapCapabilityDescV1 {
    _ = ctx;
    _ = id;
    return null;
}

// ---------------------------------------------------------------------------
// `.zapmem` section emission (spec §3.2)
// ---------------------------------------------------------------------------

/// Composite section payload. The meta header and core vtable are
/// wrapped in a single `extern struct` so the linker emits them in
/// declaration order as one contiguous allocation. `meta.core_vtable_offset`
/// is derived from the struct layout via `@offsetOf`, so the section
/// is always self-consistent regardless of linker behaviour. Arena
/// declares no capabilities, so `desc_count = 0` and no
/// `ZapCapabilityDescV1` fields follow `core`.
const ZapMemorySection = extern struct {
    meta: ZapMemoryManagerMetaV1,
    core: ZapMemoryManagerCoreV1,
};

/// The section payload. Kept `pub` so the Phase-4 source-registered
/// dispatch path (`runtime.zig`'s `bindSourceActiveManager`) can read it
/// directly as `active_manager.zap_memory_section`, and `@export`ed
/// (below) in non-test builds so the linker symbol the weak-extern /
/// driver path discovers is present and not dead-stripped.
///
/// **`zap_memory_section` is a MANDATORY exported symbol name for every
/// memory manager** — first-party and third-party alike. The runtime's
/// bootstrap (`src/runtime.zig`'s `externalMemorySection`) discovers the
/// payload via `@extern(?*const ExternalMemorySectionPrefix, .{ .name =
/// "zap_memory_section", .linkage = .weak })`. A manager that emits the
/// `.zapmem` section under any other symbol name (or as an unnamed
/// section payload) will produce a binary whose weak-extern resolves to
/// null at runtime, silently falling back to the built-in ARC vtable.
///
/// The driver enforces this contract at build time: see
/// `src/memory/driver.zig`'s post-link symbol check (`assertExportsManagerSymbol`).
/// Spec section 3.2 + section 10.5 codify the requirement; this comment
/// pins the implementation-side invariant in source.
pub const zap_memory_section: ZapMemorySection = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = CAP_DECLARED_CAPS, // Axis A == BULK_OR_NEVER (0x0).
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = CAP_DECLARED_CAPS,
        .init = arenaInit,
        .deinit = arenaDeinit,
        .allocate = arenaAllocate,
        .deallocate = arenaDeallocate,
        .get_capability_desc = arenaGetCapabilityDesc,
    },
};

// Emit the mandatory `zap_memory_section` LINKER SYMBOL only in non-test
// builds. (The `pub const` above always stays visible as a Zig decl — see
// below — so this gates ONLY the exported symbol, not the value.)
//
// `zap_memory_section` is a MANDATORY exported symbol (spec §3.2): the
// runtime's `externalMemorySection` discovers it via a weak `@extern`, and
// the driver's post-link check (`assertExportsManagerSymbol`) enforces its
// presence in every standalone-compiled manager object. Production manager
// objects are built by `zap_fork_compile_zig_to_object`, which is never a
// test build, so the symbol is always present where the contract requires it.
//
// The value must ALSO remain a `pub const` decl unconditionally: the Phase-4
// source-registered dispatch path (`runtime.zig`'s `bindSourceActiveManager`)
// reads it directly as `active_manager.zap_memory_section` via `@hasDecl` —
// a Zig-decl access, NOT the linker symbol — so a user binary that registers
// this manager as its active source needs the decl regardless of `export`.
//
// Emission is gated on `builtin.output_mode == .Obj` — a standalone-object
// compile (the driver's validation object + object-linked hosts), the only
// contexts that read the section through the linker symbol. In a compiler-driven
// `.Exe`/`.Lib` the manager is a sibling SOURCE MODULE bound via its decl
// (`@import("...").zap_memory_section`), so it must NOT emit the colliding
// symbol — this is what lets Arena coexist with the manifest manager (and any
// other per-spawn manager) as sibling modules in ONE binary
// (docs/memory-manager-abi.md §10.5). It also subsumes the old `!is_test` gate
// (a test binary is an `.Exe`). See `src/memory/arc/manager.zig` for the full
// rationale. `.linkage = .weak` + `.section` are retained as before.
comptime {
    if (builtin.output_mode == .Obj) {
        @export(&zap_memory_section, .{ .name = "zap_memory_section", .section = SECTION_NAME, .linkage = .weak });
    }
}

// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs (Phase 4)
//
// Arena declares zero capabilities (`declared_caps = 0`) — it does NOT
// implement REFCOUNT_V1. The runtime's Phase 6 codegen elides every
// retain/release call site under a manager that omits the capability,
// so the stubs below are never invoked in practice. They exist solely
// to give the uniform first-party manager interface a complete set of
// symbols: Phase 4's comptime dispatch in `src/runtime.zig` calls into
// `@import("zap_active_manager").<fn>(...)` through the same alias
// surface for every first-party manager, and a missing symbol would
// break the user-binary compile even though codegen would never emit
// a call to it.
//
// Each stub `@panic`s with a diagnostic that names the manager and the
// missing capability — if a future runtime regression somehow bypasses
// codegen elision and reaches one of these, the panic surfaces the
// bug immediately at the call site rather than masking it as a typed
// pointer dereference into uninitialised vtable bytes.
// ---------------------------------------------------------------------------

fn arenaRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn arenaReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn arenaRetainSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn arenaReleaseSizedStub(
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
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn arenaAllocateRefcountedStub(
    ctx: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn arenaRefcountSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
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
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.Arena does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface (Phase 4)
//
// See the matching section in `src/memory/arc/manager.zig` for the full
// rationale. Every first-party manager exposes the same set of `pub`
// names so the runtime's comptime dispatch can call into the active
// manager's hot paths through `@import("zap_active_manager")` uniformly.
// ---------------------------------------------------------------------------

pub const init = arenaInit;
pub const deinit = arenaDeinit;
pub const allocate = arenaAllocate;
pub const deallocate = arenaDeallocate;
pub const allocateRefcounted = arenaAllocateRefcountedStub;
pub const retain = arenaRetainStub;
pub const release = arenaReleaseStub;
pub const retainSized = arenaRetainSizedStub;
pub const releaseSized = arenaReleaseSizedStub;
pub const refcountSized = arenaRefcountSizedStub;
pub const getCapabilityDesc = arenaGetCapabilityDesc;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock
//
// `Memory.Arena` does NOT declare REFCOUNT_V1, so the refcount
// aliases above point at panic-stub bodies. The bodies are never
// invoked (the runtime's comptime dispatch elides those call sites
// under no-REFCOUNT_V1 builds), but the panic-stub signatures still
// MUST match the canonical AbiV1 slot types because the runtime
// source compiles uniformly across both first-party and third-party
// builds — the type system has to validate the shape of every alias,
// not just the ones that get reached at runtime. Pinning each alias
// against its canonical slot type at module scope catches drift at
// the manager build site rather than at user-binary link time.
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
// In-file behavioural tests — bump-allocation logic.
//
// Aggregated into `zig build test` via `src/root.zig`'s first-party
// manager import block (mirroring the Tracking / ARC / GC managers).
// Every test drives the real vtable functions (`arenaAllocate`,
// `arenaDeallocate`, `arenaDeinit`) against a context whose backing
// allocator is `std.testing.allocator`, so the production init /
// refill / teardown code paths run verbatim and the testing
// allocator's leak detection proves `arenaDeinit` returns every chunk
// AND the context struct — a leaked chunk fails the test run.
// ---------------------------------------------------------------------------

/// Count the chunks currently linked into the context's teardown list.
fn testCountChunks(arena_ctx: *const ArenaContext) usize {
    var count: usize = 0;
    var chunk_iter = arena_ctx.chunk_list;
    while (chunk_iter) |chunk| : (chunk_iter = chunk.next) count += 1;
    return count;
}

test "arenaAllocate returns pointers honoring every supported alignment" {
    const arena_ctx = arenaContextCreate(std.testing.allocator) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);

    const alignments = [_]u32{ 8, 16, 32, 64, 128, 256, 512, 1024, 4096 };
    const sizes = [_]usize{ 1, 3, 8, 17, 64 };
    for (alignments) |alignment| {
        for (sizes) |size| {
            const ptr = arenaAllocate(ctx, size, alignment) orelse return error.OutOfMemory;
            try std.testing.expectEqual(
                @as(usize, 0),
                @intFromPtr(ptr) % @as(usize, alignment),
            );
            // The returned block must be writable end to end.
            @memset(ptr[0..size], 0xAB);
        }
    }
}

test "arenaAllocate serves non-overlapping writable blocks across chunk refills" {
    const arena_ctx = arenaContextCreate(std.testing.allocator) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);

    // Allocate far more than the first chunk holds so several refills
    // occur, filling each block with a distinct byte pattern.
    const block_size: usize = 4096;
    const block_count: usize = (ARENA_FIRST_CHUNK_SIZE * 8) / block_size;
    var blocks: [block_count][*]u8 = undefined;
    for (0..block_count) |block_index| {
        const ptr = arenaAllocate(ctx, block_size, 8) orelse return error.OutOfMemory;
        @memset(ptr[0..block_size], @truncate(block_index));
        blocks[block_index] = ptr;
    }
    try std.testing.expect(testCountChunks(arena_ctx) > 1);
    // Every earlier block's pattern must have survived every later
    // allocation — any bump-cursor overlap corrupts a predecessor.
    for (blocks, 0..) |ptr, block_index| {
        const expected_byte: u8 = @truncate(block_index);
        for (ptr[0..block_size]) |actual_byte| {
            try std.testing.expectEqual(expected_byte, actual_byte);
        }
    }
}

test "arena chunk sizes grow geometrically and cap at ARENA_MAX_CHUNK_SIZE" {
    const arena_ctx = arenaContextCreate(std.testing.allocator) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);

    // Doubling from 64 KiB reaches the 8 MiB cap after 7 refills;
    // drive enough standard refills to observe the cap twice.
    const doubling_steps = comptime std.math.log2(ARENA_MAX_CHUNK_SIZE / ARENA_FIRST_CHUNK_SIZE);
    const target_chunk_count = comptime doubling_steps + 3;
    const block_size: usize = 32 * 1024;
    var iterations: usize = 0;
    while (testCountChunks(arena_ctx) < target_chunk_count) : (iterations += 1) {
        try std.testing.expect(iterations < 4096);
        _ = arenaAllocate(ctx, block_size, 8) orelse return error.OutOfMemory;
    }

    // The teardown list is newest-first; collect and reverse to get
    // allocation order.
    var chunk_sizes: [target_chunk_count]usize = undefined;
    var chunk_iter = arena_ctx.chunk_list;
    var reverse_index: usize = target_chunk_count;
    while (chunk_iter) |chunk| : (chunk_iter = chunk.next) {
        reverse_index -= 1;
        chunk_sizes[reverse_index] = chunk.size;
    }
    try std.testing.expectEqual(@as(usize, 0), reverse_index);

    var expected_size: usize = ARENA_FIRST_CHUNK_SIZE;
    for (chunk_sizes) |chunk_size| {
        try std.testing.expectEqual(expected_size, chunk_size);
        try std.testing.expect(chunk_size <= ARENA_MAX_CHUNK_SIZE);
        expected_size = @min(expected_size * 2, ARENA_MAX_CHUNK_SIZE);
    }
}

test "oversized requests get dedicated chunks and preserve the bump chunk" {
    const arena_ctx = arenaContextCreate(std.testing.allocator) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);

    const first_small = arenaAllocate(ctx, 16, 8) orelse return error.OutOfMemory;
    const schedule_after_first = arena_ctx.next_chunk_size;
    const chunks_after_first = testCountChunks(arena_ctx);

    // Larger than the next scheduled chunk => dedicated, exactly-sized
    // chunk; the bump cursor must not move to it.
    const oversized_request = schedule_after_first * 2;
    const cursor_before_oversized = arena_ctx.bump_cursor;
    const oversized_ptr = arenaAllocate(ctx, oversized_request, 8) orelse return error.OutOfMemory;
    @memset(oversized_ptr[0..oversized_request], 0xCD);
    try std.testing.expectEqual(cursor_before_oversized, arena_ctx.bump_cursor);
    try std.testing.expectEqual(chunks_after_first + 1, testCountChunks(arena_ctx));
    // The dedicated chunk (newest in the teardown list) is sized for
    // exactly this request: header + alignment slack + payload.
    const dedicated_chunk = arena_ctx.chunk_list.?;
    try std.testing.expectEqual(
        @sizeOf(ChunkHeader) + @as(usize, 7) + oversized_request,
        dedicated_chunk.size,
    );

    // A subsequent small allocation continues bump-packing immediately
    // after the first one, inside the original chunk.
    const second_small = arenaAllocate(ctx, 16, 8) orelse return error.OutOfMemory;
    try std.testing.expectEqual(@intFromPtr(first_small) + 16, @intFromPtr(second_small));
}

test "arenaDeallocate is a no-op and never invalidates prior allocations" {
    const arena_ctx = arenaContextCreate(std.testing.allocator) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);

    const ptr = arenaAllocate(ctx, 64, 8) orelse return error.OutOfMemory;
    @memset(ptr[0..64], 0x5A);
    arenaDeallocate(ctx, ptr, 64, 8);
    // BULK_OR_NEVER: the block stays live and untouched after the
    // (accounting-only) deallocate call, and later allocations must
    // not reuse it before deinit.
    const later = arenaAllocate(ctx, 64, 8) orelse return error.OutOfMemory;
    try std.testing.expect(@intFromPtr(later) != @intFromPtr(ptr));
    for (ptr[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0x5A), byte);
}

test "arenaAllocate reports OOM as null when the backing allocator fails" {
    // fail_index = 1: the context struct itself allocates fine, the
    // first chunk request fails — the spec's null OOM signal must
    // surface instead of a panic.
    var failing_backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const arena_ctx = arenaContextCreate(failing_backing.allocator()) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);
    try std.testing.expectEqual(@as(?[*]u8, null), arenaAllocate(ctx, 16, 8));
}

test "arenaAllocate reports pathological size overflow as null" {
    const arena_ctx = arenaContextCreate(std.testing.allocator) orelse return error.OutOfMemory;
    defer arenaDeinit(@ptrCast(arena_ctx));
    const ctx: *anyopaque = @ptrCast(arena_ctx);
    // `size + alignment slack + header` overflows usize; the checked
    // refill arithmetic must classify that as OOM (null), never wrap
    // into a too-small chunk.
    try std.testing.expectEqual(
        @as(?[*]u8, null),
        arenaAllocate(ctx, std.math.maxInt(usize) - 4, 8),
    );
}
