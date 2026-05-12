//! `Zap.Memory.Tracking` — diagnostic tracking memory manager.
//!
//! Phase 7 of the pluggable memory manager rollout — see
//! `docs/memory-manager-abi.md` (especially sections 4, 10, and 14) for
//! the normative contract this file implements.
//!
//! This manager is a CI diagnostic tool. It wraps a page-allocator-
//! backed inner allocator, tracks every allocation in a hash map keyed
//! by user pointer, surrounds each user region with canary bytes, and
//! emits stderr diagnostics for:
//!
//!   * **Leaks**: any allocation still present in the map when
//!     `core.deinit` runs prints `LEAK: ptr=0x..., size=N, alignment=A`.
//!   * **Invalid frees**: a `core.deallocate` for a pointer not present
//!     in the map prints `INVALID FREE: ptr=0x... not allocated by
//!     this manager`.
//!   * **Use-after-free / out-of-bounds writes**: canary tampering
//!     detected on `core.deallocate` prints `USE-AFTER-FREE or OOB:
//!     canary corrupted at ptr=0x...`.
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
//! `Zap.Memory.Tracking` wraps `std.heap.page_allocator` as its inner
//! allocator. Every `core.allocate(size, alignment)` becomes an inner
//! allocation of `leading_canary + size + trailing_canary` bytes, with
//! the user pointer offset past the leading canary. The leading-canary
//! size is `max(canary_size, alignment)`, padded so the user pointer
//! itself satisfies the requested alignment; the trailing-canary is
//! always `canary_size` bytes.
//!
//! Records are kept in an `AutoHashMapUnmanaged(usize, AllocRecord)`
//! keyed by the **user pointer's** integer value (not the base
//! allocation's). On `core.deallocate`, the record is looked up,
//! canaries are validated, and the inner allocator frees the base
//! pointer.
//!
//! ### Thread safety
//!
//! Spec §4.2 allows `core.allocate` and `core.deallocate` to be called
//! concurrently from any thread. The hash map is not lock-free, so the
//! manager wraps every hash-map mutation in a `cmpxchg`-based spinlock
//! built directly with `@cmpxchgStrong` / `@atomicStore`. The
//! spinlock is preferred over `std.Thread.Mutex` because the fork
//! primitive compiles managers with `link_libc = false`; pulling in
//! OS-threading primitives that may depend on libc startup risks a
//! freestanding-ish compilation cycle that `page_allocator` and
//! `@cmpxchgStrong` both avoid.
//!
//! The canary fill/check is performed under the same lock to ensure
//! the free path's "look up record, validate canaries, remove record"
//! sequence is atomic with respect to other deallocs (in practice the
//! canary check could run lock-free since each allocation has a unique
//! user pointer, but the simpler invariant — every mutation under the
//! lock — is easier to verify correct).
//!
//! ### Zero capabilities
//!
//! For v1.0, Tracking declares zero capabilities. A future enhancement
//! could wrap an inner ARC manager and forward `REFCOUNT_V1`; for now
//! it is a pure leak/UAF/OOB detector aimed at programs whose
//! allocations all flow through raw `core.allocate`. Phase 6's
//! conditional layout + codegen elision means Map/List/String
//! allocations under Tracking flow through `core.allocate` (no
//! refcount call sites), exactly the surface this manager checks.
//!
//! ### Stderr output
//!
//! `std.debug.print` is used for the diagnostic messages. It bypasses
//! the `Io` interface, writes to stderr using the most basic syscalls
//! available, and works without libc — matching the constraints of
//! the fork primitive's object-mode compilation (see spec §11.1.1).
//!
//! ### Why `page_allocator` and not `c_allocator`?
//!
//! The fork primitive `zap_fork_compile_zig_to_object` builds this
//! file with `link_libc = false`. `c_allocator` requires libc;
//! `page_allocator` makes a direct `mmap` syscall on POSIX and
//! `NtAllocateVirtualMemory` on Windows, neither of which depends on
//! libc startup. Both the inner-allocator backing AND the hashmap
//! backing route through `page_allocator` for the same reason.

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
        "tracking: ZapMemoryManagerMetaV1 v1.0 must be exactly 32 bytes",
    );
    if (@sizeOf(ZapInitOptions) != 8) @compileError(
        "tracking: ZapInitOptions v1.0 must be exactly 8 bytes",
    );
    if (@sizeOf(ZapCapabilityDescV1) != 24) @compileError(
        "tracking: ZapCapabilityDescV1 v1.0 must be exactly 24 bytes",
    );
    if (@sizeOf(ZapMemoryManagerCoreV1) != 56) @compileError(
        "tracking: ZapMemoryManagerCoreV1 v1.0 must be exactly 56 bytes",
    );

    if (@offsetOf(ZapMemoryManagerCoreV1, "init") != 16) @compileError(
        "tracking: ZapMemoryManagerCoreV1.init must be at offset 16",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deinit") != 24) @compileError(
        "tracking: ZapMemoryManagerCoreV1.deinit must be at offset 24",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 32) @compileError(
        "tracking: ZapMemoryManagerCoreV1.allocate must be at offset 32",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 40) @compileError(
        "tracking: ZapMemoryManagerCoreV1.deallocate must be at offset 40",
    );
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 48) @compileError(
        "tracking: ZapMemoryManagerCoreV1.get_capability_desc must be at offset 48",
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
    else => @compileError("tracking: unsupported object format for .zapmem section"),
};

