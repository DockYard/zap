//! `Memory.Tracking` — diagnostic tracking memory manager.
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
//!     canary corrupted at ptr=0x...`. The hash-map record is left
//!     in place and the poisoned inner allocation is INTENTIONALLY
//!     leaked — the corrupted bytes stay in memory at a stable
//!     address so the user (or an attached debugger) can dump them
//!     for forensic analysis. A later `core.deinit` walk reports
//!     the same allocation as a `LEAK`, which doubles as the
//!     second-line signal that something went wrong.
//!   * **Size/alignment mismatch on free**: when the runtime passes a
//!     size or alignment that disagrees with the recorded values for
//!     the user pointer, the manager prints
//!     `DEALLOC SIZE/ALIGN MISMATCH: ...` and INTENTIONALLY leaks the
//!     allocation rather than freeing it. The mismatch indicates a
//!     runtime bug, not user error; the diagnostic is the actionable
//!     signal and the leak gives the user a stable address for
//!     forensic inspection (same rationale as the canary-corruption
//!     case above).
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
//! `Memory.Tracking` wraps `std.heap.page_allocator` as its inner
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
// Phase 4.c — leak-attribution boundary types (ABI between the runtime and
// any manager that records allocation-site attribution).
//
// The leak report is rendered by the RUNTIME, not this manager: the
// unified renderer needs the symbolizer, the `.zap-symbols` side-table,
// and the shared visual-format spec — all of which live in `runtime.zig`,
// which this self-contained manager (std + builtin only, `link_libc =
// false`) cannot import. So the manager owns the authoritative live-
// allocation set and the canary state, and hands each survivor / violation
// to a runtime-installed *report sink* as a `ZapLeakRecord`; the sink
// symbolizes the backtrace and renders the unified `domain=leak`
// diagnostic. This is the "emit structured data, thin reporting layer
// renders it" wiring the Phase 4.c spec calls for.
//
// `ZapLeakRecord` is redeclared (with a `comptime` size/offset assert)
// in `runtime.zig`'s `AbiV1` block under the self-contained-manager
// convention; the two must stay byte-identical.
// ---------------------------------------------------------------------------

/// Which kind of memory fault a `ZapLeakRecord` describes. Drives the
/// renderer's domain/sub-kind selection (`leak` vs the `uaf` /
/// `invalid_free` / `mismatch` sub-kinds of a memory diagnostic).
const ZapLeakKind = enum(u32) {
    /// A live allocation that survived to `core.deinit` — a leak.
    leak = 0,
    /// A canary byte was tampered (use-after-free or out-of-bounds write).
    use_after_free_or_oob = 1,
    /// `core.deallocate` for a pointer this manager never handed out.
    invalid_free = 2,
    /// The runtime-supplied size/alignment disagreed with the record.
    dealloc_mismatch = 3,
};

/// Structured, render-ready description of one memory fault, handed from
/// the manager to the runtime's report sink. All slices/arrays are
/// borrowed or inline (no ownership crosses the boundary): `type_name`
/// points into the user binary's `.rodata`, and `backtrace` is read
/// in-place from the manager's record. The sink must not retain any
/// pointer past the call.
const ZapLeakRecord = extern struct {
    /// The fault kind (`ZapLeakKind` value).
    kind: u32,
    /// The user pointer the runtime observed (the leaked / freed object).
    user_ptr: usize,
    /// The user-visible allocation size in bytes.
    size: usize,
    /// The user-visible allocation alignment.
    alignment: u32,
    /// The object's refcount at report time. Tracking declares no
    /// REFCOUNT_V1 capability, so every allocation it audits flows
    /// through `core.allocate` (no side-table refcount); the manager
    /// reports `1` — the construction-site ownership count — which is
    /// what the renderer prints as `refcount 1`.
    refcount: u32,
    /// Borrowed `.rodata` slice naming the Zap type, or null/0 when the
    /// allocation was never annotated.
    type_name_ptr: ?[*]const u8,
    type_name_len: usize,
    /// Allocation-site return addresses (borrowed from the record), or
    /// null/0 when the allocation was never annotated.
    backtrace_ptr: ?[*]const usize,
    backtrace_len: usize,
    /// Canary sub-detail (only meaningful for `use_after_free_or_oob`):
    /// the index of the first tampered byte and the canary width. Zero
    /// for the other kinds.
    canary_offset: usize,
    canary_size: usize,
    /// Mismatch sub-detail (only meaningful for `dealloc_mismatch`): the
    /// size/alignment the runtime supplied to `core.deallocate`. Zero for
    /// the other kinds.
    supplied_size: usize,
    supplied_alignment: u32,
};

/// The runtime-installed leak-report sink. Invoked once per surviving
/// allocation at `core.deinit` and once per canary/invalid-free/mismatch
/// fault at `core.deallocate`. `sink_ctx` is an opaque cookie the runtime
/// passed to `setLeakReportSink` (it threads the runtime's own renderer
/// state); the manager passes it back unchanged.
const ZapLeakReportSink = *const fn (sink_ctx: ?*anyopaque, record: *const ZapLeakRecord) callconv(.c) void;

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

