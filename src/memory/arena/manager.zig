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
//! `Memory.Arena` wraps Zig 0.16's `std.heap.ArenaAllocator` backed
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
//! historical note that `Memory.Arena` would wrap `ArenaAllocator`
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
    // Vtable structs carry pointers; their layout checks are RELATIVE
    // to `PTR` (mirroring `src/memory/abi.zig`). On 64-bit (`PTR == 8`)
    // these reduce to the original 24/56-byte layout; on wasm32 the
    // descriptors are correctly smaller.
    const PTR: usize = @sizeOf(*const anyopaque);
    if (@sizeOf(ZapCapabilityDescV1) != std.mem.alignForward(usize, 12, PTR) + PTR) @compileError(
        "arena: ZapCapabilityDescV1 size must be its integer prefix plus one pointer",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 16 + 5 * PTR) @compileError(
        "arena: ZapMemoryManagerCoreV1 size must be its 16-byte prefix plus five pointers",
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
///
/// ### Thread-safety of `arena.deinit()`
///
/// Zig 0.16's `std.heap.ArenaAllocator.deinit` is documented as "not
/// threadsafe" — it walks `used_list`/`free_list` without atomic
/// fences because the deinit path assumes exclusive access. This is
/// nonetheless safe to call here because spec §4.4 makes `deinit` a
/// **single-threaded normal-exit-only** call: the runtime invokes
/// `core.deinit` exactly once, from the main thread, after all
/// program-spawned threads have either joined or been terminated by
/// the normal-shutdown path. No concurrent `arenaAllocate` or
/// `arenaDeallocate` can be in flight when this function runs, so the
/// "not threadsafe" caveat does not apply. On abnormal-exit paths
/// (`abort`, `panic`, `std.process.exit`) this function is never
/// invoked at all — the OS reclaims the `mmap`'d chunks directly.
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
    // Spec §4.2 contract: `alignment` is "always a power of two and at
    // least `@alignOf(usize)`". The runtime is responsible for enforcing
    // that — papering over a contract violation here would silently
    // round invalid alignments up to 1 and hide the bug. Assert the
    // contract directly so a regression surfaces immediately in
    // `Debug` / `ReleaseSafe` builds (the only modes the fork primitive
    // compiles managers under; see spec §10.3.1). Zero-size allocations
    // are forwarded as-is — the arena's `alloc` asserts `n > 0`,
    // matching the spec contract that `size > 0` is the runtime's
    // responsibility.
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    const arena_alignment: std.mem.Alignment = .fromByteUnits(alignment);
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