/// Canary byte pattern. `0xCC` is the conventional "int 3" / "debug
/// trap" byte on x86 — chosen because it is loud in hex dumps, unlikely
/// to collide with user data patterns (which usually skew towards 0x00
/// and ASCII ranges), and easy to recognise during post-mortem
/// inspection of corrupted memory.
const CANARY_BYTE: u8 = 0xCC;

/// Canary byte count on each side of the user region. 16 bytes catches
/// every typical overflow (single-byte off-by-one through long-string
/// memcpy) while keeping the per-allocation overhead small. Spec
/// section 14 calls out diagnostic managers as "wrap user data with
/// canaries"; 16 bytes is the conventional choice that matches
/// Address Sanitizer's shadow-byte canary width.
const CANARY_SIZE: usize = 16;

// ---------------------------------------------------------------------------
// Allocation record + manager context
// ---------------------------------------------------------------------------

/// Per-allocation metadata kept in the tracking hash map.
///
/// `base_ptr` is the inner-allocation pointer (start of the leading
/// canary) — used to free the underlying memory on dealloc. `size` and
/// `alignment` are the user-visible request as the runtime supplied
/// them. `leading_canary_size` is the actual byte count between
/// `base_ptr` and the user pointer; it is recomputed in
/// `trackingDeallocate` from `alignment` so we don't have to store it,
/// but we keep it in the record anyway for diagnostic clarity (and to
/// guard against future scheme changes).
const AllocRecord = struct {
    base_ptr: [*]u8,
    size: usize,
    alignment: u32,
    leading_canary_size: usize,
};

/// Spinlock state. Two-value `cmpxchg`/`atomicStore` pair, identical to
/// `std.atomic.Mutex`'s shape but inlined so this manager doesn't bind
/// to the exact public path (`std.atomic.Mutex` is the canonical Zig
/// 0.16 lock type that does NOT require `std.Thread`; the fork
/// primitive compiles object files with `link_libc = false`, and
/// `std.Thread.Mutex` pulls in OS-threading primitives we'd prefer to
/// avoid for a self-contained manager).
///
/// The lock spins under contention. Tracking is a diagnostic CI tool —
/// raw throughput is not a goal, and spinlock contention is bounded by
/// the number of concurrent allocate/deallocate calls the test program
/// makes, which in practice is small.
const SpinLockState = enum(u8) { unlocked = 0, locked = 1 };