/// Maximum number of allocation-site return addresses stored per live
/// allocation. The runtime captures a backtrace at the `core.allocate`
/// call site (via `ArcRuntime.allocAny`'s `Backtrace.capture`) and hands
/// it to `annotateAllocation`; the manager keeps the first
/// `ALLOC_BACKTRACE_MAX_FRAMES` so the deinit-time leak report can name
/// the allocation site without holding a heap-backed slice (which would
/// itself perturb the live-allocation set this manager is auditing).
/// 16 frames is deep enough to reach the user's `main` through the
/// runtime's heap-promotion trampoline for every realistic Zap program;
/// the report renderer caps what it shows via `ZAP_BACKTRACE` anyway.
const ALLOC_BACKTRACE_MAX_FRAMES: usize = 16;

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
///
/// Phase 4.c leak attribution: `type_name` / `backtrace` are populated
/// out-of-band by `annotateAllocation`, which the runtime calls
/// immediately after the `core.allocate` that produced `user_ptr`. They
/// stay empty (`type_name_len == 0`, `backtrace_len == 0`) for any
/// allocation the runtime did not annotate (e.g. a manager-internal
/// allocation, or a build whose runtime predates the attribution hook),
/// in which case the leak report degrades cleanly to the
/// pointer/size/alignment it has always carried.
///
///   * `type_name` is a borrowed slice into the user binary's `.rodata`
///     (a comptime `@typeName`-derived string the runtime owns for the
///     process lifetime) — never freed by the manager.
///   * `backtrace` is a fixed-capacity inline array (no heap) so storing
///     attribution never itself allocates.
const AllocRecord = struct {
    base_ptr: [*]u8,
    size: usize,
    alignment: u32,
    leading_canary_size: usize,

    /// Borrowed `.rodata` slice naming the Zap type of the allocation
    /// (e.g. `%User{}`), or empty when the allocation was not annotated.
    type_name_ptr: [*]const u8 = undefined,
    type_name_len: usize = 0,

    /// Allocation-site return addresses captured by the runtime at the
    /// `core.allocate` call site. `backtrace_len` is `0` when the
    /// allocation was not annotated.
    backtrace: [ALLOC_BACKTRACE_MAX_FRAMES]usize = undefined,
    backtrace_len: usize = 0,

    fn typeName(self: *const AllocRecord) []const u8 {
        if (self.type_name_len == 0) return "";
        return self.type_name_ptr[0..self.type_name_len];
    }
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

    /// Phase 4.c: the runtime-installed leak-report sink. Set once at
    /// startup via `setLeakReportSink` (the runtime threads its unified
    /// renderer through here). `null` when no sink was installed — e.g.
    /// the in-process behavioural tests below, or a host that links the
    /// manager without the attribution-aware runtime — in which case the
    /// manager falls back to the legacy raw `printDiagnostic` lines so a
    /// leak is never silently dropped.
    report_sink: ?ZapLeakReportSink = null,

    /// Opaque cookie passed back to `report_sink` unchanged. Carries the
    /// runtime's renderer state across the C-ABI boundary.
    report_sink_ctx: ?*anyopaque = null,
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

/// Pluggable diagnostic sink type. The production manager writes
/// diagnostics to stderr (via `std.debug.print`), but the in-process
/// behavioural tests in this file need to capture the messages into a
/// buffer and assert their contents. Both paths route through this
/// function-pointer indirection so the test can install a capturing
/// writer for the duration of the test and the production binary keeps
/// using `defaultDiagnosticWriter` (stderr).
///
/// The hook takes a pre-formatted byte slice — the caller is
/// responsible for formatting the message into a stack-local buffer
/// before invoking the hook. Routing pre-formatted text through the
/// hook (rather than a `comptime fmt + args` pair) keeps the test
/// capture path simple: the test writer just appends bytes to a buffer
/// and does not need to support the entire `std.fmt` parameter shape.
const DiagnosticWriter = *const fn (message: []const u8) void;

/// Default diagnostic sink. Delegates to `std.debug.print` because that
/// path bypasses the `Io` interface, writes to stderr using the most
/// basic syscalls available, and works without libc — matching the fork
/// primitive's `link_libc = false` constraint on object-mode manager
/// builds (see spec §11.1.1). Format errors are silently dropped: the
/// diagnostic is best-effort and must not panic the program that
/// triggered the corrupted-canary check.
fn defaultDiagnosticWriter(message: []const u8) void {
    std.debug.print("{s}", .{message});
}

/// Module-global diagnostic sink pointer. Updated by behavioural tests
/// via `setDiagnosticWriterForTest` so they can capture diagnostics
/// into a buffer; the production binary leaves it pointing at the
/// stderr-emitting `defaultDiagnosticWriter`.
///
/// This is the only piece of mutable module state in the manager;
/// every per-allocation record lives inside `TrackingContext`. The
/// variable is read at most once per diagnostic emission and is never
/// mutated from production code paths — tests install their writer
/// before exercising the vtable functions and restore the default
/// before returning. Concurrent reads from the production allocator/
/// deallocator paths are safe (Zig's `*const fn` semantics give us a
/// read-only pointer load).
var diagnostic_writer: DiagnosticWriter = defaultDiagnosticWriter;

/// Format a diagnostic message into a fixed stack buffer and dispatch
/// it through the module-global `diagnostic_writer`. Using a stack
/// buffer (rather than calling `std.debug.print` directly) keeps the
/// `link_libc = false` constraint satisfied while letting tests
/// substitute a buffer-capturing writer.
///
/// The buffer is sized at 512 bytes — comfortably larger than every
/// diagnostic message this manager emits (the longest current message
/// is the deallocate size/alignment mismatch, which fits well under
/// 256 bytes even with two `0x...` hex pointer formats). If the format
/// ever overflows, `std.fmt.bufPrint` returns `error.NoSpaceLeft` and
/// we emit a short truncation marker instead — diagnostics must never
/// panic the program that triggered them.
fn printDiagnostic(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        const truncation_marker = "[tracking diagnostic message truncated]\n";
        const copy_len = @min(truncation_marker.len, buf.len);
        @memcpy(buf[0..copy_len], truncation_marker[0..copy_len]);
        break :blk buf[0..copy_len];
    };
    diagnostic_writer(message);
}

// ---------------------------------------------------------------------------
// Phase 4.c — leak-attribution recording + report dispatch
// ---------------------------------------------------------------------------

