//! `Zap.Memory.Arena` — production whole-program arena memory manager.
//!
//! Phase 5 of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` (especially sections 4, 10, and 14) for
//! the normative contract this file implements.
//!
//! This file is the canonical first-party Arena implementation. It is
//! compiled by the Zig-fork primitive `zap_fork_compile_zig_to_object`
//! into a standalone object file that the Zap build pipeline links into
//! every Zap binary whose manifest selects `Zap.Memory.Arena`. The
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
//! `Zap.Memory.Arena` wraps Zig 0.16's `std.heap.ArenaAllocator` backed
//! by `std.heap.page_allocator`. Every `core.allocate` request is
//! served from the wrapped arena; every `core.deallocate` is a no-op
//! because the arena reclaims its backing storage in a single bulk
//! free at process exit (see `core.deinit`). The whole-program-lifetime
//! semantics match the Erlang/BEAM-style "process heap" model the Arena
//! manager is intended to approximate at the binary level.
//!
//! ### Thread safety
//!
//! Zig 0.16 made `std.heap.ArenaAllocator` lock-free via atomic
//! linked-list operations on its `used_list` / `free_list` chains and
//! per-node `end_index` bumps (see `lib/std/heap/ArenaAllocator.zig` in
//! the pinned fork — `loadFirstNode`, `tryPushNode`, `stealFreeList`,
//! `pushFreeList`, and the `@atomicRmw(.Add, .acquire)` on `end_index`
//! in the alloc hot path). The manager therefore needs no external
//! mutex: `core.allocate` and `core.deallocate` are safe under any
//! degree of multi-threaded contention. Spec section 4.7 carried a
//! historical note that `Zap.Memory.Arena` would wrap `ArenaAllocator`
//! "with a mutex when called from the multi-threaded allocator path";
//! that footnote pre-dates the 0.16 lock-free rewrite and is no longer
//! applicable to this implementation.
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
//! In practice this means Phase 5 makes `Zap.Memory.Arena` usable only
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
//! `std.heap.page_allocator` during `core.init` to hold the
//! `std.heap.ArenaAllocator` state. The context survives for the
//! lifetime of the process; `core.deinit` (called on the normal-exit
//! path — see spec section 4.4) destroys the arena's backing chunks
//! via `arena.deinit()` and then returns the context struct itself to
//! `page_allocator`. On abnormal-exit paths (`abort`, `panic`,
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
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "arena: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "arena: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );

    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "arena: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "arena: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "arena: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "arena: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "arena: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
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

/// Object-format-conditional section name. Mach-O places the section
/// inside the `__DATA` segment; ELF and COFF use a top-level
/// `.zapmem` section (spec §3.1).
const SECTION_NAME = switch (builtin.target.ofmt) {
    .elf => ".zapmem",
    .macho => "__DATA,__zapmem",
    .coff => ".zapmem",
    else => @compileError("arena: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Manager context.
//
// The Arena manager holds a live `std.heap.ArenaAllocator` for the
// lifetime of the process. The context struct is page-allocator-owned
// because the fork primitive's `link_libc = false` configuration
// forbids `c_allocator`; see the architecture note above for the full
// rationale.
// ---------------------------------------------------------------------------

const ArenaContext = struct {
    /// The wrapped lock-free arena. Backed by `std.heap.page_allocator`
    /// so each underlying chunk is its own `mmap` region, matching the
    /// "BEAM process heap" lifetime semantics — the chunks are reclaimed
    /// wholesale by `arena.deinit()` on `core.deinit`, or by the OS on
    /// abnormal exit.
    arena: std.heap.ArenaAllocator,
};

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Allocates an `ArenaContext` on
/// `page_allocator`, embeds a fresh `ArenaAllocator(page_allocator)`,
/// and returns the pointer as the manager context per spec §4.2.
///
/// Spec §4.2 prohibits the manager from calling its own `allocate`
/// during init in a way that would trigger compiler-emitted allocation
/// paths (`Map`, `List`, `String` constructors, etc.). This manager
/// uses only `page_allocator` during init — never its own
/// `arenaAllocate` — so the prohibition is satisfied. The compiler-
/// emitted allocation surface is reached strictly post-init.
fn arenaInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const ctx = std.heap.page_allocator.create(ArenaContext) catch return null;
    ctx.* = .{
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
    };
    return @ptrCast(ctx);
}

/// Deinitialise the manager. Frees every chunk the wrapped arena
/// allocated, then returns the context struct itself to
/// `page_allocator`. Spec §4.4 declares `deinit` best-effort — it
/// runs only on the normal-main-return path — so the manager must not
/// depend on this path executing for correctness. The Arena manager
/// trivially satisfies that constraint: on abnormal exit the OS
/// reclaims every `mmap`'d chunk, so the only resource that would
/// "leak" is bookkeeping data the OS would have reclaimed anyway.
fn arenaDeinit(ctx: *anyopaque) callconv(.c) void {
    const arena_ctx: *ArenaContext = @ptrCast(@alignCast(ctx));
    arena_ctx.arena.deinit();
    std.heap.page_allocator.destroy(arena_ctx);
}

/// Raw allocation slot — `core.allocate` (spec §4.2). Serves every
/// request from the wrapped lock-free arena. The runtime supplies
/// `alignment` as a power-of-two byte count (typically `@alignOf(usize)`
/// or larger); we translate that into a `std.mem.Alignment` and call
/// `rawAlloc` on the arena's allocator so we use the standard
/// `Allocator.VTable` plumbing and inherit every fix that has ever
/// landed there.
///
/// Returning `null` on OOM matches the spec's documented signal
/// (§4.3.1) — the runtime then aborts with the OOM diagnostic. The
/// arena itself never frees the resulting pointer; bulk-free happens
/// in `arenaDeinit`.
fn arenaAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const arena_ctx: *ArenaContext = @ptrCast(@alignCast(ctx));
    // `std.mem.Alignment.fromByteUnits` requires a power-of-two byte
    // count. The runtime guarantees that contract (spec §4.2: "always
    // a power of two and at least `@alignOf(usize)`"); we clamp to 1
    // defensively to avoid a 0-byte alignment producing an invalid
    // log2 value. Zero-size allocations are forwarded as-is — the
    // arena's `alloc` asserts `n > 0`, matching the spec contract that
    // size > 0 is the runtime's responsibility, so this is purely
    // belt-and-braces.
    const align_bytes: usize = if (alignment == 0) 1 else alignment;
    const arena_alignment: std.mem.Alignment = .fromByteUnits(align_bytes);
    const allocator = arena_ctx.arena.allocator();
    return allocator.rawAlloc(size, arena_alignment, @returnAddress());
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

/// The section payload. Exported so the linker does not dead-strip it.
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
pub export const zap_memory_section: ZapMemorySection linksection(SECTION_NAME) = .{
    .meta = .{
        .magic = ZMEM_MAGIC,
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerMetaV1),
        ._reserved2 = 0,
        .desc_count = 0,
        .declared_caps = 0, // No capabilities declared — Arena is a pure allocator.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = arenaInit,
        .deinit = arenaDeinit,
        .allocate = arenaAllocate,
        .deallocate = arenaDeallocate,
        .get_capability_desc = arenaGetCapabilityDesc,
    },
};