/// Manager context. Holds the hash map of live allocations and a
/// spinlock that serialises every hash-map mutation. The inner
/// allocator is `std.heap.page_allocator` (compile-time fixed for
/// v1.0; see the docstring at top of file).
const TrackingContext = struct {
    /// Live allocations keyed by user-pointer value (`@intFromPtr`).
    /// Backed by `page_allocator` (the only allocator available in
    /// `link_libc = false` mode).
    live: std.AutoHashMapUnmanaged(usize, AllocRecord) = .empty,

    /// Serialises hash-map mutations and canary fill/check. Spec §4.2
    /// allows concurrent allocate/deallocate; a single spinlock is
    /// sufficient because the manager is a diagnostic tool — raw
    /// throughput is not a goal.
    spinlock: SpinLockState = .unlocked,
};

/// Acquire the spinlock. Busy-waits via `@cmpxchgStrong`; on a busy
/// lock, yields the loop body to the CPU's pause / yield hint
/// (`std.atomic.spinLoopHint`) so the contending thread does not
/// burn 100% CPU. Acq-rel ordering on the successful exchange
/// guarantees the lock-protected region happens-after the release in
/// `spinUnlock`.
fn spinLock(state: *SpinLockState) void {
    while (true) {
        if (@cmpxchgStrong(SpinLockState, state, .unlocked, .locked, .acquire, .monotonic) == null) return;
        std.atomic.spinLoopHint();
    }
}

/// Release the spinlock. Plain release-ordering store; pairs with the
/// acquire load in the next `spinLock` to publish all writes made
/// inside the critical section.
fn spinUnlock(state: *SpinLockState) void {
    @atomicStore(SpinLockState, state, .unlocked, .release);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Compute the leading-canary byte count for a user allocation of the
/// given alignment. Result is `max(CANARY_SIZE, alignment)` rounded up
/// to a multiple of `alignment`, so the user pointer (base + leading)
/// satisfies the requested alignment. Since `alignment` is always a
/// power of two ≥ `@alignOf(usize)` (spec §4.2), the rounding is
/// equivalent to "pick the larger of CANARY_SIZE and alignment".
fn computeLeadingCanarySize(alignment: u32) usize {
    const al: usize = alignment;
    return if (CANARY_SIZE >= al) CANARY_SIZE else al;
}

/// Fill `count` bytes starting at `dst` with `CANARY_BYTE`.
fn fillCanary(dst: [*]u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        dst[i] = CANARY_BYTE;
    }
}

/// Check that `count` bytes starting at `src` are all `CANARY_BYTE`.
/// Returns the index of the first tampered byte, or `null` if intact.
fn findTamperedCanaryByte(src: [*]const u8, count: usize) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (src[i] != CANARY_BYTE) return i;
    }
    return null;
}