/// Record the Zap type + allocation-site backtrace for a live allocation
/// (Phase 4.c). The runtime calls this from `ArcRuntime.allocAny` (and the
/// other heap-promotion paths) immediately after the `core.allocate` that
/// produced `user_ptr`, passing the comptime-derived Zap type name and the
/// `Backtrace.capture` it took at the allocation site — neither of which is
/// visible to the bare `core.allocate(size, alignment)` slot.
///
/// The attribution is stored on the existing `AllocRecord` (no second
/// hash map): `core.allocate` inserted the record under `user_ptr` a
/// moment ago, so this looks it up and fills `type_name` / `backtrace`.
/// `type_name` is a borrowed `.rodata` slice (the runtime owns it for the
/// process lifetime); the backtrace is copied into the record's inline,
/// fixed-capacity array (no heap, so attribution never perturbs the
/// live-allocation set being audited). Annotating a pointer that is not
/// in the live map is a no-op — the allocation may have already been
/// freed, or come from a path the manager does not track.
///
/// `callconv(.c)` and the exploded slice arguments (ptr+len rather than a
/// Zig slice) keep this callable across the runtime↔manager C-ABI
/// boundary uniformly for first-party and object-linked builds.
fn trackingAnnotateAllocation(
    ctx: *anyopaque,
    user_ptr: [*]u8,
    type_name_ptr: [*]const u8,
    type_name_len: usize,
    backtrace_ptr: [*]const usize,
    backtrace_len: usize,
) callconv(.c) void {
    const tctx: *TrackingContext = @ptrCast(@alignCast(ctx));
    const user_ptr_value = @intFromPtr(user_ptr);

    spinLock(&tctx.spinlock);
    defer spinUnlock(&tctx.spinlock);

    const rec_ptr = tctx.live.getPtr(user_ptr_value) orelse return;
    rec_ptr.type_name_ptr = type_name_ptr;
    rec_ptr.type_name_len = type_name_len;
    const copy_len = @min(backtrace_len, ALLOC_BACKTRACE_MAX_FRAMES);
    var i: usize = 0;
    while (i < copy_len) : (i += 1) rec_ptr.backtrace[i] = backtrace_ptr[i];
    rec_ptr.backtrace_len = copy_len;
}

/// Install the runtime's leak-report sink (Phase 4.c). Called once at
/// memory-startup, before any allocation, so every survivor at
/// `core.deinit` and every canary/invalid-free/mismatch fault routes
/// through the unified renderer rather than the legacy raw lines. Passing
/// a null sink restores the raw-line fallback (used by nothing in
/// production; defensive).
fn trackingSetLeakReportSink(
    ctx: *anyopaque,
    sink: ?ZapLeakReportSink,
    sink_ctx: ?*anyopaque,
) callconv(.c) void {
    const tctx: *TrackingContext = @ptrCast(@alignCast(ctx));
    spinLock(&tctx.spinlock);
    defer spinUnlock(&tctx.spinlock);
    tctx.report_sink = sink;
    tctx.report_sink_ctx = sink_ctx;
}

/// Dispatch one fault record to the runtime sink when installed, else
/// fall back to the legacy raw `printDiagnostic` line so a leak / fault
/// is never silently dropped. The `fallback` closure formats the legacy
/// message; it runs only when no sink is installed.
///
/// Both the sink call and the fallback run OUTSIDE the manager spinlock
/// (the caller releases it first): the sink symbolizes + renders + may
/// allocate (it is the non-signal deinit path), and the fallback's
/// `std.debug.print` takes the stderr mutex — neither must be held under
/// the manager's lock (the lock-inversion rationale already documented on
/// `trackingDeallocate`). The `report_sink` / `report_sink_ctx` reads are
/// plain pointer loads; the sink is installed once at startup and never
/// mutated concurrently with a fault dispatch.
/// Build a `ZapLeakRecord` for a `core.deallocate` fault (canary
/// corruption or size/alignment mismatch) from the staged
/// `FaultAttribution`. The attribution's inline backtrace array is
/// referenced by pointer; the record is consumed synchronously by
/// `dispatchLeakRecord` in the same scope, so the borrow is sound.
fn faultRecord(
    kind: ZapLeakKind,
    user_ptr_value: usize,
    size: usize,
    alignment: u32,
    attribution: *const FaultAttribution,
    canary_offset: usize,
    canary_size: usize,
    supplied_size: usize,
    supplied_alignment: u32,
) ZapLeakRecord {
    return .{
        .kind = @intFromEnum(kind),
        .user_ptr = user_ptr_value,
        .size = size,
        .alignment = alignment,
        // A faulting allocation is still live (preserved for forensics);
        // its construction-site ownership count is 1.
        .refcount = 1,
        .type_name_ptr = if (attribution.type_name_len == 0) null else attribution.type_name_ptr,
        .type_name_len = attribution.type_name_len,
        .backtrace_ptr = if (attribution.backtrace_len == 0) null else &attribution.backtrace,
        .backtrace_len = attribution.backtrace_len,
        .canary_offset = canary_offset,
        .canary_size = canary_size,
        .supplied_size = supplied_size,
        .supplied_alignment = supplied_alignment,
    };
}

