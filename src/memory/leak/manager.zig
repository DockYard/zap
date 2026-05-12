//! `Zap.Memory.Leak` — diagnostic leak-everything memory manager.
//!
//! Phase 7 of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` (especially sections 4, 10, and 14) for
//! the normative contract this file implements.
//!
//! This manager is a CI diagnostic tool. Every `core.allocate` returns
//! real memory from `std.heap.page_allocator`; every `core.deallocate`
//! is a deliberate no-op. The whole point is that allocations are NEVER
//! freed for the lifetime of the process. Two CI use cases this enables:
//!
//!   1. **Codegen elision verification.** A binary built with
//!      `memory: Zap.Memory.Leak` declares zero capabilities (no
//!      `REFCOUNT_V1`), so under Phase 6's conditional layout + codegen
//!      elision the compiler must emit zero retain/release call sites.
//!      The output binary's `.text` should contain no calls into the
//!      manager's vtable at all — if the elision regresses and the
//!      compiler keeps emitting retains/releases against a manager
//!      that has no REFCOUNT_V1 slot, the resulting symbol references
//!      will fail to link (or call into uninitialised vtable slots),
//!      which CI catches immediately.
//!   2. **Bounded-memory benchmarks.** A short-lived program built
//!      with Leak runs to completion without freeing anything; the
//!      OS reclaims the address space on exit. This baselines what
//!      raw allocator throughput looks like with zero deallocation
//!      overhead and zero refcount overhead.
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
//! `Zap.Memory.Leak` wraps `std.heap.page_allocator` directly. There is
//! no slab pool, no free list, no per-allocation header — every request
//! goes straight to a syscall (`mmap` on POSIX, `NtAllocateVirtualMemory`
//! on Windows). This is the simplest possible backing allocator that
//! still produces real, writable memory.
//!
//! ### Zero capabilities
//!
//! Leak declares zero capabilities. `core.get_capability_desc` returns
//! null for every ID. Under Phase 6's codegen elision, a Zap program
//! built with `memory: Zap.Memory.Leak` must compile cleanly — the
//! compiler sees zero declared capabilities and elides all retain/
//! release call sites. Map/List/String allocations route through raw
//! `core.allocate` only.
//!
//! ### Deliberate no-op deallocation
//!
//! `leakDeallocate` is a no-op. Memory allocated by this manager is
//! intentionally leaked for the process lifetime. This is NOT a bug —
//! it is the entire purpose of this manager. On normal exit the OS
//! reclaims every `mmap`'d page; on abnormal exit (panic, abort,
//! SIGKILL) the OS reclaims those pages too. From the program's point
//! of view, leaked memory is indistinguishable from leaked-by-design
//! arena memory (the `Zap.Memory.Arena` manager has the same surface
//! behaviour, just with explicit bulk free in `core.deinit`).
//!
//! ### Why `page_allocator` and not `c_allocator`?
//!
//! The fork primitive `zap_fork_compile_zig_to_object` builds this
//! file with `link_libc = false` (see `~/projects/zig/src/zir_api.zig`'s
//! `compileToObjectImpl` — the `Compilation.Config.resolve` call pins
//! `link_libc = false` for object-mode output). `c_allocator` requires
//! libc; `page_allocator` makes a direct `mmap` syscall on POSIX and
//! `NtAllocateVirtualMemory` on Windows, neither of which depends on
//! libc startup. Both `Zap.Memory.Arena` and `Zap.Memory.ARC` follow
//! the same convention.

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
        "leak: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "leak: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "leak: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "leak: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );

    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "leak: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "leak: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "leak: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "leak: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "leak: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
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
    else => @compileError("leak: unsupported object format for .zapmem section"),
};

// ---------------------------------------------------------------------------
// Manager context.
//
// Leak holds a single-byte heap-allocated context purely so the runtime's
// init/deinit lifecycle is exercised. The context carries no state — there
// is nothing to track because no individual deallocations ever occur — but
// returning a heap pointer rather than the address of a `const` sentinel
// matches the Arena manager's pattern and gives us a real address that
// the runtime can pass back to every vtable call.
// ---------------------------------------------------------------------------

const LeakContext = struct {
    /// Placeholder byte. Leak has no per-process state — every
    /// allocation is satisfied directly by `page_allocator` and never
    /// freed — but the spec (§4.2) requires `init` to return a
    /// non-null pointer, so we heap-allocate this struct and return
    /// its address. `deinit` frees the struct itself but does NOT
    /// release any user allocations made through `leakAllocate`.
    _: u8 = 0,
};

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Allocates a `LeakContext` on
/// `page_allocator` and returns its pointer as the manager context
/// per spec §4.2.
///
/// Spec §4.2 prohibits the manager from calling its own `allocate`
/// during init in a way that would trigger compiler-emitted allocation
/// paths (`Map`, `List`, `String` constructors, etc.). This manager
/// uses only `page_allocator` directly during init — never its own
/// `leakAllocate` — so the prohibition is satisfied trivially.
fn leakInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const ctx = std.heap.page_allocator.create(LeakContext) catch return null;
    ctx.* = .{};
    return @ptrCast(ctx);
}