/// Write a diagnostic line to stderr. `std.debug.print` bypasses the
/// `Io` interface, writes to stderr using the most basic syscalls
/// available, and works without libc (matching the fork primitive's
/// `link_libc = false` constraint). Format errors are silently
/// dropped — the diagnostic is best-effort and must not panic the
/// program that triggered the corrupted-canary check.
fn printDiagnostic(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// ---------------------------------------------------------------------------
// Vtable functions
// ---------------------------------------------------------------------------

/// Initialise the manager. Allocates a `TrackingContext` on
/// `page_allocator` with an empty hash map, returns its address as
/// the manager context per spec §4.2.
///
/// Spec §4.2 prohibits the manager from triggering compiler-emitted
/// allocation paths during init (Map/List/String constructors,
/// refcount allocators). This manager only touches `page_allocator`
/// during init — never its own `trackingAllocate` — so the
/// prohibition is satisfied trivially.
fn trackingInit(options: ?*const ZapInitOptions) callconv(.c) ?*anyopaque {
    _ = options;
    const ctx = std.heap.page_allocator.create(TrackingContext) catch return null;
    ctx.* = .{};
    return @ptrCast(ctx);
}

/// Deinitialise the manager. Walks the live hash map; every remaining
/// entry is a leak and is reported to stderr in the format
/// `LEAK: ptr=0x..., size=N, alignment=A`. Frees the inner pages for
/// the leaked allocations so the test that ran the program can be
/// re-run without the OS having to keep the abandoned pages around;
/// this matches the spirit of spec §4.4 ("deinit must not return
/// failure" — we drain everything and proceed regardless of what we
/// find). Frees the hash map's backing storage and the context struct
/// last.
///
/// Spec §4.4 makes `deinit` best-effort — it runs only on the
/// normal-main-return path — so the leak report is also best-effort.
/// On abnormal exit (panic, abort, SIGKILL) the leak report is not
/// produced; users running this manager in CI should drive their
/// test through a clean process exit to see the report.
fn trackingDeinit(ctx: *anyopaque) callconv(.c) void {
    const tctx: *TrackingContext = @ptrCast(@alignCast(ctx));
    // Spec §4.4 says deinit is "called on the same thread that called
    // init" with no concurrent vtable calls; we therefore do not need
    // to take the mutex here. But we DO need to drain the hash map in
    // a way that does not invalidate the iterator while we free —
    // collecting keys/values first via the iterator and freeing in a
    // second pass would require allocation. Instead, walk the iterator
    // and release each base pointer to the inner allocator as we go;
    // the iterator state is over the underlying open-addressing array
    // and is not affected by external mutation of allocations we
    // already iterated past.
    var iter = tctx.live.iterator();
    while (iter.next()) |entry| {
        const user_ptr_value = entry.key_ptr.*;
        const rec = entry.value_ptr.*;
        printDiagnostic(
            "LEAK: ptr=0x{x}, size={d}, alignment={d}\n",
            .{ user_ptr_value, rec.size, rec.alignment },
        );
        // Return the inner allocation to page_allocator. The total
        // inner-allocation size is `leading + size + CANARY_SIZE`.
        const total = rec.leading_canary_size + rec.size + CANARY_SIZE;
        const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(rec.alignment, @as(u32, @intCast(CANARY_SIZE))));
        std.heap.page_allocator.rawFree(rec.base_ptr[0..total], inner_alignment, @returnAddress());
    }
    tctx.live.deinit(std.heap.page_allocator);
    std.heap.page_allocator.destroy(tctx);
}

/// Raw allocation slot — `core.allocate` (spec §4.2). Wraps the inner
/// page-allocator request in canary bytes, records the live
/// allocation in the hash map, and returns the user pointer (offset
/// past the leading canary).
///
/// The inner allocation is `leading + size + CANARY_SIZE` bytes,
/// where `leading = max(CANARY_SIZE, alignment)`. The inner alignment
/// passed to `page_allocator.rawAlloc` is `max(alignment, CANARY_SIZE)`
/// so the user pointer (base + leading) still satisfies the
/// requested alignment.
fn trackingAllocate(ctx: *anyopaque, size: usize, alignment: u32) callconv(.c) ?[*]u8 {
    const tctx: *TrackingContext = @ptrCast(@alignCast(ctx));

    // Spec §4.2 contract: `alignment` is "always a power of two and at
    // least `@alignOf(usize)`". The runtime is responsible for
    // enforcing that — papering over a contract violation here would
    // silently round invalid alignments up to 1 and hide the bug.
    // Assert the contract directly so a regression surfaces immediately
    // in `Debug` / `ReleaseSafe` builds (the only modes the fork
    // primitive compiles managers under; see spec §10.3.1). Mirrors
    // the Arena/Leak manager pattern.
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));

    const leading_canary_size = computeLeadingCanarySize(alignment);
    const total = leading_canary_size + size + CANARY_SIZE;
    const inner_alignment_bytes: u32 = @max(alignment, @as(u32, @intCast(CANARY_SIZE)));
    const inner_alignment: std.mem.Alignment = .fromByteUnits(inner_alignment_bytes);

    const base_ptr = std.heap.page_allocator.rawAlloc(total, inner_alignment, @returnAddress()) orelse return null;

    // Fill canaries.
    fillCanary(base_ptr, leading_canary_size);
    fillCanary(base_ptr + leading_canary_size + size, CANARY_SIZE);

    const user_ptr = base_ptr + leading_canary_size;
    const user_ptr_value = @intFromPtr(user_ptr);

    // Insert into the hash map under the spinlock.
    spinLock(&tctx.spinlock);
    defer spinUnlock(&tctx.spinlock);
    tctx.live.put(std.heap.page_allocator, user_ptr_value, .{
        .base_ptr = base_ptr,
        .size = size,
        .alignment = alignment,
        .leading_canary_size = leading_canary_size,
    }) catch {
        // OOM on the hash-map side: roll back the inner allocation and
        // return null. The spec's OOM signal is "allocate returned
        // null"; we satisfy that whether OOM came from the inner
        // allocator or the tracking bookkeeping.
        std.heap.page_allocator.rawFree(base_ptr[0..total], inner_alignment, @returnAddress());
        return null;
    };

    return user_ptr;
}