fn dispatchLeakRecord(
    tctx: *const TrackingContext,
    record: *const ZapLeakRecord,
    comptime fallback_fmt: []const u8,
    fallback_args: anytype,
) void {
    if (tctx.report_sink) |sink| {
        sink(tctx.report_sink_ctx, record);
    } else {
        printDiagnostic(fallback_fmt, fallback_args);
    }
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
        // Phase 4.c: report the survivor through the runtime's unified
        // renderer (sink) when installed — attributed with the Zap type
        // and the symbolized allocation site — else the legacy raw
        // `LEAK:` line. Tracking declares no REFCOUNT_V1 capability, so
        // every audited allocation flows through `core.allocate` with no
        // side-table refcount; the construction-site ownership count is
        // `1`, which is what the report prints as `refcount 1`.
        const type_name = rec.typeName();
        const record: ZapLeakRecord = .{
            .kind = @intFromEnum(ZapLeakKind.leak),
            .user_ptr = user_ptr_value,
            .size = rec.size,
            .alignment = rec.alignment,
            .refcount = 1,
            .type_name_ptr = if (rec.type_name_len == 0) null else rec.type_name_ptr,
            .type_name_len = rec.type_name_len,
            .backtrace_ptr = if (rec.backtrace_len == 0) null else &rec.backtrace,
            .backtrace_len = rec.backtrace_len,
            .canary_offset = 0,
            .canary_size = 0,
            .supplied_size = 0,
            .supplied_alignment = 0,
        };
        dispatchLeakRecord(
            tctx,
            &record,
            "LEAK: ptr=0x{x}, size={d}, alignment={d}{s}{s}\n",
            .{
                user_ptr_value,
                rec.size,
                rec.alignment,
                if (type_name.len == 0) "" else ", type=",
                type_name,
            },
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
    // Guard the inner allocation size against `usize` overflow. A runtime
    // bug or a corrupted request that drives `size` close to `maxInt(usize)`
    // would otherwise wrap silently into a tiny inner allocation, leaving
    // the canary-fill loops to scribble across unrelated memory. Checked
    // arithmetic short-circuits the path to `return null` so the runtime
    // observes a clean OOM signal (spec §4.3.1) and aborts with the standard
    // diagnostic — matching how the manager already handles a genuine
    // `page_allocator` failure below.
    const total_with_leading = std.math.add(usize, leading_canary_size, size) catch return null;
    const total = std.math.add(usize, total_with_leading, CANARY_SIZE) catch return null;
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

/// Outcome of the deallocation pre-check. Computed inside the spinlock-
/// protected critical section and consumed outside it — both to emit
/// the diagnostic message and to decide whether to proceed with the
/// hash-map removal and inner `rawFree`.
///
/// Keeping the outcome flowing through a small enum (rather than
/// printing directly inside the critical section) closes two latent
/// holes:
///
///   1. `std.debug.print` takes the global stderr mutex while we are
///      holding the manager's spinlock. If another thread is mid-print
///      and waiting on the spinlock for its own deallocate, the two
///      locks invert and one of the threads can stall. Releasing the
///      spinlock first eliminates the inversion entirely.
///   2. On a canary-corruption or size/alignment mismatch we want to
///      preserve the poisoned record for post-mortem inspection rather
///      than recycle the memory back through `page_allocator`. The
///      outcome variant tells the post-critical-section block exactly
///      what to do.
/// Phase 4.c: the Zap type + allocation-site backtrace copied OUT of the
/// `AllocRecord` inside the critical section so the post-lock dispatch can
/// build a `ZapLeakRecord` without re-acquiring the spinlock. The backtrace
/// is copied by value (a fixed inline array) so no pointer into the live
/// map outlives the lock. Empty when the allocation was never annotated.
const FaultAttribution = struct {
    type_name_ptr: [*]const u8 = undefined,
    type_name_len: usize = 0,
    backtrace: [ALLOC_BACKTRACE_MAX_FRAMES]usize = undefined,
    backtrace_len: usize = 0,

    fn fromRecord(rec: AllocRecord) FaultAttribution {
        var attribution: FaultAttribution = .{
            .type_name_ptr = rec.type_name_ptr,
            .type_name_len = rec.type_name_len,
            .backtrace_len = rec.backtrace_len,
        };
        var i: usize = 0;
        while (i < rec.backtrace_len) : (i += 1) attribution.backtrace[i] = rec.backtrace[i];
        return attribution;
    }
};

const DeallocateOutcome = union(enum) {
    /// Pointer was not in the live map. The record was never present —
    /// nothing to remove, nothing to free. Diagnostic carries only the
    /// pointer value.
    invalid_free: struct {
        user_ptr_value: usize,
    },
    /// Recorded size/alignment did not match the runtime-supplied
    /// values. Intentionally leak the inner allocation — the diagnostic
    /// is the actionable signal, and the leak gives the user a stable
    /// address for forensic inspection. The record has been left in
    /// the live map so a subsequent `deinit` walk also reports it as a
    /// leak with the recorded metadata.
    mismatch: struct {
        user_ptr_value: usize,
        recorded_size: usize,
        recorded_alignment: u32,
        supplied_size: usize,
        supplied_alignment: u32,
        attribution: FaultAttribution,
    },
    /// Leading canary was tampered. The record has been LEFT in the
    /// live map and the inner allocation has NOT been freed — the
    /// poisoned bytes stay in place for forensics, and a later
    /// `deinit` walk will also report the allocation as a leak with
    /// the corruption still visible in memory.
    leading_canary_corrupt: struct {
        user_ptr_value: usize,
        offset: usize,
        canary_size: usize,
        recorded_size: usize,
        recorded_alignment: u32,
        attribution: FaultAttribution,
    },
    /// Trailing canary was tampered. Same forensic preservation policy
    /// as `leading_canary_corrupt` — the record is left in the live
    /// map and the inner allocation is not freed.
    trailing_canary_corrupt: struct {
        user_ptr_value: usize,
        offset: usize,
        canary_size: usize,
        recorded_size: usize,
        recorded_alignment: u32,
        attribution: FaultAttribution,
    },
    /// Canaries intact and size/alignment matched. The record was
    /// removed from the live map and `total_bytes` / `inner_alignment`
    /// describe the inner allocation that must be returned to
    /// `page_allocator` outside the critical section.
    clean: struct {
        base_ptr: [*]u8,
        total_bytes: usize,
        inner_alignment: std.mem.Alignment,
    },
};

/// Raw deallocation slot — `core.deallocate` (spec §4.2). The vtable
/// caller hands us the user pointer plus the runtime-recorded size and
/// alignment; we cross-reference the hash-map record, validate the
/// canaries, and dispatch one of:
///
///   * **Invalid free**: pointer is not in the live map. Diagnostic is
///     emitted and the call returns; nothing else changes.
///   * **Size/alignment mismatch**: the runtime supplied values disagree
///     with the recorded ones. We INTENTIONALLY leak the inner
///     allocation — the diagnostic is the actionable signal, and the
///     leaked address gives the user a stable forensic handle.
///   * **Canary corruption**: leading or trailing canary contains a
///     byte that is not `CANARY_BYTE`. We emit the
///     `USE-AFTER-FREE or OOB` diagnostic and INTENTIONALLY leak the
///     poisoned region — the bytes stay in place so the user can dump
///     them later; recycling the memory back through `page_allocator`
///     would let some other allocation reuse the address and erase
///     the evidence.
///   * **Clean free**: canaries intact and size/alignment match. The
///     record is removed from the hash map and the inner allocation
///     is returned to `page_allocator`.
///
/// Two structural rules drive the ordering inside this function:
///
///   1. **Diagnostic message dispatch happens AFTER the spinlock
///      releases.** `std.debug.print` (the default sink) takes the
///      global stderr mutex; holding the spinlock across that mutex
///      acquire risks a lock inversion if another thread is mid-print
///      and waiting on our spinlock. We capture the outcome into a
///      `DeallocateOutcome` value, release the spinlock, then format
///      and emit the diagnostic from a stack-local context.
///   2. **The record is only removed from the hash map after every
///      validation passes.** Earlier revisions used `fetchRemove` up
///      front and then ran the canary checks against the already-
///      detached record; on corruption the record was already gone,
///      which made the resulting program state hard to inspect. The
///      current code uses `getPtr` to read the record without
///      removing it, validates the canaries, and only calls
///      `fetchRemove` on the clean path.
///
/// The spec (§4.2) guarantees `ptr`, `size`, and `alignment` match the
/// values that were passed to `allocate`. We trust `ptr` for the hash
/// lookup; `size` and `alignment` are cross-checked against the
/// recorded values, and a mismatch prints a diagnostic and leaks the
/// allocation (the runtime is expected to be correct here — this
/// catches bugs in the runtime, not in user code).
fn trackingDeallocate(
    ctx: *anyopaque,
    ptr: [*]u8,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    const tctx: *TrackingContext = @ptrCast(@alignCast(ctx));
    const user_ptr_value = @intFromPtr(ptr);

    // ----- critical section -------------------------------------------------
    // Compute the outcome but DO NOT emit any diagnostic from inside this
    // block: `std.debug.print` would take the stderr mutex while we are
    // holding the spinlock, which inverts the lock order with any other
    // thread that is mid-print and waiting on the spinlock.
    spinLock(&tctx.spinlock);
    const outcome: DeallocateOutcome = compute_outcome: {
        const rec_ptr = tctx.live.getPtr(user_ptr_value) orelse {
            break :compute_outcome .{ .invalid_free = .{ .user_ptr_value = user_ptr_value } };
        };
        const rec = rec_ptr.*;

        // Cross-check the runtime-supplied size/alignment against the
        // record. A mismatch indicates a runtime bug; per the docstring
        // above, we LEAK the inner allocation rather than free it. The
        // record stays in the hash map so a later deinit also reports it
        // (with the recorded metadata) — giving the user two diagnostic
        // signals for one runtime bug.
        if (rec.size != size or rec.alignment != alignment) {
            break :compute_outcome .{ .mismatch = .{
                .user_ptr_value = user_ptr_value,
                .recorded_size = rec.size,
                .recorded_alignment = rec.alignment,
                .supplied_size = size,
                .supplied_alignment = alignment,
                .attribution = FaultAttribution.fromRecord(rec),
            } };
        }

        // Validate the leading canary. On corruption, leave the record
        // in place and DO NOT free the inner allocation — the poisoned
        // bytes are the actionable evidence, and recycling them back
        // through `page_allocator` would let another allocation reuse
        // the address before the user gets a chance to inspect it.
        if (findTamperedCanaryByte(rec.base_ptr, rec.leading_canary_size)) |off| {
            break :compute_outcome .{ .leading_canary_corrupt = .{
                .user_ptr_value = user_ptr_value,
                .offset = off,
                .canary_size = rec.leading_canary_size,
                .recorded_size = rec.size,
                .recorded_alignment = rec.alignment,
                .attribution = FaultAttribution.fromRecord(rec),
            } };
        }

        // Validate the trailing canary, with the same preserve-on-
        // corruption policy as the leading canary check.
        const trailing_start = rec.base_ptr + rec.leading_canary_size + rec.size;
        if (findTamperedCanaryByte(trailing_start, CANARY_SIZE)) |off| {
            break :compute_outcome .{ .trailing_canary_corrupt = .{
                .user_ptr_value = user_ptr_value,
                .offset = off,
                .canary_size = CANARY_SIZE,
                .recorded_size = rec.size,
                .recorded_alignment = rec.alignment,
                .attribution = FaultAttribution.fromRecord(rec),
            } };
        }

        // Clean path — every validation passed. Remove the record from
        // the hash map and stage the inner allocation parameters so the
        // post-critical-section block can call `rawFree` outside the
        // spinlock. `fetchRemove` here cannot fail because we just
        // succeeded in `getPtr` and we hold the spinlock that
        // serialises every hash-map mutation.
        const removed = tctx.live.fetchRemove(user_ptr_value).?;
        const total = removed.value.leading_canary_size + removed.value.size + CANARY_SIZE;
        const inner_alignment: std.mem.Alignment = .fromByteUnits(@max(
            removed.value.alignment,
            @as(u32, @intCast(CANARY_SIZE)),
        ));
        break :compute_outcome .{ .clean = .{
            .base_ptr = removed.value.base_ptr,
            .total_bytes = total,
            .inner_alignment = inner_alignment,
        } };
    };
    spinUnlock(&tctx.spinlock);
    // ----- end critical section --------------------------------------------

    // Dispatch the outcome outside the spinlock: diagnostics route through
    // the stderr-taking `std.debug.print` and the clean path returns memory
    // to `page_allocator` (an `mmap`/`munmap` syscall on POSIX). Neither
    // operation needs the spinlock, and both could otherwise contend for
    // unrelated kernel-side locks while we held it.
    switch (outcome) {
        .invalid_free => |info| {
            // An invalid free has no `AllocRecord` (the pointer was never
            // ours), so there is no Zap type / allocation-site backtrace
            // to attribute — the pointer is the only datum.
            const record: ZapLeakRecord = .{
                .kind = @intFromEnum(ZapLeakKind.invalid_free),
                .user_ptr = info.user_ptr_value,
                .size = 0,
                .alignment = 0,
                .refcount = 0,
                .type_name_ptr = null,
                .type_name_len = 0,
                .backtrace_ptr = null,
                .backtrace_len = 0,
                .canary_offset = 0,
                .canary_size = 0,
                .supplied_size = 0,
                .supplied_alignment = 0,
            };
            dispatchLeakRecord(
                tctx,
                &record,
                "INVALID FREE: ptr=0x{x} not allocated by this manager\n",
                .{info.user_ptr_value},
            );
        },
        .mismatch => |info| {
            const record = faultRecord(
                ZapLeakKind.dealloc_mismatch,
                info.user_ptr_value,
                info.recorded_size,
                info.recorded_alignment,
                &info.attribution,
                0,
                0,
                info.supplied_size,
                info.supplied_alignment,
            );
            dispatchLeakRecord(
                tctx,
                &record,
                "DEALLOC SIZE/ALIGN MISMATCH: ptr=0x{x} recorded size={d}/align={d}, runtime supplied size={d}/align={d}; inner allocation intentionally leaked for forensics\n",
                .{
                    info.user_ptr_value,
                    info.recorded_size,
                    info.recorded_alignment,
                    info.supplied_size,
                    info.supplied_alignment,
                },
            );
        },
        .leading_canary_corrupt => |info| {
            const record = faultRecord(
                ZapLeakKind.use_after_free_or_oob,
                info.user_ptr_value,
                info.recorded_size,
                info.recorded_alignment,
                &info.attribution,
                info.offset,
                info.canary_size,
                0,
                0,
            );
            dispatchLeakRecord(
                tctx,
                &record,
                "USE-AFTER-FREE or OOB: leading canary corrupted at ptr=0x{x} (byte {d}/{d}); inner allocation intentionally leaked for forensics\n",
                .{ info.user_ptr_value, info.offset, info.canary_size },
            );
        },
        .trailing_canary_corrupt => |info| {
            const record = faultRecord(
                ZapLeakKind.use_after_free_or_oob,
                info.user_ptr_value,
                info.recorded_size,
                info.recorded_alignment,
                &info.attribution,
                info.offset,
                info.canary_size,
                0,
                0,
            );
            dispatchLeakRecord(
                tctx,
                &record,
                "USE-AFTER-FREE or OOB: trailing canary corrupted at ptr=0x{x} (byte {d}/{d}); inner allocation intentionally leaked for forensics\n",
                .{ info.user_ptr_value, info.offset, info.canary_size },
            );
        },
        .clean => |info| std.heap.page_allocator.rawFree(
            info.base_ptr[0..info.total_bytes],
            info.inner_alignment,
            @returnAddress(),
        ),
    }
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
// ---------------------------------------------------------------------------
// REFCOUNT_V1 panic stubs (Phase 4)
//
// Tracking declares zero capabilities. The runtime's Phase 6 codegen
// elides every retain/release call site under a manager that omits the
// capability, so the stubs below are never invoked in practice. They
// exist solely to give the uniform first-party manager interface a
// complete set of symbols — see the matching section in
// `src/memory/arc/manager.zig` for the full rationale.
// ---------------------------------------------------------------------------

fn trackingRetainStub(ctx: *anyopaque, object: *anyopaque) callconv(.c) void {
    _ = ctx;
    _ = object;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingReleaseStub(
    ctx: *anyopaque,
    object: *anyopaque,
    deep_walk: ?*const fn (object: *anyopaque) callconv(.c) void,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = deep_walk;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingRetainSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) void {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingReleaseSizedStub(
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
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingAllocateRefcountedStub(
    ctx: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) ?[*]u8 {
    _ = ctx;
    _ = size;
    _ = alignment;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

fn trackingRefcountSizedStub(
    ctx: *anyopaque,
    object: *anyopaque,
    size: usize,
    alignment: u32,
) callconv(.c) u32 {
    _ = ctx;
    _ = object;
    _ = size;
    _ = alignment;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSlabClassIndex(comptime size: usize, comptime alignment: u32) ?u32 {
    _ = size;
    _ = alignment;
    return null;
}

pub inline fn allocateRefcountedClass(ctx: *anyopaque, comptime class_index: u32) ?[*]u8 {
    _ = ctx;
    _ = class_index;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn retainSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) void {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
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
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

pub inline fn refcountSizedClass(ctx: *anyopaque, object: *anyopaque, comptime class_index: u32) u32 {
    _ = ctx;
    _ = object;
    _ = class_index;
    @panic("Memory.Tracking does not implement REFCOUNT_V1 — codegen should have elided this call");
}

// ---------------------------------------------------------------------------
// Uniform first-party manager interface (Phase 4)
//
// See the matching section in `src/memory/arc/manager.zig` for the full
// rationale.
// ---------------------------------------------------------------------------

pub const init = trackingInit;
pub const deinit = trackingDeinit;
pub const allocate = trackingAllocate;
pub const deallocate = trackingDeallocate;
pub const allocateRefcounted = trackingAllocateRefcountedStub;
pub const retain = trackingRetainStub;
pub const release = trackingReleaseStub;
pub const retainSized = trackingRetainSizedStub;
pub const releaseSized = trackingReleaseSizedStub;
pub const refcountSized = trackingRefcountSizedStub;
pub const getCapabilityDesc = trackingGetCapabilityDesc;

// Phase 4.c — optional leak-attribution interface. The runtime calls
// these by name through the source-registered `active_manager` import
// (gated by `@hasDecl`), so they need no `.zapmem` capability descriptor:
// the attribution channel is private to the runtime↔manager pair compiled
// into one binary. `annotateAllocation` records the Zap type + alloc-site
// backtrace the runtime captured at the `core.allocate` call site;
// `setLeakReportSink` installs the runtime's unified renderer as the
// deinit-time report sink.
pub const annotateAllocation = trackingAnnotateAllocation;
pub const setLeakReportSink = trackingSetLeakReportSink;

// ---------------------------------------------------------------------------
// Uniform-interface alias signature lock
//
// `Memory.Tracking` does NOT declare REFCOUNT_V1, so the refcount
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

// ---------------------------------------------------------------------------
// Behavioural test scaffolding (in-process)
//
// The integration tests in `src/memory/driver.zig` validate the section/
// symbol pipeline using synthesised objects — they do NOT execute the
// vtable functions in this file. The shell smoke scripts (e.g.
// `scripts/test_tracking_manager_compile.sh`) compile this file as a
// standalone object but only inspect its section layout; they likewise
// do not run the manager.
//
// The tests below exercise the manager's actual runtime behaviour:
// canary-fill on allocate, canary-tamper detection on deallocate, leak
// reporting on deinit, invalid-free detection, and size/alignment
// mismatch reporting. They route every diagnostic through the
// `diagnostic_writer` indirection set up earlier in this file, so each
// test can install a buffer-capturing writer, run the vtable, and
// assert on the captured message.
//
// The tests do not call the runtime's allocator — they construct the
// manager directly through its `trackingInit` / `trackingAllocate` /
// `trackingDeallocate` / `trackingDeinit` entry points, exactly the
// way the runtime would dispatch through the vtable.
// ---------------------------------------------------------------------------

/// Test-only diagnostic capture buffer. Bounded to a fixed stack-allocated
/// byte array so the tests can install a writer that appends formatted
/// diagnostic messages without touching the heap. The fixed cap (4096
/// bytes) is plenty for every diagnostic the manager emits during a
/// single test scenario; the truncation behaviour mirrors the
/// `printDiagnostic` overflow path described above (a marker is written
/// instead of the rest of the message).
const TestCapture = struct {
    /// Backing byte array. 4096 bytes accommodates several allocations'
    /// worth of leak diagnostics (~80 bytes per LEAK line, 50+ lines).
    buffer: [4096]u8 = undefined,
    /// Number of bytes written so far. Reset to zero on `clear()`.
    len: usize = 0,

    fn clear(self: *TestCapture) void {
        self.len = 0;
    }

    fn write(self: *TestCapture, message: []const u8) void {
        const remaining = self.buffer.len - self.len;
        const copy_len = @min(message.len, remaining);
        @memcpy(self.buffer[self.len..][0..copy_len], message[0..copy_len]);
        self.len += copy_len;
    }

    fn slice(self: *const TestCapture) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Module-global capture used by the test diagnostic writer. Tests
/// install `testCaptureWriter` as the active sink, write through the
/// manager's normal `printDiagnostic` path, and read the captured
/// bytes from `test_capture.slice()`.
var test_capture: TestCapture = .{};

/// Diagnostic writer that appends every emitted message into
/// `test_capture`. Replaces `defaultDiagnosticWriter` for the duration
/// of a behavioural test; restored on test exit so subsequent tests
/// (and the production binary) keep using stderr.
fn testCaptureWriter(message: []const u8) void {
    test_capture.write(message);
}

/// Save/restore harness for `diagnostic_writer`. Each test captures
/// the previous sink on entry, installs `testCaptureWriter`, clears
/// the capture buffer, runs the body, and restores the previous sink
/// (typically `defaultDiagnosticWriter`) on exit. The struct is used
/// only inside `test` blocks below.
const TestCaptureGuard = struct {
    previous: DiagnosticWriter,

    fn install() TestCaptureGuard {
        const previous = diagnostic_writer;
        diagnostic_writer = testCaptureWriter;
        test_capture.clear();
        return .{ .previous = previous };
    }

    fn restore(self: TestCaptureGuard) void {
        diagnostic_writer = self.previous;
    }
};

test "trackingAllocate fills leading and trailing canary regions" {
    // The behavioural contract: every allocation must have
    // `CANARY_BYTE` (0xCC) bytes in the leading and trailing canary
    // regions. A regression that skipped the fill would let the
    // tamper-detection path see leftover heap data and either fire
    // false-positive corruption diagnostics or miss real OOB writes.

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;
    defer trackingDeinit(ctx_opaque);

    const ptr = trackingAllocate(ctx_opaque, 64, 8) orelse return error.AllocFailed;

    // The leading-canary region is `max(CANARY_SIZE, alignment)` bytes
    // immediately before the user pointer. For alignment=8 and
    // CANARY_SIZE=16, that's 16 leading bytes.
    const leading_size = computeLeadingCanarySize(8);
    var i: usize = 0;
    while (i < leading_size) : (i += 1) {
        try std.testing.expectEqual(CANARY_BYTE, (ptr - leading_size)[i]);
    }

    // The trailing canary is always CANARY_SIZE bytes starting
    // immediately after the user region.
    i = 0;
    while (i < CANARY_SIZE) : (i += 1) {
        try std.testing.expectEqual(CANARY_BYTE, (ptr + 64)[i]);
    }

    // Hand the allocation back cleanly so trackingDeinit doesn't
    // report a leak.
    trackingDeallocate(ctx_opaque, ptr, 64, 8);
}

test "trackingDeallocate detects trailing canary OOB write" {
    // The behavioural contract: writing past the user region's end
    // tampers a trailing canary byte; deallocate must detect the
    // tamper, emit `USE-AFTER-FREE or OOB: trailing canary corrupted`,
    // and NOT free the inner allocation (the poisoned bytes must
    // remain in place for forensic inspection).

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;

    const ptr = trackingAllocate(ctx_opaque, 64, 8) orelse return error.AllocFailed;
    // Simulate an OOB write one byte past the user region.
    (ptr + 64)[0] = 0x00;

    trackingDeallocate(ctx_opaque, ptr, 64, 8);

    const captured = test_capture.slice();
    try std.testing.expect(std.mem.indexOf(u8, captured, "USE-AFTER-FREE or OOB") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "trailing canary corrupted") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "intentionally leaked for forensics") != null);

    // The corruption-preserve policy means the allocation is STILL in
    // the live map after the deallocate call. Trigger deinit to drain
    // the map (deinit must still free even leaked allocations so the
    // test does not blow the page-allocator's bookkeeping).
    trackingDeinit(ctx_opaque);

    // The deinit walk must have reported the surviving record as a
    // LEAK, doubling the diagnostic signal as the file-level docstring
    // promises.
    const captured_after_deinit = test_capture.slice();
    try std.testing.expect(std.mem.indexOf(u8, captured_after_deinit, "LEAK:") != null);
}

test "trackingDeallocate detects leading canary OOB write" {
    // Mirror of the trailing-canary test for the leading region.
    // A leading-canary tamper indicates an underflow write into the
    // bytes immediately before the user pointer.

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;

    const ptr = trackingAllocate(ctx_opaque, 64, 8) orelse return error.AllocFailed;
    // Simulate an underflow write one byte before the user region.
    const leading_size = computeLeadingCanarySize(8);
    (ptr - leading_size)[0] = 0x00;

    trackingDeallocate(ctx_opaque, ptr, 64, 8);

    const captured = test_capture.slice();
    try std.testing.expect(std.mem.indexOf(u8, captured, "USE-AFTER-FREE or OOB") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "leading canary corrupted") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "intentionally leaked for forensics") != null);

    trackingDeinit(ctx_opaque);
}

test "trackingDeinit reports leaks for allocations that were never freed" {
    // The behavioural contract: any allocation still present in the
    // live map at deinit time is reported via the `LEAK: ptr=0x...`
    // diagnostic and the inner pages are returned to page_allocator.

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;

    const ptr_a = trackingAllocate(ctx_opaque, 32, 8) orelse return error.AllocFailed;
    const ptr_b = trackingAllocate(ctx_opaque, 128, 16) orelse return error.AllocFailed;
    _ = ptr_a;
    _ = ptr_b;

    trackingDeinit(ctx_opaque);

    const captured = test_capture.slice();
    // Two distinct LEAK lines, one per surviving allocation.
    var leak_count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, captured[search_start..], "LEAK:")) |idx| {
        leak_count += 1;
        search_start += idx + "LEAK:".len;
    }
    try std.testing.expectEqual(@as(usize, 2), leak_count);
    // Sanity-check the size/alignment metadata is rendered correctly.
    try std.testing.expect(std.mem.indexOf(u8, captured, "size=32, alignment=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "size=128, alignment=16") != null);
}

test "trackingDeallocate flags a never-allocated pointer as invalid free" {
    // The behavioural contract: a deallocate call whose pointer is
    // not in the live map prints `INVALID FREE` and returns without
    // touching the inner allocator (the pointer might alias anything).

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;
    defer trackingDeinit(ctx_opaque);

    // Fabricate a pointer that the manager has definitely never seen.
    // Using a stack-local byte's address keeps the test self-contained;
    // any pointer that misses the hash map suffices. We treat the
    // pointer's bytes as untouched memory — the manager must NOT free
    // it (the test would corrupt the stack frame otherwise).
    var bogus_byte: u8 = 0;
    const bogus_ptr: [*]u8 = @ptrCast(&bogus_byte);

    trackingDeallocate(ctx_opaque, bogus_ptr, 64, 8);

    const captured = test_capture.slice();
    try std.testing.expect(std.mem.indexOf(u8, captured, "INVALID FREE") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "not allocated by this manager") != null);
}

test "trackingDeallocate flags size or alignment mismatch and leaks the allocation" {
    // The behavioural contract: when the runtime supplies a size or
    // alignment that disagrees with the recorded values, the manager
    // emits `DEALLOC SIZE/ALIGN MISMATCH`, INTENTIONALLY leaks the
    // inner allocation, and leaves the record in the live map so a
    // later `trackingDeinit` walk also reports it as a leak.

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;

    const ptr = trackingAllocate(ctx_opaque, 64, 8) orelse return error.AllocFailed;

    // Hand back a different alignment than was used to allocate. The
    // mismatch is the actionable signal; the manager must not free
    // the allocation with the wrong alignment.
    trackingDeallocate(ctx_opaque, ptr, 64, 16);

    const captured = test_capture.slice();
    try std.testing.expect(std.mem.indexOf(u8, captured, "DEALLOC SIZE/ALIGN MISMATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "recorded size=64/align=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "runtime supplied size=64/align=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, "intentionally leaked for forensics") != null);

    // Deinit drains the leaked record. The accompanying LEAK
    // diagnostic confirms the record was preserved through the
    // mismatch path rather than removed without freeing.
    trackingDeinit(ctx_opaque);

    const captured_after_deinit = test_capture.slice();
    try std.testing.expect(std.mem.indexOf(u8, captured_after_deinit, "LEAK:") != null);
}

test "trackingAllocate returns null when total size would overflow usize" {
    // Phase 7 Gap 6 fix: the total inner allocation size is
    // `leading_canary_size + size + CANARY_SIZE`. A `size` value
    // close to `maxInt(usize)` would silently wrap around under
    // unchecked arithmetic and let the canary-fill loops run beyond
    // the allocated region. `std.math.add` short-circuits the path
    // to `return null` so the runtime observes a clean OOM signal.

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;
    defer trackingDeinit(ctx_opaque);

    // A size that, when added to even a 16-byte leading canary, would
    // exceed `maxInt(usize)`. The exact value is chosen so the first
    // checked-add overflows.
    const huge_size: usize = std.math.maxInt(usize) - 4;
    const result = trackingAllocate(ctx_opaque, huge_size, 8);
    try std.testing.expectEqual(@as(?[*]u8, null), result);
}

test "trackingDeallocate clean path frees inner allocation and removes record" {
    // The happy path: allocate, deallocate with matching size/
    // alignment, deinit. The capture buffer must remain empty
    // throughout — no LEAK, no INVALID FREE, no MISMATCH, no canary
    // corruption diagnostics.

    const guard = TestCaptureGuard.install();
    defer guard.restore();

    const ctx_opaque = trackingInit(null) orelse return error.TrackingInitFailed;
    defer trackingDeinit(ctx_opaque);

    const ptr = trackingAllocate(ctx_opaque, 64, 8) orelse return error.AllocFailed;
    trackingDeallocate(ctx_opaque, ptr, 64, 8);

    try std.testing.expectEqual(@as(usize, 0), test_capture.slice().len);
}