/// Deinitialise the manager. Frees the context struct itself but does
/// NOT release any allocations made through `leakAllocate` — those
/// pages remain mapped until the OS reclaims them at process exit.
///
/// The intentional leak is the entire reason this manager exists; do
/// not "fix" this by adding a tracking list and freeing pages on
/// deinit. If you need that behaviour, you want `Zap.Memory.Tracking`
/// (which wraps another manager and detects leaks at deinit) or
/// `Zap.Memory.Arena` (which bulk-frees at deinit).
///
/// Spec §4.4 makes `deinit` best-effort — it runs only on the
/// normal-main-return path — so the manager must not depend on this
/// path executing for correctness. Leak trivially satisfies that
/// constraint: on abnormal exit the OS reclaims every `mmap`'d page
/// the manager handed out, so nothing changes from the user's point
/// of view whether `deinit` runs or not.
fn leakDeinit(ctx: *anyopaque) callconv(.c) void {
    const leak_ctx: *LeakContext = @ptrCast(@alignCast(ctx));
    std.heap.page_allocator.destroy(leak_ctx);
}

/// Raw allocation slot — `core.allocate` (spec §4.2). Returns real
/// memory backed by `page_allocator`. Every successful allocation
/// produces a page-aligned `mmap` region (rounded up to the host page
/// size); `page_allocator.rawAlloc` is the standard Zig 0.16 entry
/// point and handles the page-size rounding itself.
///
/// Returning `null` on OOM matches the spec's documented signal
/// (§4.3.1) — the runtime then aborts with the OOM diagnostic. The
/// allocation is never freed by this manager; `leakDeallocate` is a
/// no-op.
fn leakAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    _ = ctx;
    // Spec §4.2 contract: `alignment` is "always a power of two and at
    // least `@alignOf(usize)`". The runtime is responsible for enforcing
    // that — papering over a contract violation here would silently
    // round invalid alignments up to 1 and hide the bug. Assert the
    // contract directly so a regression surfaces immediately in
    // `Debug` / `ReleaseSafe` builds (the only modes the fork primitive
    // compiles managers under; see spec §10.3.1). Mirrors the Arena
    // manager's pattern (`arenaAllocate`).
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    const leak_alignment: std.mem.Alignment = .fromByteUnits(alignment);
    return std.heap.page_allocator.rawAlloc(size, leak_alignment, @returnAddress());
}

/// Raw deallocation slot — `core.deallocate` (spec §4.2). Deliberate
/// no-op: memory allocated by `leakAllocate` is intentionally leaked
/// for the process lifetime. See `leakDeinit`'s docstring for the
/// rationale.
///
/// Spec §4.2 explicitly endorses no-op deallocators for arenas and
/// similar bulk-free managers; this same allowance covers Leak's
/// never-free policy.
fn leakDeallocate(
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

/// Capability descriptor lookup. Leak declares zero capabilities, so
/// every query returns null (spec §5.5).
fn leakGetCapabilityDesc(
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
/// is always self-consistent regardless of linker behaviour. Leak
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
        .declared_caps = 0, // No capabilities declared — Leak is a pure allocator that never frees.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = leakInit,
        .deinit = leakDeinit,
        .allocate = leakAllocate,
        .deallocate = leakDeallocate,
        .get_capability_desc = leakGetCapabilityDesc,
    },
};

// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs (Phase 4)
//
// Leak declares zero capabilities. The runtime's Phase 6 codegen elides
// every retain/release call site under a manager that omits the
// capability, so the stubs below are never invoked in practice. They
// exist solely to give the uniform first-party manager interface a
// complete set of symbols — see the matching section in
// `src/memory/arc/manager.zig` for the full rationale.
// ---------------------------------------------------------------------------

fn leakRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Zap.Memory.Leak does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn leakReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Zap.Memory.Leak does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn leakRetainSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Zap.Memory.Leak does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn leakReleaseSizedStub(
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
    @panic("Zap.Memory.Leak does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn leakAllocateRefcountedStub(
    ctx: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Zap.Memory.Leak does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn leakRefcountSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Zap.Memory.Leak does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface (Phase 4)
//
// See the matching section in `src/memory/arc/manager.zig` for the full
// rationale.
// ---------------------------------------------------------------------------

pub const init = leakInit;
pub const deinit = leakDeinit;
pub const allocate = leakAllocate;
pub const deallocate = leakDeallocate;
pub const allocateRefcounted = leakAllocateRefcountedStub;
pub const retain = leakRetainStub;
pub const release = leakReleaseStub;
pub const retainSized = leakRetainSizedStub;
pub const releaseSized = leakReleaseSizedStub;
pub const refcountSized = leakRefcountSizedStub;
pub const getCapabilityDesc = leakGetCapabilityDesc;