/// Raw deallocation slot — `core.deallocate` (spec §4.2). Looks up the
/// record by user pointer; on miss prints `INVALID FREE` and returns.
/// On hit validates the canaries; if tampered prints
/// `USE-AFTER-FREE or OOB` and proceeds to free. Removes the record
/// from the hash map and frees the inner allocation through
/// `page_allocator.rawFree`.
///
/// The spec (§4.2) guarantees `ptr`, `size`, and `alignment` match the
/// values that were passed to `allocate`. We trust `ptr` for the hash
/// lookup; `size` and `alignment` are cross-checked against the
/// recorded values, and a mismatch prints a diagnostic (though the
/// runtime is expected to be correct here — this catches bugs in the
/// runtime, not in user code).
fn trackingDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    const tctx: *TrackingContext = @ptrCast(@alignCast(ctx));
    const user_ptr_value = @intFromPtr(ptr);

    spinLock(&tctx.spinlock);
    defer spinUnlock(&tctx.spinlock);

    const entry = tctx.live.fetchRemove(user_ptr_value) orelse {
        printDiagnostic(
            "INVALID FREE: ptr=0x{x} not allocated by this manager\n",
            .{user_ptr_value},
        );
        return;
    };
    const rec = entry.value;

    // Cross-check the runtime-supplied size/alignment against the
    // record. A mismatch indicates a runtime bug; we still proceed
    // with the free using the recorded values so we don't leak the
    // inner allocation.
    if (rec.size != size or rec.alignment != alignment) {
        printDiagnostic(
            "DEALLOC SIZE/ALIGN MISMATCH: ptr=0x{x} recorded size={d}/align={d}, runtime supplied size={d}/align={d}\n",
            .{ user_ptr_value, rec.size, rec.alignment, size, alignment },
        );
    }

    // Validate the leading canary.
    if (findTamperedCanaryByte(rec.base_ptr, rec.leading_canary_size)) |off| {
        printDiagnostic(
            "USE-AFTER-FREE or OOB: leading canary corrupted at ptr=0x{x} (byte {d}/{d})\n",
            .{ user_ptr_value, off, rec.leading_canary_size },
        );
    }

    // Validate the trailing canary.
    const trailing_start = rec.base_ptr + rec.leading_canary_size + rec.size;
    if (findTamperedCanaryByte(trailing_start, CANARY_SIZE)) |off| {
        printDiagnostic(
            "USE-AFTER-FREE or OOB: trailing canary corrupted at ptr=0x{x} (byte {d}/{d})\n",
            .{ user_ptr_value, off, CANARY_SIZE },
        );
    }

    // Return the inner allocation to page_allocator.
    const total = rec.leading_canary_size + rec.size + CANARY_SIZE;
    const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(rec.alignment, @as(u32, @intCast(CANARY_SIZE))));
    std.heap.page_allocator.rawFree(rec.base_ptr[0..total], inner_alignment, @returnAddress());
}

/// Capability descriptor lookup. Tracking declares zero capabilities,
/// so every query returns null (spec §5.5).
fn trackingGetCapabilityDesc(
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
/// is always self-consistent regardless of linker behaviour. Tracking
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
        .declared_caps = 0, // No capabilities declared — Tracking is a pure diagnostic wrapper.
        .core_vtable_offset = @offsetOf(ZapMemorySection, "core"),
        .reserved = 0,
    },
    .core = .{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = trackingInit,
        .deinit = trackingDeinit,
        .allocate = trackingAllocate,
        .deallocate = trackingDeallocate,
        .get_capability_desc = trackingGetCapabilityDesc,
    },
};
