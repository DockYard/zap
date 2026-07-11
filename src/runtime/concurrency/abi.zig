//! Zap concurrency kernel — C-ABI intrinsic bridge (P2-J1).
//!
//! The minimal `zap_proc_*` intrinsic surface that makes the Phase 1
//! kernel (`concurrency.zig`) callable from Zap user binaries. This file
//! is the ROOT of the kernel compilation unit: the build driver
//! (`src/concurrency_driver.zig`) compiles it per target through the
//! Zig-fork primitive `zap_fork_compile_zig_to_object` — exactly like
//! manager sources (plan §4) — and the resulting object is spliced into
//! the user binary's link line via `zir_compilation_add_link_object_file`
//! when the `runtime_concurrency` gate is ON. The gate is comptime and
//! defaults OFF: no gate, no object, no `zap_proc_*` symbol anywhere in
//! the binary (the plan §3 zero-cost guarantee).
//!
//! ## ABI conventions (mirroring `docs/memory-manager-abi.md`)
//!
//! * Every export is `callconv(.c)` with fixed-width/pointer-only
//!   parameters. No Zig error unions cross the boundary: failures are
//!   signaled by documented sentinel returns (`Pid.invalid` bits = 0 for
//!   pid-returning calls, negative `i32` codes otherwise).
//! * Pids travel as their raw `u64` encoding (`Pid.toBits`); `0` is the
//!   canonical invalid pid (never issued — generation 0 is reserved).
//! * The consuming side of this surface is `src/runtime.zig`'s
//!   comptime-gated `ZapConcurrencyRuntime` extern mirror; the two
//!   declaration sets MUST stay signature-identical (drift fails at link
//!   time or corrupts at runtime — both sides carry this cross-reference).
//! * P2-J2/J3's ZIR lowering calls these intrinsics through the same
//!   extern shapes; nothing here assumes a Zig caller.
//!
//! ## Threading contract (single-scheduler Phase 2 posture)
//!
//! Exactly ONE thread — "the driver thread", the thread that called
//! `zap_proc_runtime_init` — may call `zap_proc_spawn`,
//! `zap_proc_run_until_quiescent`, and `zap_proc_runtime_deinit`.
//! Process-scoped intrinsics run inside process bodies, which execute on
//! that same thread (the kernel's cooperative fibers run on the thread
//! that drives the scheduler). This is the Phase 1 scheduler's own
//! contract (`scheduler.zig` module doc) surfaced through the ABI;
//! Phase 4's M:N scheduler revises it behind the same intrinsic names.
//!
//! ## The current-process handle (plan A.2.4 / A.4.1)
//!
//! Process-scoped intrinsics take an explicit opaque `process` handle —
//! the value the kernel passed to the process entry function. This is
//! the kernel's parameter-threading discipline carried across the C-ABI
//! boundary: no TLS read per intrinsic call. Appendix A.4.1's
//! register-vs-parameter-vs-TLS decision for compiled Zap code stays
//! open; parameter threading is the shape that keeps every option
//! available to P2-J2/J3 (an ambient-lookup variant can be added
//! additively if Phase 2 measurement picks TLS). Passing anything other
//! than the entry-delivered handle is undefined behavior — the handle is
//! a `*ProcessContext` borrowed from the process's own fiber frame.
//!
//! ## Payload seam (P2-J5)
//!
//! `zap_proc_send` carries OPAQUE PAYLOAD BYTES: the deep-copy walker
//! that turns a Zap value graph into a detachable pool-carved fragment
//! is plan item 2.4 (job P2-J5). Until it lands, this bridge copies the
//! caller's bytes into a heap block owned by the message system and
//! tracked in the runtime's payload ledger:
//!
//! * delivered payloads are freed by `zap_proc_envelope_free`;
//! * payloads still sitting in a mailbox when the receiver is torn down
//!   are dead-lettered by the kernel's teardown drain (which frees the
//!   ENVELOPE header back to the pool) and their ledger blocks are
//!   reclaimed at `zap_proc_runtime_deinit` — per-teardown payload
//!   reclamation arrives with P2-J5's pool-carved fragments, which the
//!   envelope pool's abandon/reclaim machinery already accounts for.
//!
//! The ledger is exact: every block is either freed by an
//! `zap_proc_envelope_free` or swept at deinit; the kernel test suite
//! asserts the ledger drains to zero. The ABI contract (opaque bytes in,
//! borrowed `{pointer,length}` view out, receiver frees via
//! `zap_proc_envelope_free`) is unchanged by the P2-J5 replacement.
//!
//! ## Process-heap manager binding (plan item 2.4 / P2-J5)
//!
//! Spawned processes bind the REAL manifest memory manager as their PCB
//! manager context, through the kernel adapter `ManifestManagerBinding`.
//! The gated-on runtime bootstrap (`src/runtime.zig`,
//! `concurrencyStartupForEntry`) hands the kernel the manifest manager's
//! v1.x core vtable + live context via `zap_proc_bind_manager` right after
//! `zap_proc_runtime_init`; `zap_proc_spawn` then binds every process to
//! it. This REPLACED the Phase-1 std-allocator bootstrap arena (the
//! no-fallbacks rule — the placeholder is gone, not layered over), the
//! replacement `process.zig`'s "Manager binding" module doc reserved for
//! this item. Phase-2 is single-model (ARC) and single-scheduler, so the
//! binding is the one shared binary-wide ARC instance and the adapter's
//! `teardown` is a no-op; the per-process private-instance model with a
//! real per-process wholesale free is the documented Phase-3 seam (plan
//! item 3.1). See `ManifestManagerBinding` for the full rationale.
//!
//! ## Exit semantics (Phase 5 seam)
//!
//! `zap_proc_exit` tears the calling process down through the kernel's
//! kill path (`pending_kill` + safepoint yield — the only teardown
//! reachable from arbitrary call depth on a cooperative fiber). Exit
//! REASONS (`:normal` vs abnormal, links/monitors/exit signals) are
//! Phase 5 (plan 5.1); until then an intrinsic exit is indistinguishable
//! from a kill in the scheduler's counters, and a process body that
//! simply returns remains the "normal exit" shape.

const std = @import("std");
const builtin = @import("builtin");
const concurrency = @import("concurrency.zig");

const process_module = @import("process.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const mailbox_module = @import("mailbox.zig");
const pid_table = @import("pid_table.zig");
const trace_module = @import("trace.zig");

/// Backing allocator for every runtime-owned structure this bridge
/// creates (pid table, envelope-pool pages, scheduler records, payload
/// ledger blocks, spawn closures, bootstrap manager states). The page
/// allocator is deliberate: it allocates straight from the OS (mmap),
/// carries no C-runtime init-order dependency, and keeps kernel memory
/// visibly separate from whatever allocator user code links. (Since
/// 7.1a the kernel object always compiles with `link_libc = true` —
/// matching the final binary, so the `std.c` seams the kernel reads
/// resolve on every target — but the page allocator remains the right
/// choice on its own merits, not as a libc workaround.) Page
/// granularity per small block is acceptable at Phase 2 volumes; the
/// P2-J5 fragment walker and the plan-2.4 manager binding replace the
/// two per-message/per-spawn consumers of this allocator.
const backing_allocator = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// C-ABI result codes
// ---------------------------------------------------------------------------

/// `i32` result codes shared by the status-returning intrinsics. Success
/// and domain outcomes are non-negative; failures are negative. The
/// numeric values are ABI — the runtime-side mirror and future ZIR
/// lowering compare against them directly.
pub const ZapProcStatus = struct {
    /// Operation completed (send: message delivered).
    pub const ok: i32 = 0;
    /// Send-only outcome: the target pid did not resolve; the message
    /// was dropped (Erlang dead-letter semantics — not an error).
    pub const dead_lettered: i32 = 1;
    /// String-tier outcome (`zap_blob_string_concat`): the base pointer
    /// is not the calling process's whole-blob-backed string view, so
    /// the blob tier declines and the runtime keeps its ordinary string
    /// path (not an error — the common case for every non-promoted
    /// string).
    pub const string_not_blob_backed: i32 = 2;
    /// The runtime is not initialized (or was already deinitialized).
    pub const not_initialized: i32 = -1;
    /// `zap_proc_runtime_init` was called on an already-live runtime.
    pub const already_initialized: i32 = -2;
    /// Allocation failure inside the runtime.
    pub const out_of_memory: i32 = -3;
    /// `zap_proc_bind_manager` / `zap_proc_register_manager` was handed a core
    /// vtable whose ABI the kernel cannot consume (major != 1, or a sub-v1.0
    /// `size`).
    pub const manager_abi_unsupported: i32 = -4;
    /// `zap_proc_register_manager` / `zap_proc_spawn_at` was given a manager
    /// index outside `[0, MAX_MANAGER_SLOTS)`.
    pub const manager_index_out_of_range: i32 = -5;
    /// A `zap_blob_*` intrinsic was handed a blob handle the calling process
    /// does not own (its ledger holds no reference — a use-after-release, a
    /// forged/re-typed handle, or a release without a matching acquisition).
    /// The runtime surfaces this as a loud panic, never a silent no-op.
    pub const blob_not_owned: i32 = -6;
};

/// The C-ABI process entry shape `zap_proc_spawn` accepts. `process` is
/// the opaque current-process handle (see the module doc) that the body
/// threads into every process-scoped intrinsic; `argument` is the
/// caller's opaque argument, delivered verbatim. Returning from the
/// entry is the normal-exit path.
pub const ZapProcEntry = *const fn (
    process: *anyopaque,
    argument: ?*anyopaque,
) callconv(.c) void;

// ---------------------------------------------------------------------------
// Payload / closure ledger
// ---------------------------------------------------------------------------

/// Header of one runtime-owned heap block (message payload or spawn
/// closure), linked into the runtime's ledger so `zap_proc_runtime_deinit`
/// can sweep blocks whose consuming event never happened (a payload
/// dead-lettered by receiver teardown, a spawn closure whose process was
/// killed before its first quantum). Blocks are the P2-J5 seam described
/// in the module doc. All ledger mutation happens on the driver thread
/// (sends and entry trampolines run on it — threading contract above).
const LedgerBlock = struct {
    previous: ?*LedgerBlock,
    next: ?*LedgerBlock,
    /// Byte length of the caller-visible region that FOLLOWS this header
    /// in the same allocation.
    body_byte_length: usize,

    /// First byte of the caller-visible region.
    fn bodyPointer(block: *LedgerBlock) [*]u8 {
        const raw: [*]u8 = @ptrCast(block);
        return raw + @sizeOf(LedgerBlock);
    }

    /// Recover the header from a caller-visible body pointer.
    fn fromBodyPointer(body: [*]const u8) *LedgerBlock {
        const raw = @intFromPtr(body) - @sizeOf(LedgerBlock);
        return @ptrFromInt(raw);
    }
};

/// Intrusive doubly-linked ledger of live `LedgerBlock`s with an exact
/// count. Driver-thread only.
const Ledger = struct {
    head: ?*LedgerBlock = null,
    live_block_count: usize = 0,
    /// Guards the intrusive list and the count (P4-J1): under M:N a `send` on
    /// any core allocates a payload block here, and a receiver's teardown on any
    /// core frees one, so both ends run cross-thread. A `std.atomic.Mutex`
    /// spinlock by kernel convention; the critical section is O(1) list surgery.
    /// The backing-allocator call itself is done OUTSIDE the lock (it is
    /// page-allocator and thread-safe on its own) so the syscall does not
    /// serialize senders.
    lock: std.atomic.Mutex = .unlocked,

    fn acquire(ledger: *Ledger) void {
        while (!ledger.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn allocate(ledger: *Ledger, body_byte_length: usize) error{OutOfMemory}!*LedgerBlock {
        const raw = backing_allocator.alignedAlloc(
            u8,
            .of(LedgerBlock),
            @sizeOf(LedgerBlock) + body_byte_length,
        ) catch return error.OutOfMemory;
        const block: *LedgerBlock = @ptrCast(@alignCast(raw.ptr));
        ledger.acquire();
        defer ledger.lock.unlock();
        block.* = .{
            .previous = null,
            .next = ledger.head,
            .body_byte_length = body_byte_length,
        };
        if (ledger.head) |head| head.previous = block;
        ledger.head = block;
        ledger.live_block_count += 1;
        return block;
    }

    fn free(ledger: *Ledger, block: *LedgerBlock) void {
        {
            ledger.acquire();
            defer ledger.lock.unlock();
            if (block.previous) |previous| {
                previous.next = block.next;
            } else {
                ledger.head = block.next;
            }
            if (block.next) |next| next.previous = block.previous;
            std.debug.assert(ledger.live_block_count > 0);
            ledger.live_block_count -= 1;
        }
        freeBlockMemory(block);
    }

    fn sweep(ledger: *Ledger) void {
        while (ledger.head) |block| {
            ledger.head = block.next;
            std.debug.assert(ledger.live_block_count > 0);
            ledger.live_block_count -= 1;
            freeBlockMemory(block);
        }
        std.debug.assert(ledger.live_block_count == 0);
    }

    fn freeBlockMemory(block: *LedgerBlock) void {
        const raw: [*]align(@alignOf(LedgerBlock)) u8 = @ptrCast(@alignCast(block));
        backing_allocator.free(raw[0 .. @sizeOf(LedgerBlock) + block.body_byte_length]);
    }
};

// ---------------------------------------------------------------------------
// Real manifest-manager binding (plan item 3.1 / P3-J1 — per-process instances)
// ---------------------------------------------------------------------------
//
// The gated-on runtime bootstrap (`src/runtime.zig`,
// `concurrencyStartupForEntry`) hands the kernel the manifest memory
// manager's v1.x core VTABLE via `zap_proc_bind_manager` immediately after
// `zap_proc_runtime_init`. The binary's manifest model is ARC (single model
// in Phase 3), so this is the real `Memory.ARC` manager's core vtable — the
// seam the `process.zig` "Manager binding" module doc reserves for this item.
//
// Phase-3 per-process-instance discipline (plan item 3.1 — the BEAM model,
// project memory `project_beam_process_memory_model.md`): each process owns
// its OWN manager instance (a private heap), minted at spawn by calling the
// core vtable's `init` (`ManifestManagerBinding.createProcessContext`) and
// stored as the PCB manager context. The adapter's `teardown` performs a
// REAL per-process wholesale free by calling the core vtable's `deinit` on
// that private context — the process's entire heap released in one call
// (cheaper than per-cell release; crash-safe, since a killed process's
// still-live cells are bulk-freed regardless of refcount state). This
// REPLACES the Phase-2 shared-singleton binding whose `teardown` was a
// documented no-op (the no-fallbacks rule — the no-op is gone, not layered
// over): a per-process wholesale free is now correct precisely because each
// process's context is private, so freeing it tears down only that
// process's heap.
//
// The kernel is deliberately manager-agnostic: it calls the ABI's own
// `init`/`deinit`/`allocate`/`deallocate` entry points and never reads the
// manager's identity (it does not know the context is an ARC slab pool).
// The core vtable is one per runtime (Phase-3 single model), so the adapter
// thunks read it from the pinned `runtime_state.manager_binding` rather than
// storing a `{core, ctx}` pair per process; the multi-manager symbol
// families are plan item 3.1's J3 follow-on. Adopting cross-process message
// payloads into a receiver's manager (plan item 2.4, the deep-copy walker)
// uses the runtime's ARC allocation path directly (`src/runtime.zig`), which
// in Phase 3 routes to the receiver process's OWN private context through the
// scheduler-published `zap_proc_active_arc_context` (`process.zig`) — not
// this kernel-side adapter, because materializing typed Zap cells needs the
// runtime value representation the kernel is deliberately free of.

/// Locally-redeclared v1.0 prefix of the memory-manager core vtable
/// (`docs/memory-manager-abi.md` §4; canonical Zig definition in
/// `src/memory/abi.zig`, self-contained ARC copy in
/// `src/memory/arc/manager.zig`). The kernel adapter calls
/// `init`/`deinit`/`allocate`/`deallocate` — `init`/`deinit` are the
/// Phase-3 per-process-instance factory (`ManifestManagerBinding` calls
/// `init` once per spawn to mint a fresh private heap and `deinit` once at
/// teardown for the real wholesale free), so they are now real typed
/// pointers rather than the Phase-2 opaque placeholders.
/// `get_capability_desc` is typed as of P6-J4: `createProcessBinding` probes
/// it once per spawn for the descriptor-only `ARSR` (watermark/reset — the
/// receive-back-edge arena auto-reset) and `STAT` (heap-bytes observability)
/// capabilities (spec §7.2/§9/§10). Redeclared per the
/// self-contained-manager convention (spec §11.1.1); the `comptime` layout
/// asserts below catch drift from the canonical definition. A newer-minor
/// manager advertises a larger `size` and appends trailing fields (spec
/// §2.3); the kernel reads only this v1.0 prefix, so it stays
/// forward-compatible.
const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (options: ?*const anyopaque) callconv(.c) ?*anyopaque,
    deinit: *const fn (context: *anyopaque) callconv(.c) void,
    allocate: *const fn (context: *anyopaque, byte_length: usize, alignment: u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (context: *anyopaque, memory: [*]u8, byte_length: usize, alignment: u32) callconv(.c) void,
    get_capability_desc: *const fn (context: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1,
};

/// Locally-redeclared `ZapCapabilityDescV1` (spec §5; canonical definition in
/// `src/memory/abi.zig`) — the record `get_capability_desc` answers with.
const ZapCapabilityDescV1 = extern struct {
    id: u32,
    version: u16,
    size: u16,
    flags: u32,
    vtable: *const anyopaque,
};

/// Locally-redeclared `ZapArenaWatermarkV1` (spec §9): a BULK_OR_NEVER
/// manager's opaque bulk-set position. The kernel stores one per process
/// binding (captured at the first proven receive-back-edge reset) and only
/// round-trips it — the four words are manager-private.
const ZapArenaWatermarkV1 = extern struct {
    chunk: ?*anyopaque,
    bump_cursor: usize,
    chunk_end: usize,
    next_chunk_size: usize,
};

/// Locally-redeclared `ZapArenaResetCapabilityV1` (spec §9) — the
/// descriptor-only `ARSR` watermark/reset capability.
const ZapArenaResetCapabilityV1 = extern struct {
    watermark: *const fn (context: *anyopaque, out_watermark: *ZapArenaWatermarkV1) callconv(.c) void,
    reset_to_watermark: *const fn (context: *anyopaque, watermark: *const ZapArenaWatermarkV1) callconv(.c) void,
};

/// Locally-redeclared `ZapStatsCapabilityV1` (spec §10) — the
/// descriptor-only `STAT` heap-bytes observability capability.
const ZapStatsCapabilityV1 = extern struct {
    heap_byte_count: *const fn (context: *anyopaque) callconv(.c) usize,
};

/// `ARSR` capability tag at the target's native endianness (spec §7.1/§9;
/// mirrors `src/memory/abi.zig`'s `ARSR_TAG` — the correspondence is locked
/// by the layout-assert discipline plus the round-trip test below).
const ARSR_TAG: u32 = std.mem.readInt(u32, "ARSR", builtin.target.cpu.arch.endian());

/// `STAT` capability tag at the target's native endianness (spec §7.1/§10).
const STAT_TAG: u32 = std.mem.readInt(u32, "STAT", builtin.target.cpu.arch.endian());

comptime {
    const ptr = @sizeOf(*const anyopaque);
    // 16-byte integer prefix + five pointer-width slots (spec §4 core
    // vtable layout; mirrors the assert in src/memory/arc/manager.zig).
    if (@sizeOf(ZapMemoryManagerCoreV1) != std.mem.alignForward(usize, 16 + 5 * ptr, @alignOf(ZapMemoryManagerCoreV1)))
        @compileError("abi: ZapMemoryManagerCoreV1 must be its 16-byte prefix plus five pointers");
    if (@offsetOf(ZapMemoryManagerCoreV1, "allocate") != 16 + 2 * ptr)
        @compileError("abi: ZapMemoryManagerCoreV1.allocate offset drift");
    if (@offsetOf(ZapMemoryManagerCoreV1, "deallocate") != 16 + 3 * ptr)
        @compileError("abi: ZapMemoryManagerCoreV1.deallocate offset drift");
    if (@offsetOf(ZapMemoryManagerCoreV1, "get_capability_desc") != 16 + 4 * ptr)
        @compileError("abi: ZapMemoryManagerCoreV1.get_capability_desc offset drift");
    // Descriptor + P6-J4 capability mirrors (spec §5/§9/§10 layouts, matching
    // the canonical asserts in src/memory/abi.zig).
    if (@sizeOf(ZapCapabilityDescV1) != std.mem.alignForward(usize, 12, ptr) + ptr)
        @compileError("abi: ZapCapabilityDescV1 must be its integer prefix plus one pointer");
    if (@sizeOf(ZapArenaWatermarkV1) != 4 * ptr)
        @compileError("abi: ZapArenaWatermarkV1 must be exactly four pointer-width words");
    if (@sizeOf(ZapArenaResetCapabilityV1) != 2 * ptr)
        @compileError("abi: ZapArenaResetCapabilityV1 must be exactly two pointer slots wide");
    if (@sizeOf(ZapStatsCapabilityV1) != 1 * ptr)
        @compileError("abi: ZapStatsCapabilityV1 must be exactly one pointer slot wide");
}

/// Number of manager slots the per-spawn manager registry holds (plan item
/// 3.1/3.3, P3-J3). Index 0 is ALWAYS the manifest default manager (bound by
/// the runtime bootstrap through `zap_proc_bind_manager`); indices 1.. are the
/// distinct non-manifest managers referenced by `spawn(f, .{ .manager = X })`
/// sites, each registered by the runtime from the compiler-generated manager
/// registry module (`zap_manager_registry`, `src/runtime.zig`). The bound is
/// generous relative to the number of distinct reclamation-model backends a
/// real program selects; a program referencing more managers than this fails
/// registration loudly rather than silently overflowing.
const MAX_MANAGER_SLOTS: u32 = 16;

/// Per-process manager binding: the manager's core vtable plus the fresh
/// private per-process context minted from it at spawn (plan item 3.1/3.3).
///
/// `ManagerContext.manager_state` points at one of these. The kernel-side
/// per-process vtable thunks below unpack it to route this process's
/// `allocate`/`deallocate`/wholesale-`teardown` to ITS manager on ITS private
/// heap; the runtime reads the SAME `{core, context}` pair (published per
/// quantum via the scheduler as `manager.manager_state`) so a process's
/// compiled-code allocations land in its own manager's heap — the multi-
/// manager per-process dispatch that lets an ARC process and an Arena process
/// coexist in one binary.
///
/// The layout is FROZEN in its two-field PREFIX and mirrored on the runtime
/// side (`src/runtime.zig`, `ProcessManagerBinding`): `core` first, `context`
/// second, both non-optional (a bound process always has both). `extern
/// struct` pins the field order. The runtime mirror reads ONLY that prefix
/// from the published pointer, so the P6-J4 fields appended after it are
/// kernel-private and prefix-compatible by construction (the §2.3 trailing-
/// extension discipline applied to an internal struct).
const ProcessManagerBinding = extern struct {
    core: *const ZapMemoryManagerCoreV1,
    context: *anyopaque,
    // -- P6-J4 kernel-private extension (never read by the runtime mirror) --
    /// The manager's `ARSR` watermark/reset capability, discovered once at
    /// spawn (`createProcessBinding`), or null when the manager does not
    /// expose it (every non-Arena first-party manager). Null keeps the
    /// receive-back-edge reset a no-op — the sound conservative default.
    arena_reset: ?*const ZapArenaResetCapabilityV1,
    /// The manager's `STAT` heap-bytes capability, discovered once at spawn,
    /// or null (heap-byte queries then report 0, the pre-P6-J4 behavior).
    stats: ?*const ZapStatsCapabilityV1,
    /// The iteration watermark for the receive-back-edge auto-reset: captured
    /// by the FIRST `iterationHeapReset` call (the process's first proven
    /// receive), then bulk-reset back to by every later call. Owner-only,
    /// like the allocation path (the reset thunk runs on the thread driving
    /// the process's quantum). Meaningful only when
    /// `iteration_watermark_captured` is true.
    iteration_watermark: ZapArenaWatermarkV1,
    /// Whether `iteration_watermark` has been captured (see above).
    iteration_watermark_captured: bool,
};

/// The per-process `ManagerVTable` every production (non-test) process
/// dispatches its cold-path allocate/deallocate/teardown through. Unlike the
/// Phase-3 single-model binding it replaces (which read one shared core from
/// the runtime), each thunk reads the PROCESS'S OWN core from the
/// `ProcessManagerBinding` in `manager_state`, so distinct-model processes in
/// one binary each dispatch to their own manager (no-fallbacks: the shared
/// `sharedCore()` singleton is gone, not layered over).
const process_manager_vtable = process_module.ManagerVTable{
    .allocate = processAllocateThunk,
    .deallocate = processDeallocateThunk,
    .teardown = processTeardownThunk,
    .heapByteCount = processHeapByteCountThunk,
    .iterationHeapReset = processIterationHeapResetThunk,
};

fn processBinding(manager_state: ?*anyopaque) *ProcessManagerBinding {
    return @ptrCast(@alignCast(manager_state.?));
}

/// Mint a FRESH private per-process binding for `core`: call the core vtable's
/// `init` to create this process's private heap, then wrap `{core, context}`
/// in a heap-allocated `ProcessManagerBinding` handed to `scheduler.spawn` as
/// the `ManagerContext`. Returns null if `init` fails (out of memory) or the
/// binding allocation fails — the caller surfaces it as spawn failure and no
/// heap leaks (the context is torn down on the binding-allocation failure
/// path). `teardown` wholesale-frees the context via `deinit` and releases the
/// binding.
fn createProcessBinding(core: *const ZapMemoryManagerCoreV1) ?process_module.ManagerContext {
    const context = core.init(null) orelse return null;
    const binding = backing_allocator.create(ProcessManagerBinding) catch {
        core.deinit(context);
        return null;
    };
    binding.* = .{
        .core = core,
        .context = context,
        // Descriptor-only capability discovery (spec §7.2): one probe per
        // capability per SPAWN, never on a hot path. A manager without the
        // descriptor keeps the sound defaults (no-op reset, 0 heap bytes).
        .arena_reset = discoverCapabilityVtable(ZapArenaResetCapabilityV1, core, context, ARSR_TAG),
        .stats = discoverCapabilityVtable(ZapStatsCapabilityV1, core, context, STAT_TAG),
        .iteration_watermark = .{ .chunk = null, .bump_cursor = 0, .chunk_end = 0, .next_chunk_size = 0 },
        .iteration_watermark_captured = false,
    };
    return .{ .manager_state = binding, .vtable = &process_manager_vtable };
}

/// Probe `core.get_capability_desc(tag)` and validate the answer against the
/// expected v1 vtable shape (spec §5.1 selection rules, restricted to the one
/// version the kernel understands): matching id, version 1, and a `size`
/// covering at least the slots the kernel reads. Any mismatch — including a
/// manager that answers with a FUTURE version only — resolves to null, i.e.
/// "capability absent", the conservative degradation the spec prescribes for
/// an older consumer.
fn discoverCapabilityVtable(
    comptime CapabilityVtable: type,
    core: *const ZapMemoryManagerCoreV1,
    context: *anyopaque,
    tag: u32,
) ?*const CapabilityVtable {
    const desc = core.get_capability_desc(context, tag) orelse return null;
    if (desc.id != tag) return null;
    if (desc.version != 1) return null;
    if (desc.size < @sizeOf(CapabilityVtable)) return null;
    return @ptrCast(@alignCast(desc.vtable));
}

fn processAllocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const binding = processBinding(manager_state);
    return binding.core.allocate(binding.context, byte_length, @intCast(alignment.toByteUnits()));
}

fn processDeallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
    const binding = processBinding(manager_state);
    binding.core.deallocate(binding.context, memory, byte_length, @intCast(alignment.toByteUnits()));
}

/// The REAL per-process wholesale free (plan item 3.1): release this process's
/// entire private heap in one call via the core vtable's `deinit`, then free
/// the binding. Sound and crash-safe: the context is private to this process,
/// so `deinit` tears down only its heap — every still-live cell (a cleanly
/// exited process has none; a killed one may have many) is bulk-reclaimed.
fn processTeardownThunk(manager_state: ?*anyopaque) void {
    const binding = processBinding(manager_state);
    binding.core.deinit(binding.context);
    backing_allocator.destroy(binding);
}

/// Per-process heap bytes (plan item 1.6), resolved through the manager's
/// descriptor-only `STAT` capability when it provides one (spec §10; the
/// first-party Arena reports reserved chunk bytes through an atomic counter,
/// so this is safe to call from any thread — introspection snapshots read
/// other processes' managers). A manager without `STAT` reports 0, the
/// pre-P6-J4 advisory behavior; teardown returns the whole heap regardless.
fn processHeapByteCountThunk(manager_state: ?*anyopaque) usize {
    const binding = processBinding(manager_state);
    const stats = binding.stats orelse return 0;
    return stats.heap_byte_count(binding.context);
}

/// The receive-back-edge arena auto-reset (plan item 6.4, P6-J4). Reached
/// ONLY through `zap_proc_receive_iteration_reset`, which the compiler emits
/// solely at receive sites whose iteration closure it PROVED
/// (`src/receive_reset.zig`) — the soundness precondition for the bulk free
/// below. Per-model semantics (documented on `ManagerVTable.iterationHeapReset`):
///
///   * Manager WITHOUT `ARSR` (ARC/ORC/Tracking/GC/Leak/NoOp): no-op.
///     REFCOUNTED models already reclaimed each iteration's garbage
///     deterministically through drops; Tracking frees at last use;
///     Leak/NoOp never reclaim by design. Nothing to bulk-free.
///   * Manager WITH `ARSR` (Arena — BULK_OR_NEVER): the FIRST call captures
///     the iteration watermark (the boundary between spawn-era state and
///     iteration-era garbage — everything the process allocated before its
///     first proven receive stays untouched forever); every LATER call
///     bulk-frees back to it in O(chunks-allocated-since). This is what
///     bounds a long-lived Arena server's heap (the §2.4 growth warning):
///     message adoptions, handler temporaries, and reply staging from
///     iteration i are wholesale-reclaimed when iteration i+1 reaches the
///     receive point.
///
/// Owner-only: runs on the thread driving the process's quantum, exactly
/// like the allocate path.
fn processIterationHeapResetThunk(manager_state: ?*anyopaque) void {
    const binding = processBinding(manager_state);
    const reset = binding.arena_reset orelse return;
    if (!binding.iteration_watermark_captured) {
        reset.watermark(binding.context, &binding.iteration_watermark);
        binding.iteration_watermark_captured = true;
        return;
    }
    reset.reset_to_watermark(binding.context, &binding.iteration_watermark);
}

// ---------------------------------------------------------------------------
// declared_caps → reclamation model decode (pid model bits — plan §2.4, J3)
//
// The pid packs a 2-bit reclamation-model field (`pid_table.ReclamationModel`)
// that a sender reads together with the generation (§2.4 invariant). J3 makes
// those bits LIVE: the model is decoded from the SELECTED manager's
// `declared_caps` at spawn and stamped into the pid. The kernel is a
// self-contained source tree (`concurrency.zig` doc) and cannot import the
// compiler's `src/memory/elision.zig`, so this decode is redeclared here and
// asserted name-for-name equivalent to `elision.reclamationModel` /
// `src/memory/abi.zig`'s axis encoding by the `capsModelCorrespondence` test
// below (the plan item 3.3 correspondence seam the `pid_table` doc reserves).
// ---------------------------------------------------------------------------

/// `REFCOUNT_V1` capability flag — bit 0 of `declared_caps` (spec §7.1).
const CAPS_REFCOUNT_V1_BIT: u64 = 0x1;
/// Low bit of the 2-bit Axis-A reclamation-model field within `declared_caps`.
const CAPS_RECLAMATION_MODEL_SHIFT: u6 = 1;
/// Width mask (pre-shift) of the Axis-A reclamation-model field.
const CAPS_RECLAMATION_MODEL_MASK: u64 = 0b11;

/// Decode a manager's `declared_caps` into the pid reclamation-model bits.
/// Mirrors `elision.reclamationModel`: bit 0 set ⇒ `refcounted`; otherwise the
/// Axis-A field selects the model, with the reserved `0b11` code mapping
/// conservatively to `bulk_or_never` (elide all individual frees).
fn reclamationModelForCaps(declared_caps: u64) pid_table.ReclamationModel {
    if ((declared_caps & CAPS_REFCOUNT_V1_BIT) != 0) return .refcounted;
    return switch ((declared_caps >> CAPS_RECLAMATION_MODEL_SHIFT) & CAPS_RECLAMATION_MODEL_MASK) {
        0b00 => .bulk_or_never,
        0b01 => .individual_no_refcount,
        0b10 => .traced,
        0b11 => .bulk_or_never,
        else => unreachable,
    };
}

/// Capability matrix (plan item 3.5): whether reclamation `model` is SOUND to
/// run on THIS build's target. Comptime on `builtin.target` — the kernel object
/// is compiled per user-binary target, so this reflects the final binary's OS.
///
/// TRACED (conservative stop-the-world mark-sweep) has no COFF/PE global/stack
/// scanner on Windows and is architecturally impossible on WebAssembly's
/// linear-memory model (no raw machine stack to scan). Per the cross-compile
/// requirement EVERY manager backend must stay PRESENT/linkable in EVERY target
/// binary (a process might spawn any), so an impossible combo is a RUNTIME
/// spawn error here — NOT a compile-time exclusion of the backend. Every other
/// model is sound on every target. The build-time driver
/// (`enforceManagerTargetSupport`) applies the SAME predicate to reject the
/// statically-known MANIFEST default early; this is its per-process twin.
fn managerModelSoundOnTarget(model: pid_table.ReclamationModel) bool {
    if (model != .traced) return true;
    return switch (builtin.target.os.tag) {
        .windows, .wasi => false,
        else => true,
    };
}

// ---------------------------------------------------------------------------
// Spawn closure trampoline
// ---------------------------------------------------------------------------

/// Ledger-tracked bridge from the kernel's Zig entry shape to the C-ABI
/// `ZapProcEntry`: the closure body carries the C entry pointer and its
/// argument. The trampoline detaches the closure from the ledger before
/// invoking the C entry; a process killed while still queued never runs
/// the trampoline, and its closure is swept at deinit (module doc,
/// payload/closure ledger).
const SpawnClosure = struct {
    c_entry: ZapProcEntry,
    c_argument: ?*anyopaque,
};

fn spawnTrampoline(context: *concurrency.ProcessContext, argument: ?*anyopaque) void {
    const block: *LedgerBlock = @ptrCast(@alignCast(argument.?));
    const closure: *SpawnClosure = @ptrCast(@alignCast(block.bodyPointer()));
    const c_entry = closure.c_entry;
    const c_argument = closure.c_argument;
    runtime_state.ledger.free(block);
    c_entry(@ptrCast(context), c_argument);
}

// ---------------------------------------------------------------------------
// Runtime singleton
// ---------------------------------------------------------------------------

/// The binary-wide runtime instance `zap_proc_runtime_init` owns
/// (deliverable: "owning the scheduler instance for the binary").
/// Instance-based kernel structures behind a single process-wide
/// binding; Phase 4 multiplies scheduler instances over the shared pid
/// table and envelope pool without changing this ABI.
const RuntimeState = struct {
    pid_table: concurrency.PidTable,
    envelope_pool: concurrency.EnvelopePool,
    /// The scheduler backend over the shared pid table + envelope pool: the
    /// production M:N pool by default, or — when `ZAP_SCHED_SEED` is set — the
    /// seeded deterministic M:N simulator (P4-J4). Both drive the SAME
    /// instance-based `Scheduler` cores and honor the SAME `zap_proc_*`
    /// intrinsics; only the driver differs (real OS threads vs a single-threaded
    /// seed-reproducible interleaving). See `SchedulerBackend`.
    backend: SchedulerBackend,
    ledger: Ledger,
    /// The kernel signal runtime (P5-J1, `signal.zig`): the shared link/monitor
    /// node pool, the reason-atom registry, and the exit/`DOWN` payload seam
    /// (wired to `ledger` below). Shared across every scheduler core via
    /// `Scheduler.Options.signal_runtime`.
    signal_runtime: concurrency.SignalRuntime,
    /// The local process registry (P5-J2, `registry.zig`): the shared
    /// name→pid table `Process.register`/`whereis`/`unregister` and send-by-name
    /// stand on. Shared across every scheduler core via
    /// `Scheduler.Options.registry`; validated against `pid_table` for liveness.
    registry: concurrency.ProcessRegistry,
    /// The `Zap.Blob` allocation domain + persistent-term registry (P6-J2,
    /// `blob.zig`): THE one sanctioned atomically-refcounted share tier.
    /// Owned by the runtime (blob payloads belong to NEITHER process's
    /// manager — the envelope-pool third-allocation-domain discipline),
    /// shared across every scheduler core via `Scheduler.Options.blob_domain`
    /// (teardown ledger drains), and torn down leak-exactly at
    /// `zap_proc_runtime_deinit` (its `deinit` releases the registry's
    /// references and asserts zero live blobs).
    blob_domain: concurrency.BlobDomain,
    /// The per-spawn manager registry (plan item 3.1/3.3, P3-J3): core
    /// vtables indexed by manager id. Slot 0 is the manifest default (bound by
    /// `zap_proc_bind_manager`); slots 1.. are the distinct `spawn(f, .{
    /// .manager = X })` managers registered from the compiler-generated
    /// registry module. `zap_proc_spawn_at` mints a fresh private per-process
    /// context from the slot's core. Null slots are unregistered. Replaces the
    /// Phase-3 single `manager_binding` singleton (no-fallbacks: the singleton
    /// is gone, not layered over).
    manager_registry: [MAX_MANAGER_SLOTS]?*const ZapMemoryManagerCoreV1,
};

/// The scheduler backend the runtime drives. Selected once at
/// `zap_proc_runtime_init` and fixed for the runtime's lifetime; every
/// `zap_proc_*` intrinsic that reaches the scheduler goes through these
/// helpers, so the two backends are interchangeable behind the ABI.
///
/// The seeded backend (P4-J4, plan item 4.4) is the payoff of exposing the
/// seeded deterministic scheduler to the Zap layer: with `ZAP_SCHED_SEED` set,
/// a concurrency program (or Zest concurrency suite) runs as a single-threaded,
/// seed-reproducible M:N interleaving — a failing run replays EXACTLY by
/// re-running with the same seed. P2-J8 deferred this on two obstacles;
/// P4-J1's `Scheduler.currentThreadScheduler` (which the simulator publishes
/// per step via `swapCurrentThreadScheduler`) resolves the first
/// (scheduler-relative process intrinsics — `zap_proc_current`/`zap_proc_spawn`
/// resolve on the stepping core exactly as under the pool). The residual
/// constraint is scope, not mechanism: the runtime is a process-wide singleton,
/// so a seeded run is whole-program; a sibling test that asserts a PRODUCTION
/// interleaving (e.g. `test_concurrency/safepoint_test.zap`'s "quick replies
/// before slow" ordering) can be legitimately violated by a seeded schedule, so
/// seeded runs target interleaving-ROBUST tests (invariants that hold under any
/// schedule — ping-pong, pairwise FIFO, teardown exactness, after-timeout),
/// while ordering-assertion tests stay in the default production run.
const SchedulerBackend = union(enum) {
    /// Production: the M:N work-stealing pool (P4-J1) over real OS threads
    /// (default = CPU count). An in-process spawn routes to the running core, an
    /// external spawn to core 0.
    production_pool: concurrency.SchedulerPool,
    /// Seeded deterministic M:N simulator (P4-J4): N logical cores on ONE
    /// thread, every scheduling decision a pure function of the seed. Owned
    /// (heap-allocated by `MnSimulator.create`); borrows the runtime's pid table
    /// + envelope pool.
    seeded_simulator: *concurrency.MnSimulator,

    /// The core an external (driver-thread) spawn admits to.
    fn primaryCore(backend: *SchedulerBackend) *concurrency.Scheduler {
        return switch (backend.*) {
            .production_pool => |*pool| pool.primaryCore(),
            .seeded_simulator => |simulator| simulator.primaryCore(),
        };
    }

    /// Drive until every process has exited. A seeded run that deadlocks
    /// (`AllProcessesWaiting`) terminates here instead of hanging — the seed
    /// reproduces the deadlock; stragglers are reaped at deinit (Erlang halt).
    fn runUntilQuiescent(backend: *SchedulerBackend) void {
        switch (backend.*) {
            .production_pool => |*pool| pool.runUntilQuiescent(),
            .seeded_simulator => |simulator| simulator.runToQuiescence() catch {},
        }
    }

    /// Drive until `root` exits (Erlang halt model).
    fn runUntilRootExits(backend: *SchedulerBackend, root: concurrency.Pid) void {
        switch (backend.*) {
            .production_pool => |*pool| pool.runUntilRootExits(root),
            .seeded_simulator => |simulator| simulator.runUntilRootExits(root) catch {},
        }
    }

    /// Reap every straggler and tear the backend down (`runtime_deinit`).
    fn shutdownAndDeinit(backend: *SchedulerBackend) void {
        switch (backend.*) {
            .production_pool => |*pool| {
                pool.shutdownAllProcesses();
                pool.deinit();
            },
            .seeded_simulator => |simulator| simulator.destroy(),
        }
    }
};

/// Read `ZAP_SCHED_SEED` — the opt-in seeded deterministic scheduler seam
/// (P4-J4). Null (unset/empty/unparseable) selects the production pool. Accepts
/// decimal or `0x`-prefixed hex (base 0). Uses `std.c.getenv`, matching the
/// kernel's other env knobs (module doc: the Linux CI leg links libc).
fn readSeededSchedulerSeed() ?u64 {
    const raw = std.c.getenv("ZAP_SCHED_SEED") orelse return null;
    const text = std.mem.sliceTo(raw, 0);
    if (text.len == 0) return null;
    return std.fmt.parseInt(u64, text, 0) catch null;
}

/// Read `ZAP_SCHED_CORES` — the number of logical cores the seeded simulator
/// models. Default 2 (the smallest genuinely-M:N configuration); clamped ≥ 1.
fn readSeededSchedulerCoreCount() usize {
    const default_core_count: usize = 2;
    const raw = std.c.getenv("ZAP_SCHED_CORES") orelse return default_core_count;
    const text = std.mem.sliceTo(raw, 0);
    const parsed = std.fmt.parseInt(usize, text, 10) catch return default_core_count;
    return @max(parsed, 1);
}

/// Read `ZAP_DEADLOCK_ACTION` — what the pool does after DETECTING a
/// system deadlock (P6-J6, plan item 6.5): `continue` (the default —
/// report once to stderr and stay parked, BEAM-compatible-plus-diagnostic),
/// `stop` (stop the pool; the run returns and stragglers are reaped at
/// deinit), or `panic` (fail fast, non-zero exit — legitimate because a
/// detected deadlock is permanent: no external wake source exists).
/// Unknown values keep the default.
fn readDeadlockAction() concurrency.DeadlockAction {
    const raw = std.c.getenv("ZAP_DEADLOCK_ACTION") orelse return .report_and_continue;
    const text = std.mem.sliceTo(raw, 0);
    if (std.mem.eql(u8, text, "stop")) return .report_and_stop;
    if (std.mem.eql(u8, text, "panic")) return .report_and_panic;
    return .report_and_continue;
}

var runtime_state_storage: RuntimeState = undefined;
var runtime_initialized: bool = false;

/// Alias so kernel-internal code reads through one name. The scheduler
/// is PINNED after the first spawn (records hold back-pointers), which a
/// global satisfies by construction.
const runtime_state = &runtime_state_storage;

/// Test/observability hook: live blocks in the payload/closure ledger.
/// Not exported — kernel tests assert the exactness contract with it.
pub fn payloadLedgerLiveBlockCount() usize {
    return runtime_state.ledger.live_block_count;
}

/// Test/observability hook: whether the runtime is currently live.
pub fn runtimeIsInitialized() bool {
    return runtime_initialized;
}

fn contextFromHandle(process: *anyopaque) *concurrency.ProcessContext {
    return @ptrCast(@alignCast(process));
}

// ---------------------------------------------------------------------------
// Signal payload seam (P5-J1): an exit/`DOWN` message payload lives in a ledger
// block so the receiver's ordinary `zap_proc_envelope_free` reclaims it exactly
// like a copied user payload. The scheduler allocates/frees through these hooks
// (it cannot reach the ledger directly); `installSignalRuntime` wires them.
// ---------------------------------------------------------------------------

fn signalPayloadAllocate(context: ?*anyopaque, byte_length: usize) callconv(.c) ?[*]u8 {
    _ = context;
    const block = runtime_state.ledger.allocate(byte_length) catch return null;
    return block.bodyPointer();
}

fn signalPayloadFree(context: ?*anyopaque, body: [*]const u8, byte_length: usize) callconv(.c) void {
    _ = context;
    _ = byte_length;
    runtime_state.ledger.free(LedgerBlock.fromBodyPointer(body));
}

/// Install the shared signal runtime (node pool + reason registry + payload
/// seam) BEFORE the scheduler backend is created, so `&runtime_state.signal_
/// runtime` is a wired, stable pointer to hand every core.
fn installSignalRuntime() void {
    runtime_state.signal_runtime = concurrency.SignalRuntime.init(backing_allocator);
    runtime_state.signal_runtime.payload_seam = .{
        .context = null,
        .allocate = signalPayloadAllocate,
        .free = signalPayloadFree,
    };
}

// ---------------------------------------------------------------------------
// Intrinsics — runtime lifecycle (driver thread)
// ---------------------------------------------------------------------------

/// Initialize the binary-wide concurrency runtime: pid table (BEAM-default
/// capacity), shared envelope pool, and the single Phase 2 scheduler.
/// Must complete before any other `zap_proc_*` call. The calling thread
/// becomes the driver thread (module doc, threading contract).
///
/// Returns `ZapProcStatus.ok`, `already_initialized`, or `out_of_memory`.
export fn zap_proc_runtime_init() callconv(.c) i32 {
    if (runtime_initialized) return ZapProcStatus.already_initialized;

    runtime_state.ledger = .{};
    runtime_state.manager_registry = @splat(null);
    runtime_state.pid_table = concurrency.PidTable.init(backing_allocator, .{}) catch
        return ZapProcStatus.out_of_memory;
    runtime_state.envelope_pool = concurrency.EnvelopePool.init(backing_allocator, .{});
    installSignalRuntime();
    runtime_state.registry = concurrency.ProcessRegistry.init(backing_allocator, .{}) catch {
        runtime_state.signal_runtime.deinit();
        runtime_state.envelope_pool.deinit();
        runtime_state.pid_table.deinit();
        return ZapProcStatus.out_of_memory;
    };
    runtime_state.blob_domain = concurrency.BlobDomain.init() catch {
        runtime_state.registry.deinit();
        runtime_state.signal_runtime.deinit();
        runtime_state.envelope_pool.deinit();
        runtime_state.pid_table.deinit();
        return ZapProcStatus.out_of_memory;
    };

    if (readSeededSchedulerSeed()) |seed| {
        // Seeded deterministic M:N backend (P4-J4): a single-threaded,
        // seed-reproducible interleaving over the shared structures. A failing
        // concurrency run replays exactly by re-running with the same seed.
        const core_count = readSeededSchedulerCoreCount();
        const simulator = concurrency.MnSimulator.create(
            backing_allocator,
            &runtime_state.pid_table,
            &runtime_state.envelope_pool,
            seed,
            .{
                .core_count = core_count,
                .signal_runtime = &runtime_state.signal_runtime,
                .registry = &runtime_state.registry,
                .blob_domain = &runtime_state.blob_domain,
            },
        ) catch {
            runtime_state.blob_domain.deinit();
            runtime_state.registry.deinit();
            runtime_state.signal_runtime.deinit();
            runtime_state.envelope_pool.deinit();
            runtime_state.pid_table.deinit();
            return ZapProcStatus.out_of_memory;
        };
        runtime_state.backend = .{ .seeded_simulator = simulator };
        // Announce the active seed so a failing run is replayable (the plan-4.4
        // failing-seed contract at the program level). Suppressed under `zig
        // test` so a kernel-test build never writes to stderr (build-runner
        // capture would flag it as failure noise).
        if (!@import("builtin").is_test) std.debug.print(
            "[zap] seeded deterministic scheduler ACTIVE — ZAP_SCHED_SEED={d} (0x{x}) cores={d}: single-threaded reproducible M:N; re-run with this seed to replay exactly\n",
            .{ seed, seed, core_count },
        );
    } else {
        runtime_state.backend = .{ .production_pool = undefined };
        concurrency.SchedulerPool.init(
            &runtime_state.backend.production_pool,
            backing_allocator,
            &runtime_state.pid_table,
            &runtime_state.envelope_pool,
            .{
                .core_options = .{
                    .signal_runtime = &runtime_state.signal_runtime,
                    .registry = &runtime_state.registry,
                    .blob_domain = &runtime_state.blob_domain,
                    // P6-J6: the deadlock detector's post-report action
                    // (default: report to stderr once, keep parking).
                    .deadlock_action = readDeadlockAction(),
                },
            },
        ) catch {
            runtime_state.blob_domain.deinit();
            runtime_state.registry.deinit();
            runtime_state.signal_runtime.deinit();
            runtime_state.envelope_pool.deinit();
            runtime_state.pid_table.deinit();
            return ZapProcStatus.out_of_memory;
        };
    }
    runtime_initialized = true;
    return ZapProcStatus.ok;
}

/// Test-only: initialize the runtime with the seeded deterministic M:N backend
/// DIRECTLY (no env var, no stderr banner) — the seam the abi-level seeded
/// reproducibility test drives, so it need not mutate process-global
/// environment. Mirrors the seeded branch of `zap_proc_runtime_init`.
fn runtimeInitSeededForTest(seed: u64, core_count: usize) i32 {
    if (runtime_initialized) return ZapProcStatus.already_initialized;
    runtime_state.ledger = .{};
    runtime_state.manager_registry = @splat(null);
    runtime_state.pid_table = concurrency.PidTable.init(backing_allocator, .{}) catch
        return ZapProcStatus.out_of_memory;
    runtime_state.envelope_pool = concurrency.EnvelopePool.init(backing_allocator, .{});
    installSignalRuntime();
    runtime_state.registry = concurrency.ProcessRegistry.init(backing_allocator, .{}) catch {
        runtime_state.signal_runtime.deinit();
        runtime_state.envelope_pool.deinit();
        runtime_state.pid_table.deinit();
        return ZapProcStatus.out_of_memory;
    };
    runtime_state.blob_domain = concurrency.BlobDomain.init() catch {
        runtime_state.registry.deinit();
        runtime_state.signal_runtime.deinit();
        runtime_state.envelope_pool.deinit();
        runtime_state.pid_table.deinit();
        return ZapProcStatus.out_of_memory;
    };
    const simulator = concurrency.MnSimulator.create(
        backing_allocator,
        &runtime_state.pid_table,
        &runtime_state.envelope_pool,
        seed,
        .{
            .core_count = core_count,
            .signal_runtime = &runtime_state.signal_runtime,
            .registry = &runtime_state.registry,
            .blob_domain = &runtime_state.blob_domain,
        },
    ) catch {
        runtime_state.blob_domain.deinit();
        runtime_state.registry.deinit();
        runtime_state.signal_runtime.deinit();
        runtime_state.envelope_pool.deinit();
        runtime_state.pid_table.deinit();
        return ZapProcStatus.out_of_memory;
    };
    runtime_state.backend = .{ .seeded_simulator = simulator };
    runtime_initialized = true;
    return ZapProcStatus.ok;
}

/// Bind the manifest memory manager FACTORY for spawned processes:
/// `core_vtable` is the manager's v1.x core vtable
/// (`ZapMemoryManagerCoreV1`), created and owned by the runtime
/// (`src/runtime.zig`, `active_manager_state.core`). Called once by the
/// gated-on bootstrap immediately after `zap_proc_runtime_init`, BEFORE any
/// spawn. Every process spawned thereafter MINTS ITS OWN private context
/// from this vtable's `init` (`ManifestManagerBinding.createProcessContext`)
/// — the Phase-3 per-process-instance model (plan item 3.1) replacing the
/// Phase-2 shared-context binding. Note the signature change from Phase 2:
/// no shared `context` is passed, because each process creates its own
/// (`docs/memory-manager-abi.md` records the ABI). Rebinds are
/// idempotent-friendly (last wins); the runtime binds exactly once. Driver
/// thread only.
///
/// Returns `ZapProcStatus.ok`, `not_initialized`, or
/// `manager_abi_unsupported` (the core declares a non-1 ABI major or a
/// sub-v1.0 `size`).
export fn zap_proc_bind_manager(core_vtable: *const anyopaque) callconv(.c) i32 {
    return zap_proc_register_manager(0, core_vtable);
}

/// Register a manager core vtable into per-spawn registry slot `manager_index`
/// (plan item 3.1/3.3, P3-J3). Slot 0 is the manifest default (also reachable
/// through `zap_proc_bind_manager`); slots 1.. are the distinct non-manifest
/// managers a `spawn(f, .{ .manager = X })` site selects, registered by the
/// gated-on runtime bootstrap from the compiler-generated registry module
/// BEFORE any managed spawn. `zap_proc_spawn_at` mints each process's private
/// context from the selected slot's core. Rebinds are last-wins; the runtime
/// registers each slot exactly once. Driver thread only.
///
/// Returns `ZapProcStatus.ok`, `not_initialized`, `manager_index_out_of_range`
/// (`manager_index >= MAX_MANAGER_SLOTS`), or `manager_abi_unsupported` (the
/// core declares a non-1 ABI major or a sub-v1.0 `size`).
export fn zap_proc_register_manager(manager_index: u32, core_vtable: *const anyopaque) callconv(.c) i32 {
    if (!runtime_initialized) return ZapProcStatus.not_initialized;
    if (manager_index >= MAX_MANAGER_SLOTS) return ZapProcStatus.manager_index_out_of_range;
    const core: *const ZapMemoryManagerCoreV1 = @ptrCast(@alignCast(core_vtable));
    if (core.abi_major != 1 or core.size < @sizeOf(ZapMemoryManagerCoreV1)) {
        return ZapProcStatus.manager_abi_unsupported;
    }
    runtime_state.manager_registry[manager_index] = core;
    return ZapProcStatus.ok;
}

/// Tear the runtime down: kill and tear down every straggler process
/// (`shutdownAllProcesses` — drop-lists run, mailboxes drain, stacks and
/// pid slots return), sweep the payload/closure ledger (module doc), and
/// release the pools. Driver thread only; idempotent (a second call is a
/// no-op). After deinit the runtime may be initialized again.
export fn zap_proc_runtime_deinit() callconv(.c) void {
    if (!runtime_initialized) return;
    // Reap stragglers (a root-mode run leaves the root's children live per the
    // Erlang halt model; also covers an init→spawn→deinit without a run). Safe
    // and single-threaded: the pool's workers have already joined inside `run`.
    runtime_state.backend.shutdownAndDeinit();
    runtime_state.envelope_pool.deinit();
    runtime_state.pid_table.deinit();
    runtime_state.ledger.sweep();
    // Every process's signal sets were drained at its teardown (above), so no
    // signal node is live — `deinit` asserts that and returns the pool's blocks.
    runtime_state.signal_runtime.deinit();
    // Every registered process released its name at teardown (above), so no
    // registration is live — `deinit` asserts that (the leak oracle) and frees
    // the slot storage.
    runtime_state.registry.deinit();
    // Every process's blob ledger drained at its teardown and every in-flight
    // blob envelope was reclaimed by the mailbox drains (both above), so the
    // only remaining references are the persistent-term registry's own —
    // `deinit` releases those and asserts ZERO live blobs (the share tier's
    // leak-exactness oracle), then frees the domain.
    runtime_state.blob_domain.deinit();
    // P6-J6: release the observability capture storage (grown lazily by
    // `zap_introspect_capture`).
    introspect_snapshot_storage.deinit(backing_allocator);
    introspect_snapshot_storage = .empty;
    runtime_initialized = false;
}

/// Drive the scheduler until every process has exited (the kernel's
/// `runUntilQuiescent`). Driver thread only. Returns immediately when no
/// process is live. P2-J2/J3's entry-process design calls this from the
/// generated bootstrap once user main runs as the root process.
///
/// Returns `ZapProcStatus.ok` or `not_initialized`.
export fn zap_proc_run_until_quiescent() callconv(.c) i32 {
    if (!runtime_initialized) return ZapProcStatus.not_initialized;
    runtime_state.backend.runUntilQuiescent();
    return ZapProcStatus.ok;
}

/// Drive the scheduler until the process identified by `target_pid_bits`
/// has exited, then return — other processes may still be live (the
/// kernel's `runUntilProcessExits`). This is the root-process join the
/// P2-J2 generated bootstrap drives: user main runs as the root process
/// and the program's lifetime is the root's lifetime; stragglers are torn
/// down by `zap_proc_runtime_deinit`'s `shutdownAllProcesses` (Erlang
/// halt semantics). Driver thread only. Returns immediately when the pid
/// does not resolve (already dead, stale, or forged).
///
/// Returns `ZapProcStatus.ok` or `not_initialized`.
export fn zap_proc_run_until_exit(target_pid_bits: u64) callconv(.c) i32 {
    if (!runtime_initialized) return ZapProcStatus.not_initialized;
    const target = concurrency.Pid.fromBits(target_pid_bits);
    runtime_state.backend.runUntilRootExits(target);
    return ZapProcStatus.ok;
}

/// The current process's opaque handle — the same value the kernel
/// passed to the process entry function — or null when no process
/// quantum is running (including on the driver thread outside the
/// scheduler loop) or the runtime is not initialized.
///
/// This is the ambient-lookup companion to the parameter-threaded
/// current-process discipline (module doc): compiled Zap code reaches
/// process-scoped intrinsics through the runtime's process wrappers,
/// which cannot thread the entry-delivered handle through every Zap
/// call frame in Phase 2, so they re-resolve it per operation through
/// this intrinsic (one global read plus one field read on the Phase 2
/// single scheduler — the A.4.1 register-vs-parameter-vs-TLS decision
/// for compiled code stays open, and this surface is additive over it).
/// Kernel-internal code never calls this.
export fn zap_proc_current() callconv(.c) ?*anyopaque {
    if (!runtime_initialized) return null;
    // The current process is the one this CORE is running (M:N): resolve through
    // the calling thread's scheduler. Null on the driver thread outside the run
    // loop, or on any thread with no quantum in flight.
    const core = concurrency.Scheduler.currentThreadScheduler() orelse return null;
    return @ptrCast(core.currentProcessContext());
}

// ---------------------------------------------------------------------------
// Intrinsics — spawn (driver thread or process body; same OS thread)
// ---------------------------------------------------------------------------

/// The optional parent relationship a spawn establishes ATOMICALLY, before the
/// child is admitted and can run/exit (Erlang `spawn_link`/`spawn_monitor`
/// atomicity — the relationship must exist before the child can exit, so a
/// child that exits immediately still propagates to the parent). Carried by
/// value from the `spawn_link`/`spawn_monitor` intrinsics through `spawnAtWith`.
const SpawnRelationship = union(enum) {
    /// A plain spawn — no parent relationship.
    none,
    /// `spawn_link`: bidirectionally link the child to this parent process.
    link: *concurrency.ProcessContext,
    /// `spawn_monitor`: install a monitor from `parent` on the child; the minted
    /// reference is written to `ref_out`.
    monitor: struct { parent: *concurrency.ProcessContext, ref_out: *u64 },
};

/// Spawn a process running `entry(process_handle, argument)` under the manager
/// in registry slot `manager_index`, optionally establishing a parent
/// `relationship` (`spawn_link`/`spawn_monitor`) ATOMICALLY before the child is
/// admitted. The spawn mints a FRESH private per-process context from that
/// manager's core vtable (wholesale-freed at the process's teardown) and stamps
/// the pid's model bits from the manager's `declared_caps`
/// (`reclamationModelForCaps`) so a sender reads the target's reclamation model
/// together with its generation (§2.4 invariant). Returns the new pid's raw
/// encoding, or `0` (the invalid pid) on failure: runtime not initialized,
/// `manager_index` out of range/unregistered, an unsound manager model on this
/// target, manager `init`/allocation failure, or process-table exhaustion.
fn spawnAtWith(
    entry: ZapProcEntry,
    argument: ?*anyopaque,
    manager_index: u32,
    relationship: SpawnRelationship,
) u64 {
    if (!runtime_initialized) return concurrency.Pid.invalid.toBits();
    if (manager_index >= MAX_MANAGER_SLOTS) return concurrency.Pid.invalid.toBits();
    // No fallback bootstrap arena (the no-fallbacks rule): a process cannot
    // spawn until the selected registry slot has a manager registered.
    const core = runtime_state.manager_registry[manager_index] orelse
        return concurrency.Pid.invalid.toBits();

    // Pid model bits (plan §2.4, J3): the reclamation model of the process's
    // OWN manager, decoded from its declared capabilities.
    const model = reclamationModelForCaps(core.declared_caps);

    // Capability matrix (plan item 3.5): refuse to spawn a process under a
    // manager whose model is unsound on this target (e.g. a TRACED manager on
    // Windows / wasm). The backend stays linkable — this is a spawn error, not
    // a compile-time exclusion — so a DIFFERENT manager can still be selected
    // here on the same target.
    if (!managerModelSoundOnTarget(model)) return concurrency.Pid.invalid.toBits();

    // Per-process instance (plan item 3.1): mint a FRESH private manager
    // context (a private heap) for this process from the SELECTED manager's
    // core `init`. On any downstream spawn failure it is wholesale-freed via
    // `manager_context.teardown()` so the private heap never leaks.
    const manager_context = createProcessBinding(core) orelse
        return concurrency.Pid.invalid.toBits();

    const closure_block = runtime_state.ledger.allocate(@sizeOf(SpawnClosure)) catch {
        manager_context.teardown();
        return concurrency.Pid.invalid.toBits();
    };
    const closure: *SpawnClosure = @ptrCast(@alignCast(closure_block.bodyPointer()));
    closure.* = .{ .c_entry = entry, .c_argument = argument };

    // Route the spawn to the RUNNING core for an in-process spawn (locality;
    // stealing rebalances) and to core 0 for an external spawn from the driver
    // (its stack pool + record cache are the driver thread's own — see
    // `SchedulerPool.primaryCore`). Either core's `spawn` touches only that
    // core's per-scheduler resources on its own thread. A `spawn_link`/
    // `spawn_monitor` parent runs on THIS core (it is the caller), so the
    // relationship record is resolved on the same core the spawn runs on.
    const spawn_core = concurrency.Scheduler.currentThreadScheduler() orelse runtime_state.backend.primaryCore();
    const pid = spawn_core.spawn(.{
        .entry = spawnTrampoline,
        .argument = closure_block,
        // The process runs on its OWN private context; the per-process vtable's
        // teardown wholesale-frees it at exit (`ProcessManagerBinding`).
        .manager = manager_context,
        .model = model,
        .link_parent = switch (relationship) {
            .link => |parent| parent.record,
            else => null,
        },
        .monitor_parent = switch (relationship) {
            .monitor => |m| m.parent.record,
            else => null,
        },
        .monitor_ref_out = switch (relationship) {
            .monitor => |m| m.ref_out,
            else => null,
        },
    }) catch {
        runtime_state.ledger.free(closure_block);
        manager_context.teardown();
        return concurrency.Pid.invalid.toBits();
    };
    return pid.toBits();
}

/// Spawn a process under the MANIFEST default manager (registry slot 0) — the
/// no-option `Process.spawn(f)` path. Kept as the ABI-stable convenience the
/// Phase-2 surface and the root-process bootstrap already call.
export fn zap_proc_spawn(entry: ZapProcEntry, argument: ?*anyopaque) callconv(.c) u64 {
    return spawnAtWith(entry, argument, 0, .none);
}

/// Spawn under the manager in registry slot `manager_index` (plan item 3.1/3.3,
/// P3-J3 — the `spawn(f, .{ .manager = X })` surface). See `spawnAtWith`.
export fn zap_proc_spawn_at(entry: ZapProcEntry, argument: ?*anyopaque, manager_index: u32) callconv(.c) u64 {
    return spawnAtWith(entry, argument, manager_index, .none);
}

/// `spawn_link(f)` (P5-J2): spawn under the manifest manager and ATOMICALLY link
/// the caller to the child before it is admitted, so a child that exits
/// immediately still propagates its exit to the caller (Erlang `spawn_link`
/// atomicity — no racy link-after-spawn). Returns the child's pid bits, or `0`
/// on failure or when called outside a process (no parent to link).
export fn zap_proc_spawn_link(entry: ZapProcEntry, argument: ?*anyopaque) callconv(.c) u64 {
    const spawn_core = concurrency.Scheduler.currentThreadScheduler() orelse
        return concurrency.Pid.invalid.toBits();
    const parent = spawn_core.currentProcessContext() orelse
        return concurrency.Pid.invalid.toBits();
    return spawnAtWith(entry, argument, 0, .{ .link = parent });
}

/// `spawn_monitor(f) -> {pid, ref}` (P5-J2): spawn under the manifest manager
/// and ATOMICALLY install a monitor from the caller on the child before it is
/// admitted; the minted reference is written to `ref_out`. Returns the child's
/// pid bits (and the ref via `ref_out`), or `0`/`ref_out = 0` on failure or when
/// called outside a process.
export fn zap_proc_spawn_monitor(entry: ZapProcEntry, argument: ?*anyopaque, ref_out: *u64) callconv(.c) u64 {
    ref_out.* = 0;
    const spawn_core = concurrency.Scheduler.currentThreadScheduler() orelse
        return concurrency.Pid.invalid.toBits();
    const parent = spawn_core.currentProcessContext() orelse
        return concurrency.Pid.invalid.toBits();
    return spawnAtWith(entry, argument, 0, .{ .monitor = .{ .parent = parent, .ref_out = ref_out } });
}

// ---------------------------------------------------------------------------
// Intrinsics — process-scoped (handle = the entry-delivered process value)
// ---------------------------------------------------------------------------

/// The calling process's pid (raw encoding).
export fn zap_proc_self(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).selfPid().toBits();
}

/// Send `payload_len` opaque bytes (copied — the caller keeps ownership
/// of its buffer) to `target_pid_bits`. Zero-length sends are legal and
/// carry a null payload view. Returns `ZapProcStatus.ok` (delivered),
/// `dead_lettered` (target dead/stale — message dropped, Erlang
/// semantics), or `out_of_memory`. See the module doc's payload seam:
/// the byte-copy transport is replaced by the P2-J5 deep-copy walker.
export fn zap_proc_send(
    process: *anyopaque,
    target_pid_bits: u64,
    payload_pointer: ?[*]const u8,
    payload_len: usize,
) callconv(.c) i32 {
    const context = contextFromHandle(process);
    const target = concurrency.Pid.fromBits(target_pid_bits);

    var fragment = mailbox_module.Fragment{};
    var payload_block: ?*LedgerBlock = null;
    if (payload_len > 0) {
        const block = runtime_state.ledger.allocate(payload_len) catch
            return ZapProcStatus.out_of_memory;
        @memcpy(block.bodyPointer()[0..payload_len], payload_pointer.?[0..payload_len]);
        fragment = .{
            .payload_pointer = block.bodyPointer(),
            .payload_byte_length = payload_len,
            .payload_origin_page = null,
        };
        payload_block = block;
    }

    const outcome = context.send(target, fragment) catch {
        if (payload_block) |block| runtime_state.ledger.free(block);
        return ZapProcStatus.out_of_memory;
    };
    return switch (outcome) {
        .delivered => ZapProcStatus.ok,
        .dead_lettered => blk: {
            // Nothing was enqueued; the payload block has no consumer.
            if (payload_block) |block| runtime_state.ledger.free(block);
            break :blk ZapProcStatus.dead_lettered;
        },
    };
}

/// Send a MOVED value graph to `target_pid_bits` — the same-model O(1)
/// region-move send (plan item 6.1, P3-J5). Unlike `zap_proc_send`, the payload
/// is NOT copied: `root_pointer` is a value graph the sender detached from its
/// own heap (proven uniquely owned + region-closed by the region-closure
/// verifier), transported by pointer through the neutral envelope with ZERO
/// byte copy. `reclaim` is the leak-exactness hook invoked if the envelope is
/// freed without the receiver adopting the graph (dead-letter, or a receiver
/// teardown drain). On `dead_lettered` the graph was never enqueued; the CALLER
/// re-owns the orphan (the kernel does not reclaim it here).
export fn zap_proc_send_moved(
    process: *anyopaque,
    target_pid_bits: u64,
    root_pointer: [*]const u8,
    byte_length: usize,
    reclaim: mailbox_module.MovedReclaimFn,
) callconv(.c) i32 {
    const context = contextFromHandle(process);
    const target = concurrency.Pid.fromBits(target_pid_bits);
    const fragment = mailbox_module.Fragment{
        .payload_pointer = root_pointer,
        .payload_byte_length = byte_length,
        .payload_origin_page = null,
        .moved_reclaim = reclaim,
    };
    const outcome = context.send(target, fragment) catch {
        // Enqueue failed (out of envelope capacity); nothing consumed the graph.
        return ZapProcStatus.out_of_memory;
    };
    return switch (outcome) {
        .delivered => ZapProcStatus.ok,
        // Nothing was enqueued — the sender re-owns the detached graph.
        .dead_lettered => ZapProcStatus.dead_lettered,
    };
}

/// Whether `target_pid_bits` names a REFCOUNTED-model process. The same-model
/// O(1) region-move send (P3-J5) is sound only when sender and receiver share a
/// reclamation model; the sender (always refcounted when it reaches the move
/// path) queries this to decide move-vs-copy BEFORE detaching. Reads the pid's
/// model bits (the §2.4 `{slot, generation, model}` invariant); a stale/invalid
/// pid decodes to whatever model its bits carry, and the send then dead-letters
/// harmlessly if the slot is dead.
export fn zap_proc_pid_is_refcounted(target_pid_bits: u64) callconv(.c) bool {
    return concurrency.Pid.fromBits(target_pid_bits).model == .refcounted;
}

/// If the parked envelope carries a MOVED value graph, return its root pointer
/// and TRANSFER ownership to the caller (clearing the fragment so the following
/// `zap_proc_envelope_free` neither reclaims nor byte-frees it); otherwise
/// return null (a copied payload the caller reconstructs from the byte view).
/// Called by the receive lowering immediately after `zap_proc_receive_park`.
export fn zap_proc_envelope_take_moved(envelope_handle: *anyopaque) callconv(.c) ?[*]const u8 {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    if (envelope.fragment.moved_reclaim == null) return null;
    const root = envelope.fragment.payload_pointer;
    // Ownership transfers to the receiver (which adopts the graph): clear the
    // fragment so `zap_proc_envelope_free` performs a pure header free.
    envelope.fragment = .{};
    return root;
}

/// Park the calling process until a USER message is queued, then return
/// the oldest user envelope as an opaque reference, with the payload
/// view written through the out-parameters (`null`/`0` for payload-less
/// messages). Signal envelopes (trapped exits / `DOWN`s) are SKIPPED and
/// stay queued, in order, for `zap_proc_await_signal` (P5-R1) — the
/// typed receive never decodes a `SignalPayload` as the message type.
/// The payload view BORROWS from the envelope: it is valid until
/// `zap_proc_envelope_free`, which the caller MUST eventually invoke on
/// the returned reference. If the process is killed while parked, the
/// call never returns.
export fn zap_proc_receive_park(
    process: *anyopaque,
    out_payload_pointer: *?[*]const u8,
    out_payload_len: *usize,
) callconv(.c) *anyopaque {
    const context = contextFromHandle(process);
    const envelope = context.receiveUser();
    out_payload_pointer.* = envelope.fragment.payload_pointer;
    out_payload_len.* = envelope.fragment.payload_byte_length;
    return @ptrCast(envelope);
}

/// Release an envelope returned by `zap_proc_receive_park`: frees the
/// payload ledger block (when present) and returns the envelope header
/// to the shared pool. Exactly-once per received envelope.
export fn zap_proc_envelope_free(envelope_handle: *anyopaque) callconv(.c) void {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    if (envelope.fragment.moved_reclaim) |reclaim| {
        // A MOVED payload the receiver did NOT adopt (dead-letter, or a mailbox
        // drained at receiver teardown — a delivered move clears the fragment
        // via `zap_proc_envelope_take_moved`, so this branch sees only orphans).
        // Reclaim the detached graph leak-exactly (`reclaim` munmaps it).
        if (envelope.fragment.payload_pointer) |payload| reclaim(payload);
        envelope.fragment = .{};
    } else if (envelope.fragment.payload_pointer) |payload| {
        // P2-J1 transport invariant: a non-null payload with a null
        // origin page is a ledger block (module doc). P2-J5's pool-carved
        // fragments set `payload_origin_page` and take the other branch.
        std.debug.assert(envelope.fragment.payload_origin_page == null);
        runtime_state.ledger.free(LedgerBlock.fromBodyPointer(payload));
        envelope.fragment = .{};
    }
    envelope_pool_module.free(envelope);
}

/// The receive-back-edge arena auto-reset (plan item 6.4, P6-J4). The
/// compiler emits a call to this intrinsic IMMEDIATELY BEFORE a receive
/// primitive ONLY at receive sites whose iteration closure it proved
/// (`src/receive_reset.zig`: no allocation made after the process's first
/// proven receive is reachable at this program point) — that proof is the
/// soundness precondition for the bulk free. Dispatches through the calling
/// process's OWN manager binding: a BULK_OR_NEVER manager exposing `ARSR`
/// (Arena) captures the iteration watermark on the first call and bulk-frees
/// back to it on every later call; every other model is a no-op (see
/// `processIterationHeapResetThunk` for the per-model table). Never parks,
/// never fails; O(chunks-allocated-since-the-watermark).
export fn zap_proc_receive_iteration_reset(process: *anyopaque) callconv(.c) void {
    const context = contextFromHandle(process);
    context.record.pcb.manager.iterationHeapReset();
}

/// Bytes currently held by the CALLING process's own heap, per its manager's
/// accounting granularity (the descriptor-only `STAT` capability, spec §10 —
/// the first-party Arena reports reserved chunk bytes; a manager without
/// `STAT` reports 0). Self-inspection only — the introspection surface
/// (`introspection.zig`) covers cross-process snapshots — so there is no
/// liveness race to defend against: a process reading its own live binding.
export fn zap_proc_heap_byte_count(process: *anyopaque) callconv(.c) usize {
    return contextFromHandle(process).record.pcb.manager.heapByteCount();
}

/// Park the calling process until a USER message is queued, WITHOUT
/// consuming it, shrinking the process's idle footprint at the park — the
/// BEAM `hibernate` analogue (plan item 6.4; research.md §6.5 note 4).
/// While the fiber is suspended the scheduler releases the committed stack
/// pages below its saved stack pointer back to the OS
/// (`Scheduler.shrinkHibernatedStack`) — they recommit by fault on wake —
/// and heap-side reclamation is model-governed (see `ProcessContext.hibernate`
/// for the per-model table). Returns when the mailbox holds a user message
/// (a following `receive` consumes it); returns immediately — without
/// shrinking — if one is already queued. If the process is killed while
/// hibernated, the call never returns.
export fn zap_proc_hibernate(process: *anyopaque) callconv(.c) void {
    contextFromHandle(process).hibernate();
}

// ---------------------------------------------------------------------------
// Intrinsics — observability (P6-J6, plan item 6.5)
//
// The runtime-wide introspection surface behind `lib/runtime_info.zap`
// (`:zig.RuntimeInfo.*`): process listing, per-core scheduler utilization and
// run-queue depth, and the trace-ring read API. Read-side only — the trace
// EMIT sites live in the kernel and are comptime-gated (`trace.zig`); these
// exports exist in BOTH trace modes so the runtime's externs always resolve
// (they report disabled/empty when tracing is compiled OFF).
//
// Snapshot protocol (capture + indexed getters): a `*_capture` intrinsic
// copies a consistent point-in-time snapshot into runtime-owned storage and
// returns the entry count; the indexed getters then read that snapshot.
// Captures serialize on a spinlock; the getters read the captured arrays
// without it, so they are meaningful between ONE process's capture and its
// next (the Zap surface documents the single-capturer discipline). The
// listing inherits `introspection.zig`'s consistency contract: per-process
// point-in-time, never globally atomic; mailbox depth approximate; exact at
// quiescence.
// ---------------------------------------------------------------------------

/// Serializes `zap_introspect_capture` / `zap_trace_capture` (and reset)
/// against each other. Kernel spinlock convention (`std.atomic.Mutex`).
var observability_lock: std.atomic.Mutex = .unlocked;

inline fn lockObservability() void {
    while (!observability_lock.tryLock()) std.atomic.spinLoopHint();
}

inline fn unlockObservability() void {
    observability_lock.unlock();
}

/// The captured process listing (grown as needed; freed at runtime deinit).
var introspect_snapshot_storage: std.ArrayListUnmanaged(concurrency.introspection.ProcessSnapshot) = .empty;

/// Stable ABI encoding of a `ProcessState` (independent of the kernel
/// enum's ordinal layout; `lib/runtime_info.zap` maps these to atoms).
fn processStateCode(state: process_module.ProcessState) i64 {
    return switch (state) {
        .embryo => 0,
        .runnable => 1,
        .running => 2,
        .waiting => 3,
        .blocking => 4,
        .exiting => 5,
    };
}

/// Snapshot the live process set (pid, state, mailbox depth, heap bytes per
/// process) into runtime-owned storage and return how many were captured.
/// Callable from any process; captures serialize. Returns 0 when the
/// runtime is not initialized or memory is exhausted.
export fn zap_introspect_capture() callconv(.c) u64 {
    if (!runtime_initialized) return 0;
    lockObservability();
    defer unlockObservability();
    introspect_snapshot_storage.clearRetainingCapacity();
    var listing = concurrency.introspection.listProcesses(&runtime_state.pid_table);
    while (listing.next()) |snapshot| {
        introspect_snapshot_storage.append(backing_allocator, snapshot) catch return 0;
    }
    return introspect_snapshot_storage.items.len;
}

/// The captured process at `index`, or null past the captured count.
fn capturedProcessAt(index: u64) ?*const concurrency.introspection.ProcessSnapshot {
    if (index >= introspect_snapshot_storage.items.len) return null;
    return &introspect_snapshot_storage.items[@intCast(index)];
}

/// Raw pid bits of captured process `index` (0 past the captured count).
export fn zap_introspect_pid(index: u64) callconv(.c) u64 {
    const snapshot = capturedProcessAt(index) orelse return 0;
    return snapshot.pid.toBits();
}

/// State code of captured process `index` (see `processStateCode`; −1 past
/// the captured count).
export fn zap_introspect_state(index: u64) callconv(.c) i64 {
    const snapshot = capturedProcessAt(index) orelse return -1;
    return processStateCode(snapshot.state);
}

/// Mailbox depth of captured process `index` (0 past the captured count).
export fn zap_introspect_mailbox_depth(index: u64) callconv(.c) u64 {
    const snapshot = capturedProcessAt(index) orelse return 0;
    return snapshot.mailbox_depth;
}

/// Heap bytes of captured process `index` per its manager's accounting
/// (the P6-J4 `STAT` capability; 0 without one, and 0 past the count).
export fn zap_introspect_heap_bytes(index: u64) callconv(.c) u64 {
    const snapshot = capturedProcessAt(index) orelse return 0;
    return snapshot.heap_byte_count;
}

/// The scheduler core at `core_index` for the active backend, or null out
/// of range / uninitialized.
fn backendCoreAt(core_index: u64) ?*concurrency.Scheduler {
    if (!runtime_initialized) return null;
    return switch (runtime_state.backend) {
        .production_pool => |*pool| if (core_index < pool.coreCount())
            &pool.cores[@intCast(core_index)]
        else
            null,
        .seeded_simulator => |simulator| if (core_index < simulator.coreCount())
            &simulator.cores[@intCast(core_index)]
        else
            null,
    };
}

/// Number of scheduler cores in the active backend (0 when the runtime is
/// not initialized).
export fn zap_sched_core_count() callconv(.c) u64 {
    if (!runtime_initialized) return 0;
    return switch (runtime_state.backend) {
        .production_pool => |*pool| pool.coreCount(),
        .seeded_simulator => |simulator| simulator.coreCount(),
    };
}

/// Run-queue depth of core `core_index` (local FIFO + LIFO slot;
/// `Scheduler.runQueueDepth`). 0 out of range.
export fn zap_sched_run_queue_depth(core_index: u64) callconv(.c) u64 {
    const core = backendCoreAt(core_index) orelse return 0;
    return core.runQueueDepth();
}

/// Depth of the shared global overflow run queue (approximate under
/// concurrency; exact at quiescence).
export fn zap_sched_global_queue_depth() callconv(.c) u64 {
    if (!runtime_initialized) return 0;
    return switch (runtime_state.backend) {
        .production_pool => |*pool| pool.globalRunQueueDepth(),
        .seeded_simulator => |simulator| simulator.global_queue.count.load(.monotonic),
    };
}

/// Wall nanoseconds core `core_index`'s run episodes have spanned so far
/// (`Scheduler.utilizationSnapshot`). 0 out of range.
export fn zap_sched_window_nanos(core_index: u64) callconv(.c) u64 {
    const core = backendCoreAt(core_index) orelse return 0;
    return core.utilizationSnapshot().window_nanoseconds;
}

/// Nanoseconds of core `core_index`'s window spent parked (idle).
export fn zap_sched_parked_nanos(core_index: u64) callconv(.c) u64 {
    const core = backendCoreAt(core_index) orelse return 0;
    return core.utilizationSnapshot().parked_nanoseconds;
}

/// Nanoseconds of core `core_index`'s window spent busy (window − parked).
export fn zap_sched_busy_nanos(core_index: u64) callconv(.c) u64 {
    const core = backendCoreAt(core_index) orelse return 0;
    return core.utilizationSnapshot().busy_nanoseconds;
}

/// Futex parks core `core_index` has entered (thread-safe counter).
export fn zap_sched_park_count(core_index: u64) callconv(.c) u64 {
    const core = backendCoreAt(core_index) orelse return 0;
    return core.parkCount();
}

/// The captured trace events (storage comptime-gated away when tracing is
/// compiled OFF — see `trace.zig`).
var trace_snapshot_storage: if (trace_module.runtime_trace_active)
    [trace_module.ring_capacity]trace_module.TraceEventRecord
else
    void = undefined;

/// Number of valid entries in `trace_snapshot_storage`.
var trace_snapshot_count: usize = 0;

/// Whether this binary's kernel was compiled with the message-flow trace
/// instrumentation (`runtime_tracing` — manifest field or
/// `-Druntime-tracing=on`).
export fn zap_trace_enabled() callconv(.c) bool {
    return trace_module.runtime_trace_active;
}

/// Snapshot the trace ring (oldest first) into runtime-owned storage and
/// return how many events were captured. 0 when tracing is compiled OFF.
/// Exact at quiescence; a capture racing active emitters may skip the
/// entries being overwritten in that instant (`trace.zig` module doc).
export fn zap_trace_capture() callconv(.c) u64 {
    if (comptime !trace_module.runtime_trace_active) return 0;
    lockObservability();
    defer unlockObservability();
    trace_snapshot_count = trace_module.captureGlobal(&trace_snapshot_storage);
    return trace_snapshot_count;
}

/// The captured trace event at `index`, or null past the captured count
/// (always null when tracing is compiled OFF).
fn capturedTraceEventAt(index: u64) ?*const trace_module.TraceEventRecord {
    if (comptime !trace_module.runtime_trace_active) return null;
    if (index >= trace_snapshot_count) return null;
    return &trace_snapshot_storage[@intCast(index)];
}

/// Global emission sequence of captured event `index` (strictly increasing
/// across the capture; 0 past the count).
export fn zap_trace_sequence(index: u64) callconv(.c) u64 {
    const event = capturedTraceEventAt(index) orelse return 0;
    return event.sequence;
}

/// Monotonic-nanosecond timestamp of captured event `index` (0 past the
/// count).
export fn zap_trace_timestamp_nanos(index: u64) callconv(.c) u64 {
    const event = capturedTraceEventAt(index) orelse return 0;
    return event.timestamp_nanoseconds;
}

/// Kind of captured event `index` (`trace.TraceEventKind` raw value:
/// 1 = spawn, 2 = exit, 3 = send, 4 = receive, 5 = signal; 0 past the
/// count).
export fn zap_trace_kind(index: u64) callconv(.c) i64 {
    const event = capturedTraceEventAt(index) orelse return 0;
    return @intFromEnum(event.kind);
}

/// Acting process's raw pid bits of captured event `index` (0 past the
/// count).
export fn zap_trace_pid(index: u64) callconv(.c) u64 {
    const event = capturedTraceEventAt(index) orelse return 0;
    return event.pid_bits;
}

/// Counterparty raw pid bits of captured event `index` (send target /
/// signal target; 0 when the event has none or past the count).
export fn zap_trace_peer(index: u64) callconv(.c) u64 {
    const event = capturedTraceEventAt(index) orelse return 0;
    return event.peer_pid_bits;
}

/// Kind-specific detail byte of captured event `index` (see
/// `trace.TraceEventKind`; 0 past the count).
export fn zap_trace_detail(index: u64) callconv(.c) u64 {
    const event = capturedTraceEventAt(index) orelse return 0;
    return event.detail;
}

/// Discard the retained trace events and restart sequence numbering — a
/// test/diagnostic aid; call at quiescence (`trace.TraceRing.reset`).
/// No-op when tracing is compiled OFF.
export fn zap_trace_reset() callconv(.c) void {
    if (comptime !trace_module.runtime_trace_active) return;
    lockObservability();
    defer unlockObservability();
    trace_snapshot_count = 0;
    trace_module.resetGlobal();
}

// ---------------------------------------------------------------------------
// Intrinsics — Zap.Blob, the sanctioned atomic immutable share tier (P6-J2)
//
// The `zap_blob_*` surface over `blob.zig`'s `BlobDomain` + the per-process
// `BlobLedger`. Two disciplines govern every entry point:
//
//   * **Ownership-gated payload access.** Every intrinsic that could touch
//     payload bytes (or mint a new reference from an existing one) takes the
//     calling process handle and VERIFIES the handle against the caller's
//     ledger first. A blob operation on a handle this process does not own
//     is a program bug surfaced as a sentinel (the runtime panics loudly),
//     never a racy read of memory another owner may free concurrently. The
//     generation-validated slot CAS already makes stale/forged handles
//     memory-safe (they touch only type-stable slot words); the ledger gate
//     upgrades "memory-safe" to "semantically rejected".
//   * **Acquisition = ledger entry.** `create`/`slice`/`adopt`/
//     `registry_get` append the granted reference to the caller's ledger;
//     `release_owned` removes one; teardown drains the rest
//     (`scheduler.zig` step 4b). The flight reference a send mints is NOT
//     ledger-tracked — it belongs to the in-flight envelope and is released
//     by adoption transfer, dead-letter undo, or the envelope reclaim hook.
// ---------------------------------------------------------------------------

/// Resolve the calling process's ledger and verify it owns `handle_bits`.
fn callerOwnsBlob(process: *anyopaque, handle_bits: u64) bool {
    return contextFromHandle(process).blobLedger().contains(handle_bits);
}

/// Create a blob by copying `byte_length` bytes from `bytes_pointer` into
/// the blob domain (the one copy of the blob's life), granting the calling
/// process one owned (ledger-tracked) reference. Zero-length blobs are
/// legal (`bytes_pointer` may then be null). Returns the handle bits, or 0
/// on allocation failure / table exhaustion (the runtime panics — OOM
/// posture).
export fn zap_blob_create(
    process: *anyopaque,
    bytes_pointer: ?[*]const u8,
    byte_length: usize,
) callconv(.c) u64 {
    const bytes: []const u8 = if (byte_length == 0) &.{} else bytes_pointer.?[0..byte_length];
    const handle = runtime_state.blob_domain.create(bytes) catch return 0;
    contextFromHandle(process).blobLedger().append(handle.toBits()) catch {
        _ = runtime_state.blob_domain.release(handle);
        return 0;
    };
    return handle.toBits();
}

/// Release ONE owned reference the calling process holds on `handle_bits`
/// (the explicit early release; unreleased references drain at teardown).
/// Returns `ZapProcStatus.ok`, or `blob_not_owned` when the caller's ledger
/// holds no such reference (a use-after-release or a release of a blob this
/// process never acquired — the runtime panics).
export fn zap_blob_release_owned(process: *anyopaque, handle_bits: u64) callconv(.c) i32 {
    const ledger = contextFromHandle(process).blobLedger();
    if (!ledger.removeOne(handle_bits)) return ZapProcStatus.blob_not_owned;
    _ = runtime_state.blob_domain.release(concurrency.BlobHandle.fromBits(handle_bits));
    return ZapProcStatus.ok;
}

/// Payload byte length. Returns −1 when the caller does not own
/// `handle_bits` (stale handles are never owned — the ledger gate subsumes
/// the generation check).
export fn zap_blob_size(process: *anyopaque, handle_bits: u64) callconv(.c) i64 {
    if (!callerOwnsBlob(process, handle_bits)) return -1;
    const length = runtime_state.blob_domain.byteLength(concurrency.BlobHandle.fromBits(handle_bits)) orelse return -1;
    return @intCast(length);
}

/// The byte at `index` (0–255). Returns −1 when not owned/stale, −2 when
/// `index` is out of bounds.
export fn zap_blob_byte_at(process: *anyopaque, handle_bits: u64, index: u64) callconv(.c) i64 {
    if (!callerOwnsBlob(process, handle_bits)) return -1;
    const view = runtime_state.blob_domain.bytesView(concurrency.BlobHandle.fromBits(handle_bits)) orelse return -1;
    if (index >= view.len) return -2;
    return view[@intCast(index)];
}

/// A BORROWED view of the payload bytes, written through `out_pointer`;
/// returns the byte length, or −1 when not owned/stale. The view is valid
/// while the caller retains its owned reference (the immutable payload is
/// never moved or mutated) — the runtime copies out of it synchronously.
export fn zap_blob_bytes_view(
    process: *anyopaque,
    handle_bits: u64,
    out_pointer: *?[*]const u8,
) callconv(.c) i64 {
    out_pointer.* = null;
    if (!callerOwnsBlob(process, handle_bits)) return -1;
    const view = runtime_state.blob_domain.bytesView(concurrency.BlobHandle.fromBits(handle_bits)) orelse return -1;
    out_pointer.* = view.ptr;
    return @intCast(view.len);
}

/// COPY the byte range `[start, start+length)` OUT into a fresh blob (the
/// v1 no-aliasing slice — module doc of `blob.zig`: the Erlang sub-binary /
/// Java substring pin pathology is defeated by construction), granting the
/// caller one owned reference on the new blob. Returns the new handle bits;
/// 0 when the source is not owned/stale, the range is out of bounds, or
/// allocation fails (the runtime distinguishes via prior size validation).
export fn zap_blob_slice(
    process: *anyopaque,
    handle_bits: u64,
    start: u64,
    length: u64,
) callconv(.c) u64 {
    if (!callerOwnsBlob(process, handle_bits)) return 0;
    const view = runtime_state.blob_domain.bytesView(concurrency.BlobHandle.fromBits(handle_bits)) orelse return 0;
    if (start > view.len or length > view.len - @as(usize, @intCast(start))) return 0;
    const slice_start: usize = @intCast(start);
    const slice_length: usize = @intCast(length);
    const handle = runtime_state.blob_domain.create(view[slice_start .. slice_start + slice_length]) catch return 0;
    contextFromHandle(process).blobLedger().append(handle.toBits()) catch {
        _ = runtime_state.blob_domain.release(handle);
        return 0;
    };
    return handle.toBits();
}

/// Current share count (advisory — exact at quiescence; the test surface
/// for "the atomic count reflects both holders"). −1 when not owned/stale.
export fn zap_blob_share_count(process: *anyopaque, handle_bits: u64) callconv(.c) i64 {
    if (!callerOwnsBlob(process, handle_bits)) return -1;
    const count = runtime_state.blob_domain.shareCount(concurrency.BlobHandle.fromBits(handle_bits)) orelse return -1;
    return @intCast(count);
}

/// Opaque identity token of the payload buffer (its address bits): equal
/// tokens ⟺ the SAME bytes in memory — the pointer-identity witness the
/// zero-copy share tests assert on. 0 when not owned/stale.
export fn zap_blob_identity(process: *anyopaque, handle_bits: u64) callconv(.c) u64 {
    if (!callerOwnsBlob(process, handle_bits)) return 0;
    const payload = runtime_state.blob_domain.payloadPointer(concurrency.BlobHandle.fromBits(handle_bits)) orelse return 0;
    return @intFromPtr(payload);
}

/// Number of live blobs in the domain (test/observability surface — the
/// leak-exactness oracle Zap tests assert against).
export fn zap_blob_live_count() callconv(.c) u64 {
    if (!runtime_initialized) return 0;
    return runtime_state.blob_domain.statistics().live_blob_count;
}

/// SEND half of the blob share: verify the sender owns `handle_bits`,
/// atomically retain one FLIGHT reference (owned by the in-flight envelope,
/// not any ledger), and return the payload pointer to ride the moved
/// envelope (`zap_proc_send_moved`) with `byte_length` written through.
/// Null when the sender does not own the handle. The flight reference is
/// consumed by receiver adoption (`zap_blob_adopt`), released by the sender
/// on dead-letter, or released by the envelope reclaim hook
/// (`zap_blob_flight_release`) when the receiver dies with the envelope
/// still queued.
export fn zap_blob_flight_retain(
    process: *anyopaque,
    handle_bits: u64,
    out_byte_length: *usize,
) callconv(.c) ?[*]const u8 {
    out_byte_length.* = 0;
    if (!callerOwnsBlob(process, handle_bits)) return null;
    const handle = concurrency.BlobHandle.fromBits(handle_bits);
    // Rooted in the ledger-verified owned reference, so the count is
    // pinned above zero and the retain cannot race a free.
    if (!runtime_state.blob_domain.tryRetain(handle)) return null;
    const payload = runtime_state.blob_domain.payloadPointer(handle).?;
    out_byte_length.* = runtime_state.blob_domain.byteLength(handle).?;
    return payload;
}

/// Release one FLIGHT reference by payload pointer — the moved-envelope
/// reclaim hook (a blob envelope drained at receiver teardown) and the
/// sender's dead-letter undo path. Callable from ANY thread (the atomic
/// tier's whole point).
export fn zap_blob_flight_release(payload_pointer: [*]const u8) callconv(.c) void {
    _ = runtime_state.blob_domain.release(concurrency.BlobDomain.handleForPayloadPointer(payload_pointer));
}

/// RECEIVE half of the blob share: transfer the moved envelope's flight
/// reference to the calling process — recover the handle from the payload
/// header and record it in the receiver's ledger (no count change: the
/// flight +1 becomes the receiver's owned reference). Returns the handle
/// bits, or 0 when the ledger allocation fails (the flight reference is
/// then released so nothing leaks; the runtime panics — OOM posture).
export fn zap_blob_adopt(process: *anyopaque, payload_pointer: [*]const u8) callconv(.c) u64 {
    const handle = concurrency.BlobDomain.handleForPayloadPointer(payload_pointer);
    contextFromHandle(process).blobLedger().append(handle.toBits()) catch {
        _ = runtime_state.blob_domain.release(handle);
        return 0;
    };
    return handle.toBits();
}

/// Store the caller-owned blob under atom `key` in the global immutable
/// registry (the `persistent_term` analogue), retaining one reference FOR
/// THE REGISTRY; a put on an existing key REPLACES and releases the old
/// value's registry reference (it dies with its last outside holder).
/// Returns `ZapProcStatus.ok`, `blob_not_owned`, or `out_of_memory` (the
/// fixed registry is full).
export fn zap_blob_registry_put(process: *anyopaque, key: u64, handle_bits: u64) callconv(.c) i32 {
    if (!callerOwnsBlob(process, handle_bits)) return ZapProcStatus.blob_not_owned;
    runtime_state.blob_domain.registryPut(
        @truncate(key),
        concurrency.BlobHandle.fromBits(handle_bits),
    ) catch |err| return switch (err) {
        error.RegistryFull => ZapProcStatus.out_of_memory,
        // The ledger gate above already vouched for the handle; a stale
        // result here would mean the owned count hit zero concurrently,
        // which ownership precludes — kernel bug.
        error.StaleBlobHandle => unreachable,
    };
    return ZapProcStatus.ok;
}

/// Look up atom `key` in the global registry; when present, atomically
/// retain one reference for the calling process (recorded in its ledger —
/// released explicitly or at teardown like any acquisition). Lock-free
/// (see `blob.zig`, `registryGet`). Returns the handle bits, or 0 when the
/// key is absent (or the ledger allocation failed, in which case the
/// granted reference is released first).
export fn zap_blob_registry_get(process: *anyopaque, key: u64) callconv(.c) u64 {
    const handle = runtime_state.blob_domain.registryGet(@truncate(key)) orelse return 0;
    contextFromHandle(process).blobLedger().append(handle.toBits()) catch {
        _ = runtime_state.blob_domain.release(handle);
        return 0;
    };
    return handle.toBits();
}

// ---------------------------------------------------------------------------
// Intrinsics — the Blob-backed String tier (P6-J3, plan item 6.3)
//
// The `zap_blob_string_*` surface behind `src/runtime.zig`'s large-string
// send/receive/concat integration (rev-2 §5.4). A Zap `String` is a bare
// `[]const u8`, so blob-backing is recognized from the pointer LAYOUT
// (`BlobDomain.resolveWholePayloadView` — whole-payload views only, the
// copy-out-slices law) and gated on the caller's ledger exactly like every
// other blob intrinsic. POLICY (the promotion threshold, when a send
// promotes) lives in the runtime; these entry points are mechanism only.
// ---------------------------------------------------------------------------

/// The fixed page offset of every blob payload — the runtime caches this at
/// startup for its inline pre-filter on the string-concat hot path (one
/// mask-and-compare before any C-ABI call). Pure layout constant; callable
/// before runtime init.
export fn zap_blob_string_payload_offset() callconv(.c) u64 {
    return concurrency.blob.payloadPageOffset();
}

/// SEND half for an ALREADY blob-backed string: when `{string_pointer,
/// string_length}` is the whole-payload view of a live blob the calling
/// process owns, atomically retain one FLIGHT reference and return the
/// payload pointer to ride the moved envelope (the sender keeps its own
/// reference — its string stays readable). Null when the string is not
/// this process's whole-blob view — the caller then promotes a fresh copy
/// (`zap_blob_string_create_flight`), which is sound in every case.
export fn zap_blob_string_flight_retain(
    process: *anyopaque,
    string_pointer: [*]const u8,
    string_length: usize,
) callconv(.c) ?[*]const u8 {
    const handle = runtime_state.blob_domain.resolveWholePayloadView(
        string_pointer,
        string_length,
    ) orelse return null;
    if (!contextFromHandle(process).blobLedger().contains(handle.toBits())) return null;
    // Rooted in the ledger-verified owned reference, so the count is pinned
    // above zero; a failed retain is unreachable for an owned handle, and
    // declining here would still be sound (the caller promotes a copy).
    if (!runtime_state.blob_domain.tryRetain(handle)) return null;
    return string_pointer;
}

/// Promote a string's bytes into a fresh blob at the SEND BOUNDARY — the
/// one copy of the string's cross-process life. The new blob's single
/// reference IS the flight reference (no ledger entry anywhere): it is
/// consumed by receiver adoption (`zap_blob_adopt`), released by the sender
/// on dead-letter, or released by the envelope reclaim hook
/// (`zap_blob_flight_release`). Returns the payload pointer (page-slack
/// capacity included, so the receiver can append in place), or null on
/// allocation failure / table exhaustion (the runtime panics — OOM posture).
export fn zap_blob_string_create_flight(
    bytes_pointer: [*]const u8,
    byte_length: usize,
) callconv(.c) ?[*]const u8 {
    const handle = runtime_state.blob_domain.createFromParts(
        bytes_pointer[0..byte_length],
        &.{},
        0,
    ) catch return null;
    return runtime_state.blob_domain.payloadPointer(handle).?;
}

/// String concat over a blob-backed base — the `String.concat` integration
/// (the `<>` operator's runtime). Two legs, one call:
///
///   * **rc==1 in-place append** (the Erlang writable-binary optimization):
///     when the base is the whole view of a blob this process solely owns
///     and the capacity has room, `extra` is copied in at the frontier and
///     `out_payload` is the UNCHANGED base pointer — no allocation, no
///     copy of the base.
///   * **copy-on-shared / growth re-promotion**: otherwise a fresh blob is
///     created carrying `base ++ extra` with capacity ≥ 2× the base blob's
///     (geometric growth — amortized O(1) per appended byte), recorded in
///     the caller's ledger, and `out_payload` is the NEW payload. The base
///     blob's ledger reference is deliberately KEPT (it drains at teardown):
///     same-process aliases of the base string must stay readable, exactly
///     the bump-arena lifetime discipline ordinary strings already have.
///
/// Returns `ok` with `out_payload` set, `string_not_blob_backed` when the
/// base is not this process's whole-blob view (the runtime keeps its
/// ordinary string path), or `out_of_memory`.
export fn zap_blob_string_concat(
    process: *anyopaque,
    base_pointer: [*]const u8,
    base_length: usize,
    extra_pointer: [*]const u8,
    extra_length: usize,
    out_payload: *?[*]const u8,
) callconv(.c) i32 {
    out_payload.* = null;
    const handle = runtime_state.blob_domain.resolveWholePayloadView(
        base_pointer,
        base_length,
    ) orelse return ZapProcStatus.string_not_blob_backed;
    const ledger = contextFromHandle(process).blobLedger();
    if (!ledger.contains(handle.toBits())) return ZapProcStatus.string_not_blob_backed;

    const extra = extra_pointer[0..extra_length];
    if (runtime_state.blob_domain.tryAppendInPlace(handle, base_length, extra)) {
        out_payload.* = base_pointer;
        return ZapProcStatus.ok;
    }

    // Shared (frozen) or out of capacity: re-promote with geometric growth.
    const base = base_pointer[0..base_length];
    const base_capacity = runtime_state.blob_domain.payloadCapacity(handle).?;
    const growth_capacity = std.math.mul(usize, base_capacity, 2) catch
        return ZapProcStatus.out_of_memory;
    const promoted = runtime_state.blob_domain.createFromParts(base, extra, growth_capacity) catch
        return ZapProcStatus.out_of_memory;
    ledger.append(promoted.toBits()) catch {
        _ = runtime_state.blob_domain.release(promoted);
        return ZapProcStatus.out_of_memory;
    };
    out_payload.* = runtime_state.blob_domain.payloadPointer(promoted).?;
    return ZapProcStatus.ok;
}

/// Terminate the calling process NORMALLY (reason `normal`, P5-J1): the same
/// clean exit as returning from its entry. A linked non-trapping process is NOT
/// killed; a trapping linked/monitoring process receives `{'EXIT', Self, normal}`
/// / a `DOWN`. Never returns. (For an abnormal self-exit, see
/// `zap_proc_exit_reason`.)
export fn zap_proc_exit(process: *anyopaque) callconv(.c) noreturn {
    const context = contextFromHandle(process);
    // Record the `normal` reason, mark, then yield at a safepoint: the scheduler
    // observes `pending_kill` when the quantum ends and tears the process down
    // with the recorded reason instead of resuming it — the yield cannot return.
    context.exitSelf(.normal, runtime_state.signal_runtime.reason_atoms.normalTerm());
    unreachable;
}

/// The preemption safepoint (plan decision 6 / item 2.5): decrement the
/// quantum budget and yield when it is exhausted, when the watchdog flag
/// is set, or when a kill is pending (in which case the call never
/// returns). P2-J2's safepoint emission lowers alloc-piggyback and
/// back-edge polls onto this intrinsic.
export fn zap_proc_yield_check(process: *anyopaque) callconv(.c) void {
    contextFromHandle(process).yieldCheck();
}

/// `Process.blocking` (P4-J3, plan item 4.3): run `operation` on the blocking /
/// dirty-scheduler pool, evacuating THIS process's fiber off its core for the
/// duration so the core is freed to run its other processes. Returns the
/// operation's opaque result once the process has re-attached onto a core. See
/// `ProcessContext.blocking` for the full detach/re-attach mechanism and the
/// blocking-op contract (a leaf native call that must not re-enter the
/// scheduler). `operation` and its result are opaque pointer-sized values; the
/// `lib/process.zap` `Process.blocking` surface boxes/unboxes a typed result
/// (e.g. `i64`) around this ABI. On a runtime with no blocking pool the call
/// degrades to running the operation inline (documented single-core fallback).
export fn zap_proc_blocking(
    process: *anyopaque,
    operation: concurrency.BlockingOperation,
    operation_argument: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    return contextFromHandle(process).blocking(operation, operation_argument);
}

/// Slow path of the compiler-emitted three-layer preemption safepoints
/// (plan item 2.5, P2-J6). The ZIR-emitted layer-2 bare back-edge poll
/// and the runtime's layer-1 alloc piggyback both call this — with NO
/// process handle — when their reduction counter reaches zero, i.e. a
/// quantum's worth of reductions has elapsed. It first refreshes the
/// layer-1 running counter (`refreshReductionCounter`) so allocations made
/// before the root process is scheduled do not re-enter the slow path on
/// every call, then, when a process is current, runs the yield-if-warranted
/// safepoint (`ProcessContext.reductionSafepoint`: yields on kill / watchdog
/// / a co-runnable peer, else returns switch-free). Unlike
/// `zap_proc_yield_check`, it resolves the current process itself (the
/// ambient-lookup companion to the parameter-threaded discipline, matching
/// `zap_proc_current`) because the emitted safepoint sites cannot thread a
/// handle through every Zap call frame in Phase 2.
export fn zap_proc_safepoint_slow() callconv(.c) void {
    process_module.refreshReductionCounter();
    if (!runtime_initialized) return;
    const core = concurrency.Scheduler.currentThreadScheduler() orelse return;
    const context = core.currentProcessContext() orelse return;
    context.reductionSafepoint();
}

/// C-ABI result of `zap_proc_receive_wait_timeout` (mirrored by the
/// runtime-side `wait_for_message`). Non-negative domain outcomes.
pub const ZapProcWaitOutcome = struct {
    /// A message is at the mailbox head (a following receive pops it).
    pub const message_available: i32 = 0;
    /// The `after` timeout elapsed with no message.
    pub const timed_out: i32 = 1;
};

/// Park the calling process until a USER message is queued or
/// `timeout_nanoseconds` elapses — the `receive … after` timeout
/// mechanism (plan item 2.3, P2-J3). Queued signal envelopes do NOT
/// satisfy the wait (P5-R1): the receive would skip them, so reporting
/// one available would park the receive past its deadline. Returns
/// `ZapProcWaitOutcome.message_available` (a following
/// `zap_proc_receive_park` then takes it WITHOUT blocking) or `.timed_out`.
/// `timeout_nanoseconds == 0` probes once WITHOUT parking (`after 0`). The
/// wait is NON-consuming; a message that races the deadline wins. If the
/// process is killed while parked, the call never returns.
export fn zap_proc_receive_wait_timeout(
    process: *anyopaque,
    timeout_nanoseconds: u64,
) callconv(.c) i32 {
    const context = contextFromHandle(process);
    return switch (context.receiveWaitTimeout(timeout_nanoseconds)) {
        .message_available => ZapProcWaitOutcome.message_available,
        .timed_out => ZapProcWaitOutcome.timed_out,
    };
}

/// Route a mailbox message that matched no `receive` arm to the
/// non-crashing dead-letter path: record unexpected-message telemetry
/// (`Scheduler.unexpected_message_total` — never a silent drop) and
/// terminate the calling process through the kill path (never the
/// scheduler). Never returns. The keep-alive dead-letter sink is Phase 5.
export fn zap_proc_dead_letter_unexpected(process: *anyopaque) callconv(.c) noreturn {
    contextFromHandle(process).deadLetterUnexpected();
}

// ---------------------------------------------------------------------------
// Kernel signal primitives (P5-J1, `signal.zig`): the minimal intrinsic surface
// J2 (`spawn_link`/`spawn_monitor`) and J3 (supervisors) lower onto. Links,
// monitors, exit signals, and `trap_exit` — the MECHANISM only; all supervision
// POLICY is pure Zap stdlib. Reason atoms (`normal`/`killed`/`noproc`) are
// registered by the Zap surface (`zap_proc_set_reason_atoms`), so no Zap atom
// name is ever hardcoded here.
// ---------------------------------------------------------------------------

/// Register the three well-known reason atom ids the kernel must synthesize
/// (`normal` for a clean exit, `killed` for a kill, `noproc` for addressing a
/// dead process). Idempotent; the Zap signal wrappers call it before first use.
export fn zap_proc_set_reason_atoms(normal_term: u64, killed_term: u64, noproc_term: u64) callconv(.c) void {
    if (!runtime_initialized) return;
    runtime_state.signal_runtime.reason_atoms.set(normal_term, killed_term, noproc_term);
}

/// `link(pid)`: establish a bidirectional link (idempotent, one-per-pair). A
/// link to an already-dead process delivers a `noproc` exit to the caller.
/// Returns whether the link was established (false ⇒ the target was dead).
export fn zap_proc_link(process: *anyopaque, target_pid_bits: u64) callconv(.c) bool {
    return contextFromHandle(process).link(concurrency.Pid.fromBits(target_pid_bits));
}

/// `unlink(pid)`: break a bidirectional link (idempotent). Returns whether a
/// link existed.
export fn zap_proc_unlink(process: *anyopaque, target_pid_bits: u64) callconv(.c) bool {
    return contextFromHandle(process).unlink(concurrency.Pid.fromBits(target_pid_bits));
}

/// `monitor(pid) -> Ref`: install a unidirectional, stackable monitor and
/// return its fresh unique reference. Monitoring an already-dead process fires
/// a `noproc` `DOWN` to the caller immediately and still returns a ref.
export fn zap_proc_monitor(process: *anyopaque, target_pid_bits: u64) callconv(.c) u64 {
    return contextFromHandle(process).monitor(concurrency.Pid.fromBits(target_pid_bits));
}

/// `demonitor(Ref)`: drop a monitor this process holds. Returns whether the ref
/// named a live outgoing monitor.
export fn zap_proc_demonitor(process: *anyopaque, ref: u64) callconv(.c) bool {
    return contextFromHandle(process).demonitor(ref);
}

/// `exit(pid, reason)`: send a TRAPPABLE exit signal. `reason_kind` is the
/// Zap-classified category: 0 = `normal` (never kills a non-trapping target),
/// non-zero = `abnormal`. `reason_term` is the reason atom carried to a trapping
/// target / delivered as `{'EXIT', From, Reason}`. Returns `ZapProcStatus.ok`
/// (delivered) or `dead_lettered` (target dead — a silent no-op, Erlang).
export fn zap_proc_exit_signal(
    process: *anyopaque,
    target_pid_bits: u64,
    reason_kind: u8,
    reason_term: u64,
) callconv(.c) i32 {
    const category: concurrency.ReasonCategory = if (reason_kind == 0) .normal else .abnormal;
    return switch (contextFromHandle(process).exitSignal(concurrency.Pid.fromBits(target_pid_bits), category, reason_term)) {
        .delivered => ZapProcStatus.ok,
        .dead_lettered => ZapProcStatus.dead_lettered,
    };
}

/// `exit(pid, kill)`: the UNTRAPPABLE kill. The target dies with reason `killed`
/// regardless of `trap_exit`. Returns `ok` (delivered) or `dead_lettered`.
export fn zap_proc_kill(process: *anyopaque, target_pid_bits: u64) callconv(.c) i32 {
    return switch (contextFromHandle(process).killUntrappable(concurrency.Pid.fromBits(target_pid_bits))) {
        .delivered => ZapProcStatus.ok,
        .dead_lettered => ZapProcStatus.dead_lettered,
    };
}

/// Set this process's `trap_exit` flag (Erlang `process_flag(trap_exit, _)`),
/// returning the previous value.
export fn zap_proc_set_trap_exit(process: *anyopaque, value: bool) callconv(.c) bool {
    return contextFromHandle(process).setTrapExit(value);
}

/// Whether this process traps exits.
export fn zap_proc_trap_exit(process: *anyopaque) callconv(.c) bool {
    return contextFromHandle(process).trapsExits();
}

/// Self-terminate with an explicit reason. `reason_kind`: 0 = `normal`,
/// non-zero = `abnormal`. Never returns.
export fn zap_proc_exit_reason(process: *anyopaque, reason_kind: u8, reason_term: u64) callconv(.c) noreturn {
    const context = contextFromHandle(process);
    const category: concurrency.ReasonCategory = if (reason_kind == 0) .normal else .abnormal;
    context.exitSelf(category, reason_term);
    unreachable;
}

/// Blocking receive of the next SIGNAL message (raw J1 surface): extracts the
/// oldest exit/`DOWN` envelope — ordinary user messages are SKIPPED and stay
/// queued, in order, for the steady-state receive (P5-R1) — caches its fields,
/// frees it, and returns the reason term. `zap_proc_last_signal_*` read the
/// other fields.
export fn zap_proc_await_signal(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).awaitSignal();
}

/// C-ABI outcomes of `zap_proc_await_signal_timeout`.
pub const ZapProcSignalWaitOutcome = struct {
    /// A signal was consumed and cached (read via `zap_proc_last_signal_*`).
    pub const signal_consumed: i32 = 0;
    /// The deadline elapsed with no signal.
    pub const timed_out: i32 = 1;
};

/// `zap_proc_await_signal` bounded by a deadline — the timed signal wait the
/// supervisor `:timeout` shutdown protocol stands on (P5-R1). Blocks until a
/// signal envelope is queued (user messages skipped, left queued) or
/// `timeout_nanoseconds` elapses; `0` probes once without parking. On
/// `signal_consumed` the fields are cached exactly like `zap_proc_await_signal`
/// (read the reason via `zap_proc_last_signal_reason`). If the process is
/// killed while waiting, the call never returns.
export fn zap_proc_await_signal_timeout(
    process: *anyopaque,
    timeout_nanoseconds: u64,
) callconv(.c) i32 {
    if (contextFromHandle(process).awaitSignalTimeout(timeout_nanoseconds)) |_| {
        return ZapProcSignalWaitOutcome.signal_consumed;
    }
    return ZapProcSignalWaitOutcome.timed_out;
}

/// The `from` pid bits of the most recently `zap_proc_await_signal`-consumed
/// signal (the exiting process for an exit, the monitored process for a `DOWN`).
export fn zap_proc_last_signal_from(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).lastSignalFrom();
}

/// The monitor ref of the most recently consumed signal (`DOWN` only; 0 else).
export fn zap_proc_last_signal_ref(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).lastSignalRef();
}

/// The kind of the most recently consumed signal (1 = exit, 2 = down).
export fn zap_proc_last_signal_kind(process: *anyopaque) callconv(.c) i64 {
    return contextFromHandle(process).lastSignalKind();
}

/// The reason term of the most recently consumed signal (`zap_proc_await_signal`
/// or a down-consumed `zap_proc_receive_correlated`) — the field
/// `await_signal` returns directly, exposed for the correlated path where the
/// outcome code and the reason must both be readable.
export fn zap_proc_last_signal_reason(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).lastSignalReason();
}

// ---------------------------------------------------------------------------
// The correlated receive (P5-J4): the INTERNAL `call`/`Task.await` machinery —
// research §6.2's ref-trick receive-mark, zap-concurrency-research §5.2's
// resolved "internal correlation-token skip" (decision 7). Never surface
// syntax; the steady-state exhaustive `receive` above is untouched. See
// `mailbox.zig` ("The correlated receive + receive-mark") for the mark/skip
// semantics and `scheduler.zig` (`receiveCorrelated`) for the wait.
// ---------------------------------------------------------------------------

/// Capture the receive-mark at the calling process's current mailbox
/// position. MUST be called BEFORE the correlation ref is minted (a monitor
/// on a dead target fires its `noproc` `DOWN` during minting, and that
/// `DOWN` has to land after the mark); pair with `zap_proc_recv_mark_bind`.
export fn zap_proc_recv_mark_prepare(process: *anyopaque) callconv(.c) void {
    contextFromHandle(process).prepareReceiveMark();
}

/// Bind the prepared receive-mark to the freshly-minted `ref` it serves.
export fn zap_proc_recv_mark_bind(process: *anyopaque, ref: u64) callconv(.c) void {
    contextFromHandle(process).bindReceiveMark(ref);
}

/// Send `payload_len` opaque bytes to `target_pid_bits` stamped with the
/// correlation `ref` — the reply half of the `call`/`Task` protocol. The
/// stamp lives in the envelope HEADER (`Fragment.correlation_ref`), so the
/// receiver's correlated receive matches it without interpreting payload
/// bytes. Everything else is `zap_proc_send` exactly (copy transport,
/// dead-letter semantics, status codes).
export fn zap_proc_send_correlated(
    process: *anyopaque,
    target_pid_bits: u64,
    ref: u64,
    payload_pointer: ?[*]const u8,
    payload_len: usize,
) callconv(.c) i32 {
    const context = contextFromHandle(process);
    const target = concurrency.Pid.fromBits(target_pid_bits);

    var fragment = mailbox_module.Fragment{ .correlation_ref = ref };
    var payload_block: ?*LedgerBlock = null;
    if (payload_len > 0) {
        const block = runtime_state.ledger.allocate(payload_len) catch
            return ZapProcStatus.out_of_memory;
        @memcpy(block.bodyPointer()[0..payload_len], payload_pointer.?[0..payload_len]);
        fragment.payload_pointer = block.bodyPointer();
        fragment.payload_byte_length = payload_len;
        payload_block = block;
    }

    const outcome = context.send(target, fragment) catch {
        if (payload_block) |block| runtime_state.ledger.free(block);
        return ZapProcStatus.out_of_memory;
    };
    return switch (outcome) {
        .delivered => ZapProcStatus.ok,
        .dead_lettered => blk: {
            if (payload_block) |block| runtime_state.ledger.free(block);
            break :blk ZapProcStatus.dead_lettered;
        },
    };
}

/// C-ABI outcomes of `zap_proc_receive_correlated` (the tag values of
/// `scheduler.AwaitCorrelatedOutcome`).
pub const ZapProcCorrelatedOutcome = struct {
    /// A correlated user REPLY arrived and is stashed; decode it with
    /// `zap_proc_take_correlated`.
    pub const reply_ready: i32 = 0;
    /// The monitor `DOWN` carrying the ref arrived instead; its fields are
    /// cached (`zap_proc_last_signal_from`/`_reason`), the envelope freed.
    pub const down_consumed: i32 = 1;
    /// The timeout elapsed with no correlated message.
    pub const timed_out: i32 = 2;
};

/// Block until the message correlated with `ref` arrives — a user reply
/// stamped by `zap_proc_send_correlated`, or the monitor `DOWN` carrying
/// `ref` — or until `timeout_nanoseconds` elapses. Skipped messages remain
/// queued, in order, for the steady-state receive. Scanning starts at the
/// receive-mark when it is armed for `ref` (the O(1) skip past any older
/// backlog); a reply outcome is stashed for the immediately-following
/// `zap_proc_take_correlated`. If the process is killed while waiting, the
/// call never returns.
export fn zap_proc_receive_correlated(
    process: *anyopaque,
    ref: u64,
    timeout_nanoseconds: u64,
) callconv(.c) i32 {
    const context = contextFromHandle(process);
    return @intFromEnum(context.awaitCorrelated(ref, timeout_nanoseconds));
}

/// Take the reply envelope stashed by the last `reply_ready`
/// `zap_proc_receive_correlated`, returning it as the same opaque
/// borrowed-payload reference `zap_proc_receive_park` yields (release it
/// with `zap_proc_envelope_free`; a moved payload is claimed with
/// `zap_proc_envelope_take_moved`). Aborts if nothing is stashed — the
/// call/await machinery always pairs the two calls.
export fn zap_proc_take_correlated(
    process: *anyopaque,
    out_payload_pointer: *?[*]const u8,
    out_payload_len: *usize,
) callconv(.c) *anyopaque {
    const context = contextFromHandle(process);
    const envelope = context.takeCorrelatedStash();
    out_payload_pointer.* = envelope.fragment.payload_pointer;
    out_payload_len.* = envelope.fragment.payload_byte_length;
    return @ptrCast(envelope);
}

/// `demonitor(ref)` + FLUSH (Elixir `Process.demonitor(ref, [:flush])`):
/// drop the monitor and guarantee no `DOWN` for `ref` is ever observed by
/// the calling process afterwards — the cleanup the call/await reply and
/// timeout paths run so a late `DOWN` can never poison a later steady-state
/// receive. Returns whether `ref` named a live outgoing monitor. See
/// `Scheduler.signalDemonitorFlush` for the three-case race analysis.
export fn zap_proc_demonitor_flush(process: *anyopaque, ref: u64) callconv(.c) bool {
    return contextFromHandle(process).demonitorFlush(ref);
}

/// Cumulative count of envelopes examined by the calling process's
/// correlated receives — the R8 operation-count telemetry that PROVES the
/// O(1)-from-mark skip (a correlated receive over a 10k-message backlog
/// examines a handful of envelopes when the mark is armed, 10k+ when not).
export fn zap_proc_correlated_scan_visits(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).correlatedScanVisits();
}

/// The current MONOTONIC time in nanoseconds, read through the scheduler's clock
/// seam (the same clock as `receive … after`). The `lib/process.zap`
/// `Process.monotonic_millis` surface divides to milliseconds; supervisors
/// (`lib/supervisor.zap`) use it for the restart-intensity window. Seeded-mode:
/// reads the virtual clock, so timed policy stays reproducible under a seed.
export fn zap_proc_monotonic_nanos(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).monotonicNanos();
}

// ---------------------------------------------------------------------------
// Local process registry (P5-J2, `registry.zig`): the atomic name→pid table the
// Zap `Process.register`/`whereis`/`unregister` and send-by-name surface stand
// on. A name is an atom id (`u64`); the registry validates pid liveness through
// the pid table, so a name resolving to a dead/reused pid is a lookup MISS.
// ---------------------------------------------------------------------------

/// `register(name)`: register the CALLING process under `name` (an atom id).
/// Returns false when the name is held by another live process, or when this
/// process already holds a name (Erlang one-name-per-process). The name is
/// released automatically at this process's teardown.
export fn zap_proc_register(process: *anyopaque, name: u64) callconv(.c) bool {
    return contextFromHandle(process).registerName(name);
}

/// `unregister(name)`: release `name` if the calling process holds it
/// (idempotent). Returns whether an entry was removed.
export fn zap_proc_unregister(process: *anyopaque, name: u64) callconv(.c) bool {
    return contextFromHandle(process).unregisterName(name);
}

/// `whereis(name) -> pid bits`: resolve `name` to the raw pid bits of its LIVE
/// registrant, or `0` (the invalid pid) when unregistered or resolving to a
/// dead pid (generation-validated). The lock-free lookup path (send-by-name and
/// `Process.whereis` ride it).
export fn zap_proc_whereis(process: *anyopaque, name: u64) callconv(.c) u64 {
    return contextFromHandle(process).whereisName(name);
}

// Per-envelope signal accessors (the J2/J3 receive-lowering surface): given an
// envelope from `zap_proc_receive_park`, tell a signal from a user message and
// read its fields, so `receive` can build `{'EXIT', …}` / `{'DOWN', …}` tuples.

/// The signal kind of a parked envelope (0 = ordinary user message, 1 = exit,
/// 2 = down).
export fn zap_proc_envelope_signal_kind(envelope_handle: *anyopaque) callconv(.c) u8 {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    return @intFromEnum(envelope.fragment.signal_kind);
}

/// The `from` pid bits of a signal envelope.
export fn zap_proc_envelope_signal_from(envelope_handle: *anyopaque) callconv(.c) u64 {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    const payload: *const concurrency.SignalPayload = @ptrCast(@alignCast(envelope.fragment.payload_pointer.?));
    return payload.from_bits;
}

/// The monitor ref of a signal envelope (`down` only).
export fn zap_proc_envelope_signal_ref(envelope_handle: *anyopaque) callconv(.c) u64 {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    const payload: *const concurrency.SignalPayload = @ptrCast(@alignCast(envelope.fragment.payload_pointer.?));
    return payload.ref;
}

/// The reason term of a signal envelope.
export fn zap_proc_envelope_signal_reason(envelope_handle: *anyopaque) callconv(.c) u64 {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    const payload: *const concurrency.SignalPayload = @ptrCast(@alignCast(envelope.fragment.payload_pointer.?));
    return payload.reason_term;
}

// ---------------------------------------------------------------------------
// Tests — the kernel-side E2E proof of the intrinsic surface. The
// runtime-side smoke hook (`src/runtime.zig`, `ZAP_CONCURRENCY_SMOKE`)
// exercises the same round-trip through the extern mirror in a real
// gated-on binary.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test-only manifest-manager FACTORY double for the kernel's OWN standalone
/// test binary. The PRODUCTION binding is the real `Memory.ARC` manager,
/// handed in by `src/runtime.zig`'s bootstrap; the kernel test binary has no
/// access to that fork-compiled object, so it drives the
/// `ManifestManagerBinding` adapter with this page-allocator core double
/// (clearly test-scoped, per the deliverable's "test-only double where a
/// std-allocator manager is genuinely needed" carve-out).
///
/// Unlike the Phase-2 shared-context double, this is a REAL per-instance
/// FACTORY: every `init` mints a fresh private `Context` (an arena over the
/// backing allocator) and every `deinit` wholesale-frees it — the exact
/// shape the production ARC manager has (`arcInit`/`arcDeinit`), so the
/// per-process-instance tests below exercise the same create/allocate/
/// wholesale-free lifecycle the real manager runs. Factory-wide accounting
/// (`init_total`/`deinit_total`/`live_context_count`/`live_bytes_total`) is
/// the leak-exactness oracle: a process that dies with still-live bytes must
/// see them reclaimed by ITS context's `deinit`, driving `live_bytes_total`
/// back to zero across spawn/die cycles.
const TestManagerCore = struct {
    /// One process's private heap: an arena plus its own live-byte count.
    const Context = struct {
        arena: std.heap.ArenaAllocator,
        live_bytes: usize,
    };

    // Factory-wide accounting across every context this double mints. ATOMIC
    // (P4-J1): under the M:N pool a wave's processes are minted and torn down on
    // DIFFERENT cores concurrently, so these shared counters are cross-thread —
    // a per-process context's OWN `live_bytes` stays non-atomic (touched only by
    // the one core running that process). The counters are test instrumentation;
    // the production per-process contexts are private and unaffected.
    var init_total: std.atomic.Value(usize) = .init(0);
    var deinit_total: std.atomic.Value(usize) = .init(0);
    var live_context_count: std.atomic.Value(usize) = .init(0);
    var live_bytes_total: std.atomic.Value(usize) = .init(0);

    /// Zero the factory accounting at the start of a per-instance test so its
    /// assertions start from a known baseline (called before any spawn — no
    /// concurrent core, so a plain store is fine).
    fn resetAccounting() void {
        init_total.store(0, .monotonic);
        deinit_total.store(0, .monotonic);
        live_context_count.store(0, .monotonic);
        live_bytes_total.store(0, .monotonic);
    }

    const core = ZapMemoryManagerCoreV1{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = initThunk,
        .deinit = deinitThunk,
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .get_capability_desc = nullCapabilityLookup,
    };

    /// Typed null capability lookup: `createProcessBinding` probes every
    /// spawned process's core for the descriptor-only `ARSR`/`STAT`
    /// capabilities (P6-J4), so a test core's slot must be CALLABLE with the
    /// real signature — an opaque placeholder would be undefined behavior at
    /// the first spawn. Answering null means "no capabilities" (spec §5.5).
    fn nullCapabilityLookup(context: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
        _ = context;
        _ = id;
        return null;
    }

    fn initThunk(options: ?*const anyopaque) callconv(.c) ?*anyopaque {
        _ = options;
        const context = backing_allocator.create(Context) catch return null;
        context.* = .{ .arena = std.heap.ArenaAllocator.init(backing_allocator), .live_bytes = 0 };
        _ = init_total.fetchAdd(1, .monotonic);
        _ = live_context_count.fetchAdd(1, .monotonic);
        return @ptrCast(context);
    }

    fn deinitThunk(context_pointer: *anyopaque) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(context_pointer));
        // Wholesale free: the arena releases every still-live allocation in
        // one call — the leak-exact per-process teardown this double proves.
        std.debug.assert(live_bytes_total.load(.monotonic) >= context.live_bytes);
        _ = live_bytes_total.fetchSub(context.live_bytes, .monotonic);
        context.arena.deinit();
        backing_allocator.destroy(context);
        _ = deinit_total.fetchAdd(1, .monotonic);
        std.debug.assert(live_context_count.load(.monotonic) > 0);
        _ = live_context_count.fetchSub(1, .monotonic);
    }

    fn allocateThunk(context_pointer: *anyopaque, byte_length: usize, alignment: u32) callconv(.c) ?[*]u8 {
        const context: *Context = @ptrCast(@alignCast(context_pointer));
        const memory = context.arena.allocator().rawAlloc(
            byte_length,
            std.mem.Alignment.fromByteUnits(alignment),
            @returnAddress(),
        ) orelse return null;
        context.live_bytes += byte_length;
        _ = live_bytes_total.fetchAdd(byte_length, .monotonic);
        return memory;
    }

    fn deallocateThunk(context_pointer: *anyopaque, memory: [*]u8, byte_length: usize, alignment: u32) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(context_pointer));
        context.arena.allocator().rawFree(memory[0..byte_length], std.mem.Alignment.fromByteUnits(alignment), @returnAddress());
        std.debug.assert(context.live_bytes >= byte_length);
        context.live_bytes -= byte_length;
        std.debug.assert(live_bytes_total.load(.monotonic) >= byte_length);
        _ = live_bytes_total.fetchSub(byte_length, .monotonic);
    }
};

/// Bind the kernel test double factory as the manifest manager — the
/// test-suite mirror of what `src/runtime.zig`'s bootstrap does with the
/// real ARC manager. Call after `zap_proc_runtime_init` in any test that
/// spawns.
fn bindTestManager() void {
    _ = zap_proc_bind_manager(@ptrCast(&TestManagerCore.core));
}

test "abi: per-process binding mints a fresh private context and wholesale-frees it at teardown" {
    // The section under test needs the runtime live so `createProcessBinding`
    // can allocate the per-process `ProcessManagerBinding` and the ledger is
    // available for the teardown path.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_bind_manager(@ptrCast(&TestManagerCore.core)));

    // Two spawns get two DISTINCT private contexts (the per-process model,
    // not a shared instance) — distinct bindings, each over its own context.
    const first = createProcessBinding(&TestManagerCore.core) orelse return error.TestUnexpectedResult;
    const second = createProcessBinding(&TestManagerCore.core) orelse return error.TestUnexpectedResult;
    try testing.expect(first.manager_state.? != second.manager_state.?);
    try testing.expect(processBinding(first.manager_state).context != processBinding(second.manager_state).context);
    try testing.expectEqual(@as(usize, 2), TestManagerCore.init_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), TestManagerCore.live_context_count.load(.monotonic));

    // Allocate into the first context and DELIBERATELY do not free it — the
    // killed-process shape whose live cells must be reclaimed wholesale.
    const block = first.allocate(48, .of(u64)) orelse return error.TestUnexpectedResult;
    block[0] = 0x5A;
    block[47] = 0xA5;
    try testing.expectEqual(@as(usize, 48), TestManagerCore.live_bytes_total.load(.monotonic));

    // heapByteCount is advisory 0 (no per-context query on the v1.0 core).
    try testing.expectEqual(@as(usize, 0), first.heapByteCount());

    // teardown is a REAL wholesale free (Phase 3): it reclaims the still-live
    // block and destroys the private context — no per-cell free needed.
    first.teardown();
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), TestManagerCore.deinit_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), TestManagerCore.live_context_count.load(.monotonic));

    // The second context is independent — untouched by the first's teardown.
    second.teardown();
    try testing.expectEqual(@as(usize, 2), TestManagerCore.deinit_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count.load(.monotonic));
}

test "abi: zap_proc_bind_manager validates the core ABI and gates spawn (no fallback arena)" {
    // Binding before init reports not_initialized.
    try testing.expectEqual(
        ZapProcStatus.not_initialized,
        zap_proc_bind_manager(@ptrCast(&TestManagerCore.core)),
    );

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();

    // A non-1 ABI major is rejected.
    const bad_core = ZapMemoryManagerCoreV1{
        .abi_major = 2,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = TestManagerCore.initThunk,
        .deinit = TestManagerCore.deinitThunk,
        .allocate = TestManagerCore.allocateThunk,
        .deallocate = TestManagerCore.deallocateThunk,
        .get_capability_desc = TestManagerCore.nullCapabilityLookup,
    };
    try testing.expectEqual(
        ZapProcStatus.manager_abi_unsupported,
        zap_proc_bind_manager(@ptrCast(&bad_core)),
    );

    // Spawn is gated until a valid manager is bound.
    try testing.expectEqual(concurrency.Pid.invalid.toBits(), zap_proc_spawn(smokeReceiverEntry, null));
    bindTestManager();
    const pid_bits = zap_proc_spawn(smokeReceiverEntry, null);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    // The parked receiver is torn down by deinit (shutdownAllProcesses).
}

// -- per-spawn manager registry (plan item 3.1/3.3, P3-J3) ----------------------

/// A second test manager core reusing `TestManagerCore`'s per-instance factory
/// thunks + accounting but advertising REFCOUNTED capabilities (`declared_caps
/// = 0x1`). The registry/model-bit tests register two DISTINCT-MODEL managers
/// into one runtime and prove `zap_proc_spawn_at` selects the right one and
/// stamps each pid with its manager's reclamation model.
const test_refcounted_core = ZapMemoryManagerCoreV1{
    .abi_major = 1,
    .abi_minor = 0,
    .size = @sizeOf(ZapMemoryManagerCoreV1),
    .declared_caps = 0x1, // REFCOUNT_V1 → refcounted
    .init = TestManagerCore.initThunk,
    .deinit = TestManagerCore.deinitThunk,
    .allocate = TestManagerCore.allocateThunk,
    .deallocate = TestManagerCore.deallocateThunk,
    .get_capability_desc = TestManagerCore.nullCapabilityLookup,
};

test "abi: reclamationModelForCaps decodes the declared_caps axis encoding (pid model bits)" {
    // Name-for-name equivalent to `src/memory/elision.zig`'s `reclamationModel`
    // and the `src/memory/abi.zig` axis encoding — the plan item 3.3
    // correspondence seam the `pid_table` module doc reserves.
    try testing.expectEqual(pid_table.ReclamationModel.refcounted, reclamationModelForCaps(0x1)); // ARC
    try testing.expectEqual(pid_table.ReclamationModel.bulk_or_never, reclamationModelForCaps(0x0)); // Arena/NoOp/Leak
    try testing.expectEqual(pid_table.ReclamationModel.individual_no_refcount, reclamationModelForCaps(0x2)); // Tracking
    try testing.expectEqual(pid_table.ReclamationModel.traced, reclamationModelForCaps(0x4)); // GC
    // Reserved Axis-A code (0b11 << 1 = 0x6) maps conservatively to bulk_or_never.
    try testing.expectEqual(pid_table.ReclamationModel.bulk_or_never, reclamationModelForCaps(0x6));
    // Bit 0 dominates: a refcount manager decodes refcounted regardless of the field.
    try testing.expectEqual(pid_table.ReclamationModel.refcounted, reclamationModelForCaps(0x1 | 0x4));
}

test "abi: zap_proc_register_manager validates index range and core ABI" {
    try testing.expectEqual(
        ZapProcStatus.not_initialized,
        zap_proc_register_manager(1, @ptrCast(&TestManagerCore.core)),
    );
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();

    try testing.expectEqual(
        ZapProcStatus.manager_index_out_of_range,
        zap_proc_register_manager(MAX_MANAGER_SLOTS, @ptrCast(&TestManagerCore.core)),
    );

    const bad_core = ZapMemoryManagerCoreV1{
        .abi_major = 2,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0,
        .init = TestManagerCore.initThunk,
        .deinit = TestManagerCore.deinitThunk,
        .allocate = TestManagerCore.allocateThunk,
        .deallocate = TestManagerCore.deallocateThunk,
        .get_capability_desc = TestManagerCore.nullCapabilityLookup,
    };
    try testing.expectEqual(
        ZapProcStatus.manager_abi_unsupported,
        zap_proc_register_manager(1, @ptrCast(&bad_core)),
    );
    try testing.expectEqual(
        ZapProcStatus.ok,
        zap_proc_register_manager(1, @ptrCast(&TestManagerCore.core)),
    );
}

test "abi: zap_proc_spawn_at selects the registry manager and stamps the pid model bits" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();

    // Two DISTINCT-model managers in one runtime: slot 0 = manifest default
    // (bulk_or_never, caps=0x0), slot 1 = a refcounted manager (caps=0x1) —
    // the ARC-process + Arena-process shape a real 2-manager binary carries.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_bind_manager(@ptrCast(&TestManagerCore.core)));
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_register_manager(1, @ptrCast(&test_refcounted_core)));

    var probe = PerProcessAllocProbe{ .byte_length = 32 };

    // Spawn under each manager; the pid carries the SELECTED manager's model.
    const bulk_pid_bits = zap_proc_spawn_at(perProcessAllocatingEntry, &probe, 0);
    try testing.expect(bulk_pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(pid_table.ReclamationModel.bulk_or_never, concurrency.Pid.fromBits(bulk_pid_bits).model);

    const refcounted_pid_bits = zap_proc_spawn_at(perProcessAllocatingEntry, &probe, 1);
    try testing.expect(refcounted_pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(pid_table.ReclamationModel.refcounted, concurrency.Pid.fromBits(refcounted_pid_bits).model);

    // An UNREGISTERED slot and an out-of-range index both fail the spawn (no
    // fallback — the no-fallbacks spawn gate).
    try testing.expectEqual(concurrency.Pid.invalid.toBits(), zap_proc_spawn_at(perProcessAllocatingEntry, &probe, 2));
    try testing.expectEqual(concurrency.Pid.invalid.toBits(), zap_proc_spawn_at(perProcessAllocatingEntry, &probe, MAX_MANAGER_SLOTS));

    // Drive both processes to completion; each allocated into its OWN private
    // context and was wholesale-freed leak-exact at teardown.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());
    try testing.expectEqual(@as(usize, 2), probe.processes_run.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), TestManagerCore.init_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), TestManagerCore.deinit_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total.load(.monotonic));
}

// -- per-process private instances (plan item 3.1, P3-J1) -----------------------

/// Probe for the per-process-instance tests: each process body allocates
/// `byte_length` bytes into ITS OWN private manager context and deliberately
/// never frees it — the still-live-at-death shape the wholesale teardown must
/// reclaim. `processes_run` counts bodies that reached the allocation.
const PerProcessAllocProbe = struct {
    byte_length: usize,
    /// Bodies that reached the allocation. ATOMIC (P4-J1): the soak's wave of
    /// processes runs on different cores concurrently, so this shared counter is
    /// cross-thread.
    processes_run: std.atomic.Value(usize) = .init(0),
};

/// Allocate into this process's own private heap (through the PCB manager
/// context reached from the entry handle), then return — the normal-exit
/// path whose teardown wholesale-frees the never-freed block.
fn perProcessAllocatingEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *PerProcessAllocProbe = @ptrCast(@alignCast(argument.?));
    const context = contextFromHandle(process);
    const block = context.record.pcb.manager.allocate(probe.byte_length, .of(u64)) orelse return;
    block[0] = 0x11;
    _ = probe.processes_run.fetchAdd(1, .monotonic);
}

/// Allocate into this process's own private heap, then park forever — the
/// killed-with-live-allocations shape torn down by `shutdownAllProcesses`.
fn allocateThenParkEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *PerProcessAllocProbe = @ptrCast(@alignCast(argument.?));
    const context = contextFromHandle(process);
    const block = context.record.pcb.manager.allocate(probe.byte_length, .of(u64)) orelse return;
    block[0] = 0x22;
    _ = probe.processes_run.fetchAdd(1, .monotonic);
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    _ = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    @panic("the allocating straggler must never receive a message");
}

/// Return on the first quantum — a driver process whose exit lets
/// `zap_proc_run_until_exit` return while a straggler stays parked.
fn immediateExitEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    _ = process;
    _ = argument;
}

test "abi: each spawned process gets its own private context, wholesale-freed leak-exact at exit" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();
    bindTestManager();

    var probe = PerProcessAllocProbe{ .byte_length = 64 };
    const process_count: usize = 8;
    var index: usize = 0;
    while (index < process_count) : (index += 1) {
        const pid_bits = zap_proc_spawn(perProcessAllocatingEntry, &probe);
        try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    }
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // Every process ran and allocated into its OWN private context — one
    // context minted per spawn (NOT a shared instance).
    try testing.expectEqual(process_count, probe.processes_run.load(.monotonic));
    try testing.expectEqual(process_count, TestManagerCore.init_total.load(.monotonic));
    // Every process's context was wholesale-freed at its teardown, reclaiming
    // the never-freed 64-byte block — leak-exact, zero residue.
    try testing.expectEqual(process_count, TestManagerCore.deinit_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total.load(.monotonic));
}

test "abi: a killed process's live allocations are wholesale-freed at teardown (crash-teardown leak-exactness)" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    // The trailing deinit below is itself under test (teardown wholesale-free
    // assertions follow it), so it cannot be a plain `defer` — but a failed
    // expectation mid-test must still deinit, or the live runtime cascades
    // `already_initialized` through every later abi test (the P6 round-2
    // flake). The guard flag gives both: explicit deinit on the pass path,
    // guaranteed cleanup on every error path.
    var runtime_live = true;
    defer if (runtime_live) zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();
    bindTestManager();

    // The allocating straggler parks forever; a driver process exits so
    // `run_until_exit` returns after the straggler has taken its quantum
    // (allocated into its private heap, then parked).
    var probe = PerProcessAllocProbe{ .byte_length = 128 };
    const straggler_bits = zap_proc_spawn(allocateThenParkEntry, &probe);
    try testing.expect(straggler_bits != concurrency.Pid.invalid.toBits());
    const driver_bits = zap_proc_spawn(immediateExitEntry, null);
    try testing.expect(driver_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(driver_bits));

    // The straggler is parked with a live 128-byte allocation in its context.
    try testing.expectEqual(@as(usize, 1), probe.processes_run.load(.monotonic));
    try testing.expect(TestManagerCore.live_bytes_total.load(.monotonic) >= 128);
    try testing.expect(TestManagerCore.live_context_count.load(.monotonic) >= 1);

    // Program shutdown kills the straggler; its teardown wholesale-frees the
    // live allocation — every minted context deinit'd, zero residue.
    zap_proc_runtime_deinit();
    runtime_live = false;
    try testing.expectEqual(TestManagerCore.init_total.load(.monotonic), TestManagerCore.deinit_total.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total.load(.monotonic));
}

/// Committed default spawn/die cycles for the per-process ARC teardown soak
/// (CI-sanity sizing). Overridden by `ZAP_PROC_ARC_TEARDOWN_CYCLES` for a long
/// soak — the per-process-instance analog of `teardown_stress.zig`'s knob.
const default_proc_arc_teardown_cycles: usize = 600;

fn procArcTeardownCyclesFromEnvironment() usize {
    const raw_value = std.c.getenv("ZAP_PROC_ARC_TEARDOWN_CYCLES") orelse
        return default_proc_arc_teardown_cycles;
    return std.fmt.parseInt(usize, std.mem.span(raw_value), 10) catch default_proc_arc_teardown_cycles;
}

test "abi: per-process ARC teardown soak — spawn/die cycles stay leak-exact (teardown_stress-style)" {
    // The per-process-instance analog of the Phase-1 teardown-stress campaign
    // (`teardown_stress.zig`), extended to the REAL per-process manager
    // factory: many waves of allocating processes spawn, run, and exit through
    // `zap_proc_spawn`/wholesale teardown, each never freeing its allocation —
    // so every wave's contexts must be wholesale-freed leak-exact, driving the
    // factory accounting back to zero every wave.
    const total_cycles = procArcTeardownCyclesFromEnvironment();
    const processes_per_wave: usize = 6;
    const wave_count = @max(total_cycles / processes_per_wave, 1);

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();
    bindTestManager();

    var probe = PerProcessAllocProbe{ .byte_length = 48 };
    var wave: usize = 0;
    var spawned_total: usize = 0;
    while (wave < wave_count) : (wave += 1) {
        var index: usize = 0;
        while (index < processes_per_wave) : (index += 1) {
            const pid_bits = zap_proc_spawn(perProcessAllocatingEntry, &probe);
            try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
        }
        try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());
        spawned_total += processes_per_wave;

        // Exact per-wave accounting: every context minted so far has been
        // wholesale-freed (its never-freed cell reclaimed), no context or byte
        // outlives its process — the leak-exact invariant, checked every wave.
        try testing.expectEqual(spawned_total, TestManagerCore.init_total.load(.monotonic));
        try testing.expectEqual(spawned_total, TestManagerCore.deinit_total.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count.load(.monotonic));
        try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total.load(.monotonic));
    }
    try testing.expectEqual(spawned_total, probe.processes_run.load(.monotonic));
}

test "abi: runtime init/deinit lifecycle guards double-init and supports re-init" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    try testing.expect(runtimeIsInitialized());
    try testing.expectEqual(ZapProcStatus.already_initialized, zap_proc_runtime_init());

    zap_proc_runtime_deinit();
    try testing.expect(!runtimeIsInitialized());
    // Deinit is idempotent.
    zap_proc_runtime_deinit();

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    try testing.expect(runtimeIsInitialized());
}

test "abi: intrinsics without a live runtime fail with documented sentinels" {
    try testing.expect(!runtimeIsInitialized());
    try testing.expectEqual(
        concurrency.Pid.invalid.toBits(),
        zap_proc_spawn(smokeReceiverEntry, null),
    );
    try testing.expectEqual(ZapProcStatus.not_initialized, zap_proc_run_until_quiescent());
}

/// Shared state for the E2E round-trip test, threaded as the opaque
/// process arguments.
const RoundTripProbe = struct {
    receiver_pid_bits: u64 = 0,
    receiver_observed_self: u64 = 0,
    sender_observed_self: u64 = 0,
    received_payload_matches: bool = false,
    received_payload_len: usize = 0,
    receiver_finished: bool = false,
    sender_finished: bool = false,

    const payload = "P2-J1 round-trip payload";
};

fn smokeReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *RoundTripProbe = @ptrCast(@alignCast(argument.?));
    probe.receiver_observed_self = zap_proc_self(process);

    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    probe.received_payload_len = payload_len;
    if (payload_pointer) |pointer| {
        probe.received_payload_matches =
            std.mem.eql(u8, pointer[0..payload_len], RoundTripProbe.payload);
    }
    zap_proc_envelope_free(envelope);
    probe.receiver_finished = true;
    // Returning is the normal-exit path.
}

fn smokeSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *RoundTripProbe = @ptrCast(@alignCast(argument.?));
    probe.sender_observed_self = zap_proc_self(process);
    zap_proc_yield_check(process);
    const send_status = zap_proc_send(
        process,
        probe.receiver_pid_bits,
        RoundTripProbe.payload.ptr,
        RoundTripProbe.payload.len,
    );
    std.debug.assert(send_status == ZapProcStatus.ok);
    probe.sender_finished = true;
    zap_proc_exit(process);
}

test "abi: init → spawn → send → receive → exit round-trip through the C-ABI surface" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = RoundTripProbe{};
    const receiver_pid_bits = zap_proc_spawn(smokeReceiverEntry, &probe);
    try testing.expect(receiver_pid_bits != concurrency.Pid.invalid.toBits());
    probe.receiver_pid_bits = receiver_pid_bits;
    const sender_pid_bits = zap_proc_spawn(smokeSenderEntry, &probe);
    try testing.expect(sender_pid_bits != concurrency.Pid.invalid.toBits());

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.receiver_finished);
    try testing.expect(probe.sender_finished);
    try testing.expectEqual(receiver_pid_bits, probe.receiver_observed_self);
    try testing.expectEqual(sender_pid_bits, probe.sender_observed_self);
    try testing.expectEqual(RoundTripProbe.payload.len, probe.received_payload_len);
    try testing.expect(probe.received_payload_matches);

    // Exactness: every payload and closure ledger block was consumed.
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
    const stats = runtime_state.backend.production_pool.statistics();
    try testing.expectEqual(@as(i64, 0), stats.live_process_count);
    try testing.expectEqual(@as(u64, 2), stats.spawn_total);
    // Both exit normally: the receiver returned from its entry, and the sender
    // called `zap_proc_exit` — which since P5-J1 is a NORMAL self-exit (reason
    // `normal`), NOT the old Phase-2 kill-path exit. So `normal_exit_total` is 2
    // and no teardown is classified as a kill.
    try testing.expectEqual(@as(u64, 2), stats.normal_exit_total);
    try testing.expectEqual(@as(u64, 0), stats.kill_total);
    const envelope_stats = runtime_state.envelope_pool.statistics();
    try testing.expectEqual(@as(u32, 0), envelope_stats.live_page_count);
    try testing.expectEqual(@as(u32, 0), envelope_stats.abandoned_page_count);
}

// -- P4-J4: the seeded deterministic M:N backend drives the real intrinsics
//    reproducibly (the plan-4.4 Zap-layer payoff, validated end-to-end) --------

const seeded_producer_count = 3;
const seeded_messages_per_producer = 4;
const seeded_message_total = seeded_producer_count * seeded_messages_per_producer;

/// A fan-in probe recording the ARRIVAL ORDER of producer tags at the consumer
/// — the observable whose reproducibility proves the seeded backend replays an
/// exact M:N interleaving THROUGH THE ABI (not just inside the kernel harness).
const SeededReproProbe = struct {
    consumer_pid_bits: u64 = 0,
    arrival_order: [seeded_message_total]u8 = @splat(0),
    received: usize = 0,
    pairwise_fifo_violation: bool = false,
    per_producer_next: [seeded_producer_count]u8 = @splat(0),
};

const SeededProducerArg = struct {
    probe: *SeededReproProbe,
    index: u8,
};

fn seededProducerEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const arg: *SeededProducerArg = @ptrCast(@alignCast(argument.?));
    var sequence: u8 = 0;
    while (sequence < seeded_messages_per_producer) : (sequence += 1) {
        const payload = [2]u8{ arg.index, sequence }; // copied by the ABI (stack-safe)
        const status = zap_proc_send(process, arg.probe.consumer_pid_bits, &payload, payload.len);
        std.debug.assert(status == ZapProcStatus.ok);
        // Safepoint so seeded per-quantum budgets interleave sibling producers.
        zap_proc_yield_check(process);
    }
}

fn seededConsumerEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *SeededReproProbe = @ptrCast(@alignCast(argument.?));
    while (probe.received < seeded_message_total) {
        var payload_pointer: ?[*]const u8 = null;
        var payload_len: usize = 0;
        const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
        const bytes = payload_pointer.?[0..payload_len];
        const producer_index = bytes[0];
        const sequence = bytes[1];
        zap_proc_envelope_free(envelope);
        probe.arrival_order[probe.received] = producer_index;
        if (sequence != probe.per_producer_next[producer_index]) probe.pairwise_fifo_violation = true;
        probe.per_producer_next[producer_index] += 1;
        probe.received += 1;
    }
}

fn runSeededFanIn(seed: u64, probe: *SeededReproProbe, arguments: *[seeded_producer_count]SeededProducerArg) !void {
    try testing.expectEqual(ZapProcStatus.ok, runtimeInitSeededForTest(seed, 3));
    defer zap_proc_runtime_deinit();
    bindTestManager();

    const consumer_pid_bits = zap_proc_spawn(seededConsumerEntry, probe);
    try testing.expect(consumer_pid_bits != concurrency.Pid.invalid.toBits());
    probe.consumer_pid_bits = consumer_pid_bits;

    for (arguments, 0..) |*argument, producer_index| {
        argument.* = .{ .probe = probe, .index = @intCast(producer_index) };
        const producer_pid_bits = zap_proc_spawn(seededProducerEntry, argument);
        try testing.expect(producer_pid_bits != concurrency.Pid.invalid.toBits());
    }

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());
}

test "abi: the seeded deterministic M:N backend replays an identical interleaving through the C-ABI intrinsics" {
    // Two runs under the SAME seed must produce a byte-identical arrival
    // interleaving at the consumer — the plan-4.4 payoff proved end-to-end
    // through `zap_proc_runtime_init`(seeded) / `spawn` / `send` /
    // `receive_park` / `run_until_quiescent`, not just inside the kernel harness.
    var first_probe = SeededReproProbe{};
    var first_arguments: [seeded_producer_count]SeededProducerArg = undefined;
    try runSeededFanIn(0x5EED_D06, &first_probe, &first_arguments);
    try testing.expectEqual(@as(usize, seeded_message_total), first_probe.received);
    try testing.expect(!first_probe.pairwise_fifo_violation);
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());

    var second_probe = SeededReproProbe{};
    var second_arguments: [seeded_producer_count]SeededProducerArg = undefined;
    try runSeededFanIn(0x5EED_D06, &second_probe, &second_arguments);
    try testing.expectEqual(@as(usize, seeded_message_total), second_probe.received);
    try testing.expect(!second_probe.pairwise_fifo_violation);

    // Same seed ⇒ identical M:N arrival order through the ABI.
    try testing.expectEqualSlices(u8, &first_probe.arrival_order, &second_probe.arrival_order);
}

/// Probe for the ambient-handle and root-join intrinsics: the "root"
/// process records whether `zap_proc_current` matched its
/// entry-delivered handle, receives one message, and exits; a straggler
/// parks forever to prove the join returns before quiescence.
const AmbientJoinProbe = struct {
    root_pid_bits: u64 = 0,
    current_matched_entry_handle: bool = false,
    current_matched_after_park: bool = false,
    received_payload_len: usize = 0,
};

fn ambientRootEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *AmbientJoinProbe = @ptrCast(@alignCast(argument.?));
    probe.current_matched_entry_handle = zap_proc_current() == process;

    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    probe.received_payload_len = payload_len;
    zap_proc_envelope_free(envelope);
    // The park suspended and resumed the fiber: the ambient handle must
    // still resolve to this process's own context.
    probe.current_matched_after_park = zap_proc_current() == process;
}

fn ambientSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *AmbientJoinProbe = @ptrCast(@alignCast(argument.?));
    const send_status = zap_proc_send(process, probe.root_pid_bits, "join", 4);
    std.debug.assert(send_status == ZapProcStatus.ok);
}

fn parkForeverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    _ = argument;
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    _ = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    @panic("the straggler must never receive a message");
}

test "abi: zap_proc_current is null on the driver thread and matches the entry handle inside a process" {
    try testing.expectEqual(@as(?*anyopaque, null), zap_proc_current());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();
    try testing.expectEqual(@as(?*anyopaque, null), zap_proc_current());

    var probe = AmbientJoinProbe{};
    const root_pid_bits = zap_proc_spawn(ambientRootEntry, &probe);
    try testing.expect(root_pid_bits != concurrency.Pid.invalid.toBits());
    probe.root_pid_bits = root_pid_bits;
    const sender_pid_bits = zap_proc_spawn(ambientSenderEntry, &probe);
    try testing.expect(sender_pid_bits != concurrency.Pid.invalid.toBits());

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.current_matched_entry_handle);
    try testing.expect(probe.current_matched_after_park);
    try testing.expectEqual(@as(usize, 4), probe.received_payload_len);
    // Back on the driver thread between/after quanta: null again.
    try testing.expectEqual(@as(?*anyopaque, null), zap_proc_current());
}

test "abi: zap_proc_run_until_exit joins the target and leaves stragglers for deinit" {
    try testing.expectEqual(ZapProcStatus.not_initialized, zap_proc_run_until_exit(0));
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    // Deinit-then-assert is under test; the guard flag keeps failure paths
    // from leaking a live runtime into later tests (see the crash-teardown
    // test above for the rationale).
    var runtime_live = true;
    defer if (runtime_live) zap_proc_runtime_deinit();
    bindTestManager();

    const straggler_pid_bits = zap_proc_spawn(parkForeverEntry, null);
    try testing.expect(straggler_pid_bits != concurrency.Pid.invalid.toBits());

    var probe = AmbientJoinProbe{};
    const root_pid_bits = zap_proc_spawn(ambientRootEntry, &probe);
    try testing.expect(root_pid_bits != concurrency.Pid.invalid.toBits());
    probe.root_pid_bits = root_pid_bits;
    const sender_pid_bits = zap_proc_spawn(ambientSenderEntry, &probe);
    try testing.expect(sender_pid_bits != concurrency.Pid.invalid.toBits());

    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(root_pid_bits));

    // The root is gone; the parked straggler is still live (reaped at deinit).
    try testing.expectEqual(@as(usize, 4), probe.received_payload_len);
    try testing.expectEqual(@as(i64, 1), runtime_state.backend.production_pool.liveProcessCount());

    // Joining a dead pid returns immediately.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(root_pid_bits));

    // Program-shutdown semantics: deinit tears the straggler down.
    zap_proc_runtime_deinit();
    runtime_live = false;
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}

test "abi: observability — process listing, scheduler surfaces, and the trace-OFF read API (P6-J6)" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    // Deinit-then-assert is under test (the straggler reap + ledger check at
    // the end); the guard flag keeps any failed expectation above it from
    // leaking a live runtime into the ~19 later abi tests (the P6 round-2
    // `already_initialized` cascade).
    var runtime_live = true;
    defer if (runtime_live) zap_proc_runtime_deinit();
    bindTestManager();

    // Uninitialized-index and empty-capture behavior is total (no traps).
    try testing.expectEqual(@as(u64, 0), zap_introspect_pid(0));
    try testing.expectEqual(@as(i64, -1), zap_introspect_state(0));

    // Two parked stragglers to list, and a root whose exit stops the run.
    const first_pid_bits = zap_proc_spawn(parkForeverEntry, null);
    const second_pid_bits = zap_proc_spawn(parkForeverEntry, null);
    const root_pid_bits = zap_proc_spawn(immediateExitEntry, null);
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(root_pid_bits));

    // Process listing: exactly the two live stragglers, both named. Each is
    // `.waiting` (parked) or — if the root exited before a core gave it a
    // quantum — still `.runnable`; the listing is point-in-time, never a
    // stop-the-world (introspection.zig's consistency contract). Every
    // violation prints its observed state: a bare `expect` here once failed
    // "without output" in-suite, which made the flake undiagnosable.
    const captured = zap_introspect_capture();
    try testing.expectEqual(@as(u64, 2), captured);
    var found_first = false;
    var found_second = false;
    var index: u64 = 0;
    while (index < captured) : (index += 1) {
        const pid_bits = zap_introspect_pid(index);
        if (pid_bits == first_pid_bits) found_first = true;
        if (pid_bits == second_pid_bits) found_second = true;
        const state_code = zap_introspect_state(index);
        if (!(state_code == 1 or state_code == 3)) { // runnable | waiting
            std.debug.print(
                "captured process {d} (pid 0x{x}) in unexpected state code {d} (want runnable=1 or waiting=3)\n",
                .{ index, pid_bits, state_code },
            );
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(@as(u64, 0), zap_introspect_mailbox_depth(index));
    }
    if (!found_first or !found_second) {
        std.debug.print(
            "straggler listing mismatch: want pids 0x{x} and 0x{x}, captured 0x{x} and 0x{x}\n",
            .{ first_pid_bits, second_pid_bits, zap_introspect_pid(0), zap_introspect_pid(1) },
        );
        return error.TestUnexpectedResult;
    }
    // Past-the-count getters are total.
    try testing.expectEqual(@as(u64, 0), zap_introspect_pid(captured));
    try testing.expectEqual(@as(i64, -1), zap_introspect_state(captured));

    // Scheduler surfaces. The run has returned (workers joined), so every
    // utilization window is CLOSED and the busy/parked split is frozen and
    // exact: busy + parked == window, per core.
    const core_count = zap_sched_core_count();
    try testing.expect(core_count >= 1);
    var total_window_nanos: u64 = 0;
    var core_index: u64 = 0;
    while (core_index < core_count) : (core_index += 1) {
        const window = zap_sched_window_nanos(core_index);
        const parked = zap_sched_parked_nanos(core_index);
        const busy = zap_sched_busy_nanos(core_index);
        total_window_nanos += window;
        if (window != busy + parked) {
            std.debug.print(
                "core {d} utilization split broken: window={d} busy={d} parked={d}\n",
                .{ core_index, window, busy, parked },
            );
            return error.TestUnexpectedResult;
        }
    }
    // The root provably ran a quantum SOMEWHERE, so at least one core
    // measured a nonzero window. Deliberately NOT asserted per-core: under
    // work stealing a worker can steal and finish the whole run before the
    // driver's (core 0) loop observes its first `stopping` check, leaving
    // core 0 an episode shorter than one CLOCK_UPTIME_RAW tick (~42 ns on
    // Apple Silicon) that quantizes to a zero-span window — the pre-P7-J1
    // in-suite ReleaseFast flake, which asserted core 0 specifically.
    if (total_window_nanos == 0) {
        std.debug.print(
            "no core measured a utilization window (core_count={d})\n",
            .{core_count},
        );
        return error.TestUnexpectedResult;
    }
    try testing.expectEqual(@as(u64, 0), zap_sched_global_queue_depth());
    // Out-of-range core indexes are total.
    try testing.expectEqual(@as(u64, 0), zap_sched_run_queue_depth(core_count + 7));
    try testing.expectEqual(@as(u64, 0), zap_sched_window_nanos(core_count + 7));

    // The trace read surface in a trace-OFF kernel build (this test binary):
    // disabled, empty, and total — the Zap-level API never traps.
    try testing.expect(!zap_trace_enabled());
    try testing.expectEqual(@as(u64, 0), zap_trace_capture());
    try testing.expectEqual(@as(i64, 0), zap_trace_kind(0));
    try testing.expectEqual(@as(u64, 0), zap_trace_pid(0));
    try testing.expectEqual(@as(u64, 0), zap_trace_sequence(0));
    zap_trace_reset();

    // Deinit reaps the stragglers and releases the capture storage.
    zap_proc_runtime_deinit();
    runtime_live = false;
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}

fn deadLetterSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const status_out: *i32 = @ptrCast(@alignCast(argument.?));
    // A never-issued pid: slot 7, generation 1 was released by no one —
    // any stale/forged pid dead-letters through the table lookup.
    const forged = concurrency.Pid{
        .slot = 7,
        .generation = 999,
        .model = .refcounted,
        .node = 0,
    };
    status_out.* = zap_proc_send(process, forged.toBits(), "x", 1);
}

test "abi: send to a dead pid dead-letters and reclaims the payload block" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var observed_status: i32 = std.math.minInt(i32);
    const pid_bits = zap_proc_spawn(deadLetterSenderEntry, &observed_status);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expectEqual(ZapProcStatus.dead_lettered, observed_status);
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}

// ---------------------------------------------------------------------------
// Moved-envelope reclaim discipline (plan items 6.1/6.1a, P3-J5/P6-J1).
//
// The kernel is payload-agnostic — a moved fragment is an opaque root pointer
// plus the caller's `moved_reclaim` hook — so ONE invocation contract covers
// every moved shape (flat `List` and, since P6-J1, flat `Map`). These tests
// pin the contract's three legs at the kernel level with a counting hook:
//
//   * dead-letter  → the graph was never enqueued; the kernel must NOT invoke
//                    the reclaim (the CALLER re-owns the orphan — the runtime
//                    re-adopts and releases it);
//   * teardown-drain → a delivered-but-never-received moved envelope drained
//                    by the receiver's teardown must reclaim EXACTLY ONCE;
//   * delivered+adopted → `zap_proc_envelope_take_moved` transfers ownership
//                    and clears the fragment, so the following envelope free
//                    must NOT reclaim.
// ---------------------------------------------------------------------------

/// Counting stand-in for the runtime's `movedOrphanReclaim`: the kernel only
/// ever INVOKES the hook (never interprets the payload), so the invocation
/// count is the whole contract under test. The payload is a static buffer —
/// nothing to free.
var moved_reclaim_invocations: usize = 0;
var moved_payload_storage: [64]u8 = [_]u8{0xAB} ** 64;

fn countingMovedReclaim(payload_pointer: [*]const u8) callconv(.c) void {
    _ = payload_pointer;
    moved_reclaim_invocations += 1;
}

fn movedDeadLetterSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const status_out: *i32 = @ptrCast(@alignCast(argument.?));
    const forged = concurrency.Pid{
        .slot = 7,
        .generation = 999,
        .model = .refcounted,
        .node = 0,
    };
    status_out.* = zap_proc_send_moved(
        process,
        forged.toBits(),
        &moved_payload_storage,
        moved_payload_storage.len,
        countingMovedReclaim,
    );
}

test "abi: send_moved to a dead pid dead-letters WITHOUT invoking moved_reclaim (the caller re-owns the orphan)" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();
    moved_reclaim_invocations = 0;

    var observed_status: i32 = std.math.minInt(i32);
    const pid_bits = zap_proc_spawn(movedDeadLetterSenderEntry, &observed_status);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // Nothing was enqueued and nothing was consumed: the kernel must leave
    // the orphan to the caller (the runtime re-adopts + releases it), so the
    // reclaim hook fires ZERO times.
    try testing.expectEqual(ZapProcStatus.dead_lettered, observed_status);
    try testing.expectEqual(@as(usize, 0), moved_reclaim_invocations);
}

/// Probe threading the receive-once receiver's pid to the moved-payload
/// sender.
const MovedTeardownProbe = struct {
    receiver_pid_bits: u64 = 0,
    send_status: i32 = std.math.minInt(i32),
};

/// Receives exactly ONE message (the plain marker), then exits — leaving
/// whatever else is in its mailbox for the exit-teardown drain.
fn movedTeardownReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    _ = argument;
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    zap_proc_envelope_free(envelope);
}

fn movedTeardownSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *MovedTeardownProbe = @ptrCast(@alignCast(argument.?));
    // Pairwise FIFO: the plain marker is received first; the moved envelope
    // is still queued when the receiver exits after its single receive.
    _ = zap_proc_send(process, probe.receiver_pid_bits, "m", 1);
    probe.send_status = zap_proc_send_moved(
        process,
        probe.receiver_pid_bits,
        &moved_payload_storage,
        moved_payload_storage.len,
        countingMovedReclaim,
    );
}

test "abi: a moved envelope drained at receiver teardown runs moved_reclaim exactly once" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();
    moved_reclaim_invocations = 0;

    // The receiver receives ONE plain marker then exits, so the moved
    // envelope (sent after the marker — pairwise FIFO) is still in its
    // mailbox at exit: the receiver dies before adopting, and the teardown
    // drain (`reclaimUndeliveredEnvelope`) must run the moved reclaim
    // exactly once.
    var probe = MovedTeardownProbe{};
    const receiver_bits = zap_proc_spawn(movedTeardownReceiverEntry, null);
    try testing.expect(receiver_bits != concurrency.Pid.invalid.toBits());
    probe.receiver_pid_bits = receiver_bits;
    const sender_bits = zap_proc_spawn(movedTeardownSenderEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // Delivered, receiver exited without adopting → drained exactly once.
    try testing.expectEqual(ZapProcStatus.ok, probe.send_status);
    try testing.expectEqual(@as(usize, 1), moved_reclaim_invocations);
}

/// Probe for the delivered+adopted leg: the receiver records the moved root
/// it took ownership of.
const MovedAdoptProbe = struct {
    receiver_pid_bits: u64 = 0,
    send_status: i32 = std.math.minInt(i32),
    taken_root: ?[*]const u8 = null,
};

fn movedAdoptReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *MovedAdoptProbe = @ptrCast(@alignCast(argument.?));
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    // Take ownership of the moved graph (clears the fragment), then free the
    // envelope header — which must NOT invoke the reclaim.
    probe.taken_root = zap_proc_envelope_take_moved(envelope);
    zap_proc_envelope_free(envelope);
}

fn movedAdoptSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *MovedAdoptProbe = @ptrCast(@alignCast(argument.?));
    probe.send_status = zap_proc_send_moved(
        process,
        probe.receiver_pid_bits,
        &moved_payload_storage,
        moved_payload_storage.len,
        countingMovedReclaim,
    );
}

test "abi: a delivered moved envelope whose graph is TAKEN is never reclaimed by envelope_free" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();
    moved_reclaim_invocations = 0;

    var probe = MovedAdoptProbe{};
    const receiver_bits = zap_proc_spawn(movedAdoptReceiverEntry, &probe);
    try testing.expect(receiver_bits != concurrency.Pid.invalid.toBits());
    probe.receiver_pid_bits = receiver_bits;
    const sender_bits = zap_proc_spawn(movedAdoptSenderEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // Ownership transferred BY POINTER (zero copy — the exact root crossed),
    // and the ordinary envelope free ran with a cleared fragment: no reclaim.
    try testing.expectEqual(ZapProcStatus.ok, probe.send_status);
    try testing.expect(probe.taken_root != null);
    try testing.expectEqual(@intFromPtr(&moved_payload_storage), @intFromPtr(probe.taken_root.?));
    try testing.expectEqual(@as(usize, 0), moved_reclaim_invocations);
}

/// Probe for the cross-model stale-pid dead-letter test (P3-J4 §2.4): a sender
/// records the `zap_proc_send` status of a message aimed at a STALE pid whose
/// pid-table slot has been recycled by a DIFFERENT-model process.
const StaleCrossModelProbe = struct {
    stale_target_bits: u64 = 0,
    send_status: i32 = std.math.minInt(i32),
    finished: bool = false,
};

fn staleCrossModelSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *StaleCrossModelProbe = @ptrCast(@alignCast(argument.?));
    // Aim a payload at the stale ARC pid whose slot an Arena process recycled.
    // `zap_proc_send` → `context.send` → `pid_table.lookup`, which validates
    // {model, generation} as one atomic unit (generation first), so this must
    // dead-letter rather than deliver ARC-shaped bytes into the Arena process.
    probe.send_status = zap_proc_send(process, probe.stale_target_bits, "x", 1);
    probe.finished = true;
}

test "abi: send to a stale cross-model pid (slot recycled ARC→Arena) dead-letters (P3-J4 §2.4 invariant)" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();

    // Slot 0 = manifest bulk (Arena model, caps=0x0); slot 1 = refcounted
    // (ARC model, caps=0x1) — the real ARC+Arena two-manager binary shape.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_bind_manager(@ptrCast(&TestManagerCore.core)));
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_register_manager(1, @ptrCast(&test_refcounted_core)));

    // Batch 1: spawn an ARC (refcounted) process, capture its pid, and run it
    // to exit so its pid-table slot is released (generation bumped) — the
    // precondition for a same-slot recycle under a different model.
    var alloc_probe = PerProcessAllocProbe{ .byte_length = 8 };
    const arc_pid_bits = zap_proc_spawn_at(perProcessAllocatingEntry, &alloc_probe, 1);
    try testing.expect(arc_pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(pid_table.ReclamationModel.refcounted, concurrency.Pid.fromBits(arc_pid_bits).model);
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // Batch 2: spawn an Arena (bulk) process that RECYCLES the freed slot, and
    // a sender aimed at the STALE ARC pid. The Arena process reuses the slot
    // with a bumped generation and NEW (bulk_or_never) model bits.
    const arena_pid_bits = zap_proc_spawn_at(perProcessAllocatingEntry, &alloc_probe, 0);
    try testing.expect(arena_pid_bits != concurrency.Pid.invalid.toBits());
    const arc_pid = concurrency.Pid.fromBits(arc_pid_bits);
    const arena_pid = concurrency.Pid.fromBits(arena_pid_bits);
    // The Arena process recycled the ARC process's slot (same slot, bumped
    // generation, different model) — the exact stale-model-bit hazard §2.4
    // closes.
    try testing.expectEqual(arc_pid.slot, arena_pid.slot);
    try testing.expect(arc_pid.generation != arena_pid.generation);
    try testing.expectEqual(pid_table.ReclamationModel.bulk_or_never, arena_pid.model);

    var stale_probe = StaleCrossModelProbe{ .stale_target_bits = arc_pid_bits };
    const sender_bits = zap_proc_spawn(staleCrossModelSenderEntry, &stale_probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // The stale ARC pid resolved to a GENERATION mismatch — never to the live
    // Arena process on its recycled slot — so the send dead-lettered. A stale
    // sender can NEVER mis-emit an ARC-shaped layout into an arena heap: the
    // §2.4 cross-model pid invariant, proven end-to-end through the send path.
    try testing.expect(stale_probe.finished);
    try testing.expectEqual(ZapProcStatus.dead_lettered, stale_probe.send_status);
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}

fn oneShotReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    _ = argument;
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    zap_proc_envelope_free(envelope);
    // Exit after ONE receive: a second pending message stays in the
    // mailbox and is dead-lettered by teardown.
}

fn doubleSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const target_bits: *const u64 = @ptrCast(@alignCast(argument.?));
    std.debug.assert(zap_proc_send(process, target_bits.*, "first", 5) == ZapProcStatus.ok);
    std.debug.assert(zap_proc_send(process, target_bits.*, "second", 6) == ZapProcStatus.ok);
}

test "abi: payloads dead-lettered by receiver teardown are swept at deinit" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    bindTestManager();

    var receiver_pid_bits = zap_proc_spawn(oneShotReceiverEntry, null);
    try testing.expect(receiver_pid_bits != concurrency.Pid.invalid.toBits());
    const sender_pid_bits = zap_proc_spawn(doubleSenderEntry, &receiver_pid_bits);
    try testing.expect(sender_pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    // The second payload's envelope was drained by the kernel teardown;
    // its ledger block awaits the deinit sweep (module doc, payload seam).
    try testing.expectEqual(@as(usize, 1), payloadLedgerLiveBlockCount());
    zap_proc_runtime_deinit();
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}

// -- receive … after timeout + dead-letter (plan item 2.3, P2-J3) ---------------

/// Probe for the `zap_proc_receive_wait_timeout` integration tests.
const WaitTimeoutProbe = struct {
    timeout_nanoseconds: u64 = 0,
    wait_outcome: i32 = std.math.minInt(i32),
    finished: bool = false,
};

fn waitTimeoutNoSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *WaitTimeoutProbe = @ptrCast(@alignCast(argument.?));
    // No sender: the deadline elapses and the wait reports timed_out.
    probe.wait_outcome = zap_proc_receive_wait_timeout(process, probe.timeout_nanoseconds);
    probe.finished = true;
}

test "abi: zap_proc_receive_wait_timeout with an empty mailbox and after 0 polls without blocking" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = WaitTimeoutProbe{ .timeout_nanoseconds = 0 };
    const pid_bits = zap_proc_spawn(waitTimeoutNoSenderEntry, &probe);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.finished);
    // `after 0` polls without SUSPENDING the calling process — proven by the
    // immediate `.timed_out` outcome. (Under M:N the pool's OTHER idle cores do
    // park on their futexes, so a total park count is not a poll-vs-block
    // signal the way it was for the single Phase-2 scheduler.)
    try testing.expectEqual(ZapProcWaitOutcome.timed_out, probe.wait_outcome);
}

test "abi: zap_proc_receive_wait_timeout fires the deadline under the production futex park" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    // A small real-time deadline: the single scheduler idle-parks bounded
    // by it, wakes on timeout, and fires the waiter.
    var probe = WaitTimeoutProbe{ .timeout_nanoseconds = 2 * std.time.ns_per_ms };
    const pid_bits = zap_proc_spawn(waitTimeoutNoSenderEntry, &probe);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.finished);
    try testing.expectEqual(ZapProcWaitOutcome.timed_out, probe.wait_outcome);
}

/// Probe for the unexpected-message dead-letter path.
const DeadLetterProbe = struct {
    target_bits: u64 = 0,
    received: bool = false,
};

fn deadLetterReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *DeadLetterProbe = @ptrCast(@alignCast(argument.?));
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    zap_proc_envelope_free(envelope);
    probe.received = true;
    // The message matched no arm: dead-letter it (telemetry) and terminate
    // THIS process — the scheduler and any other process survive.
    zap_proc_dead_letter_unexpected(process);
}

fn deadLetterSenderToEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *DeadLetterProbe = @ptrCast(@alignCast(argument.?));
    std.debug.assert(zap_proc_send(process, probe.target_bits, "x", 1) == ZapProcStatus.ok);
}

test "abi: an unexpected message dead-letters with telemetry and does not crash the scheduler" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = DeadLetterProbe{};
    const receiver_bits = zap_proc_spawn(deadLetterReceiverEntry, &probe);
    try testing.expect(receiver_bits != concurrency.Pid.invalid.toBits());
    probe.target_bits = receiver_bits;
    const sender_bits = zap_proc_spawn(deadLetterSenderToEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());

    // The scheduler runs to quiescence — the dead-letter terminates only
    // the offending process, never the run loop.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.received);
    const stats = runtime_state.backend.production_pool.statistics();
    // Non-silent: exactly one unexpected-message dead letter recorded.
    try testing.expectEqual(@as(u64, 1), stats.unexpected_message_total);
    // Both processes are gone; the offending one via the kill path.
    try testing.expectEqual(@as(i64, 0), stats.live_process_count);
    try testing.expect(stats.kill_total >= 1);
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}

// ---------------------------------------------------------------------------
// Zap.Blob share tier — kernel-level lifecycle proofs (P6-J2).
//
// The Zap-visible behavior is covered by `test_concurrency/blob_test.zap`;
// these tests pin the KERNEL contract underneath it, in particular the two
// legs that need surgical process-lifecycle control:
//
//   * sender-dies-receiver-survives — THE point of the tier: the sender's
//     teardown drains its blob ledger (one atomic decrement), and the
//     receiver's adopted reference keeps the payload alive, byte-identical
//     and at the SAME address (zero copy);
//   * receiver-dies-with-queued-blob — the flight reference is released by
//     the teardown drain's `moved_reclaim` (`zap_blob_flight_release`),
//     leak-exactly.
// ---------------------------------------------------------------------------

/// Probe for the sender-dies-receiver-survives proof.
const BlobShareProbe = struct {
    receiver_pid_bits: u64 = 0,
    /// Identity token (payload address bits) the SENDER observed.
    sender_identity: u64 = 0,
    /// Identity token the RECEIVER observed after the sender died.
    receiver_identity: u64 = 0,
    /// Share count the receiver observed AFTER the sender's death (must be
    /// exactly 1 — the receiver is the sole remaining holder).
    receiver_observed_share_count: i64 = -99,
    /// Whether the receiver's post-death byte read matched the payload.
    receiver_bytes_match: bool = false,
    send_status: i32 = std.math.minInt(i32),
};

const blob_share_payload = "the sender is dead; long live the bytes";

fn blobShareSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *BlobShareProbe = @ptrCast(@alignCast(argument.?));

    // Hand the receiver our pid (so it can monitor our death) as a plain
    // copied message — pairwise FIFO puts it ahead of the blob envelope.
    var self_bits = zap_proc_self(process);
    _ = zap_proc_send(process, probe.receiver_pid_bits, @ptrCast(&self_bits), @sizeOf(u64));

    // Create the blob (share 1, ours) and record its payload identity.
    const handle_bits = zap_blob_create(process, blob_share_payload.ptr, blob_share_payload.len);
    std.debug.assert(handle_bits != 0);
    probe.sender_identity = zap_blob_identity(process, handle_bits);

    // Share it: flight-retain (+1) and send the pointer through a moved
    // envelope. No byte is copied anywhere on this path.
    var flight_byte_length: usize = 0;
    const flight = zap_blob_flight_retain(process, handle_bits, &flight_byte_length).?;
    std.debug.assert(flight_byte_length == blob_share_payload.len);
    probe.send_status = zap_proc_send_moved(
        process,
        probe.receiver_pid_bits,
        flight,
        flight_byte_length,
        zap_blob_flight_release,
    );

    // Die WITHOUT releasing: the teardown ledger drain performs our
    // release — the crash-safety leg (a process dying with blob handles
    // releases them).
}

fn blobShareReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *BlobShareProbe = @ptrCast(@alignCast(argument.?));

    // (1) The sender's pid.
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    var envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    std.debug.assert(payload_len == @sizeOf(u64));
    var sender_bits: u64 = undefined;
    @memcpy(std.mem.asBytes(&sender_bits), payload_pointer.?[0..@sizeOf(u64)]);
    zap_proc_envelope_free(envelope);

    // (2) The blob envelope: adopt the flight reference as our own.
    envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    const moved_root = zap_proc_envelope_take_moved(envelope).?;
    const handle_bits = zap_blob_adopt(process, moved_root);
    std.debug.assert(handle_bits != 0);
    zap_proc_envelope_free(envelope);

    // (3) Wait for the sender to be FULLY dead (its teardown drains its
    // blob ledger BEFORE exit signals propagate — scheduler.zig steps 4b
    // and 5b — so the DOWN observation orders our reads after its
    // release; a monitor on an already-dead pid fires `noproc`
    // immediately, covering both interleavings).
    _ = zap_proc_monitor(process, sender_bits);
    _ = zap_proc_await_signal(process);

    // (4) THE tier's point: the dead sender's payload is alive, byte-
    // identical, at the SAME address, and we are its sole holder.
    probe.receiver_identity = zap_blob_identity(process, handle_bits);
    probe.receiver_observed_share_count = zap_blob_share_count(process, handle_bits);
    var view_pointer: ?[*]const u8 = null;
    const view_length = zap_blob_bytes_view(process, handle_bits, &view_pointer);
    probe.receiver_bytes_match = view_length == blob_share_payload.len and
        std.mem.eql(u8, view_pointer.?[0..blob_share_payload.len], blob_share_payload);

    // Die without releasing: OUR teardown drain is the last release —
    // the "both die → freed, count 0" leg, asserted by the test body's
    // live count and the runtime deinit's leak gate.
}

test "abi: blob share — sender dies, receiver's blob survives at the same address; both die, freed leak-exactly" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = BlobShareProbe{};
    const receiver_bits = zap_proc_spawn(blobShareReceiverEntry, &probe);
    try testing.expect(receiver_bits != concurrency.Pid.invalid.toBits());
    probe.receiver_pid_bits = receiver_bits;
    const sender_bits = zap_proc_spawn(blobShareSenderEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expectEqual(ZapProcStatus.ok, probe.send_status);
    // Zero copy: the receiver read the SAME payload address the sender
    // created (pointer identity across the process boundary and across
    // the sender's death).
    try testing.expect(probe.sender_identity != 0);
    try testing.expectEqual(probe.sender_identity, probe.receiver_identity);
    // After the sender's death the receiver was the SOLE holder.
    try testing.expectEqual(@as(i64, 1), probe.receiver_observed_share_count);
    try testing.expect(probe.receiver_bytes_match);
    // Both holders are dead: the payload was freed by the receiver's
    // teardown ledger drain — leak-exact (the deferred runtime deinit
    // re-asserts this domain-wide).
    try testing.expectEqual(@as(u64, 0), zap_blob_live_count());
}

/// Probe for the receiver-dies-with-queued-blob proof.
const BlobTeardownProbe = struct {
    receiver_pid_bits: u64 = 0,
    send_status: i32 = std.math.minInt(i32),
    release_status: i32 = std.math.minInt(i32),
};

fn blobTeardownSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *BlobTeardownProbe = @ptrCast(@alignCast(argument.?));

    const handle_bits = zap_blob_create(process, "queued at death", 15);
    std.debug.assert(handle_bits != 0);

    // Pairwise FIFO: the plain marker is received first; the blob envelope
    // is still queued when the receiver exits after its single receive.
    _ = zap_proc_send(process, probe.receiver_pid_bits, "m", 1);
    var flight_byte_length: usize = 0;
    const flight = zap_blob_flight_retain(process, handle_bits, &flight_byte_length).?;
    probe.send_status = zap_proc_send_moved(
        process,
        probe.receiver_pid_bits,
        flight,
        flight_byte_length,
        zap_blob_flight_release,
    );

    // Release our own reference EXPLICITLY (the early-release path): the
    // flight reference is now the blob's only tether, held by the queued
    // envelope the receiver will never adopt.
    probe.release_status = zap_blob_release_owned(process, handle_bits);
}

test "abi: a blob envelope drained at receiver teardown releases the flight reference leak-exactly" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    // Reuses the moved-teardown receiver shape: ONE plain receive, then
    // exit with the blob envelope still queued.
    var probe = BlobTeardownProbe{};
    const receiver_bits = zap_proc_spawn(movedTeardownReceiverEntry, null);
    try testing.expect(receiver_bits != concurrency.Pid.invalid.toBits());
    probe.receiver_pid_bits = receiver_bits;
    const sender_bits = zap_proc_spawn(blobTeardownSenderEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expectEqual(ZapProcStatus.ok, probe.send_status);
    try testing.expectEqual(ZapProcStatus.ok, probe.release_status);
    // The teardown drain ran `zap_blob_flight_release` on the undelivered
    // envelope: nothing lives.
    try testing.expectEqual(@as(u64, 0), zap_blob_live_count());
}

/// Probe for the dead-letter undo proof.
const BlobDeadLetterProbe = struct {
    send_status: i32 = std.math.minInt(i32),
    share_count_after_undo: i64 = -99,
    release_status: i32 = std.math.minInt(i32),
};

fn blobDeadLetterSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *BlobDeadLetterProbe = @ptrCast(@alignCast(argument.?));

    const handle_bits = zap_blob_create(process, "undeliverable", 13);
    std.debug.assert(handle_bits != 0);

    const forged = concurrency.Pid{ .slot = 7, .generation = 999, .model = .refcounted, .node = 0 };
    var flight_byte_length: usize = 0;
    const flight = zap_blob_flight_retain(process, handle_bits, &flight_byte_length).?;
    probe.send_status = zap_proc_send_moved(
        process,
        forged.toBits(),
        flight,
        flight_byte_length,
        zap_blob_flight_release,
    );
    // Dead-letter: nothing was enqueued and nothing consumed the flight
    // reference — the sender undoes it (the runtime's send path does
    // exactly this on a non-ok status).
    zap_blob_flight_release(flight);
    probe.share_count_after_undo = zap_blob_share_count(process, handle_bits);
    probe.release_status = zap_blob_release_owned(process, handle_bits);
}

test "abi: a dead-lettered blob send undoes the flight reference — Erlang semantics, no leak" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = BlobDeadLetterProbe{};
    const sender_bits = zap_proc_spawn(blobDeadLetterSenderEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expectEqual(ZapProcStatus.dead_lettered, probe.send_status);
    try testing.expectEqual(@as(i64, 1), probe.share_count_after_undo);
    try testing.expectEqual(ZapProcStatus.ok, probe.release_status);
    try testing.expectEqual(@as(u64, 0), zap_blob_live_count());
}

/// Probes for the registry-survives-process-churn proof.
const BlobRegistryPutProbe = struct {
    put_status: i32 = std.math.minInt(i32),
};

const BlobRegistryGetProbe = struct {
    got_bytes_match: bool = false,
    missing_key_is_zero: bool = false,
};

const blob_registry_test_key: u64 = 0xC0FF33;

fn blobRegistryPublisherEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *BlobRegistryPutProbe = @ptrCast(@alignCast(argument.?));
    const handle_bits = zap_blob_create(process, "global config", 13);
    std.debug.assert(handle_bits != 0);
    probe.put_status = zap_blob_registry_put(process, blob_registry_test_key, handle_bits);
    // Die: the registry's own reference — NOT ours — keeps the value
    // alive across our death (persistent-term survives process churn).
}

fn blobRegistryConsumerEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *BlobRegistryGetProbe = @ptrCast(@alignCast(argument.?));
    probe.missing_key_is_zero = zap_blob_registry_get(process, 0xDEAD_BEEF) == 0;
    const handle_bits = zap_blob_registry_get(process, blob_registry_test_key);
    std.debug.assert(handle_bits != 0);
    var view_pointer: ?[*]const u8 = null;
    const view_length = zap_blob_bytes_view(process, handle_bits, &view_pointer);
    probe.got_bytes_match = view_length == 13 and
        std.mem.eql(u8, view_pointer.?[0..13], "global config");
    // Die without releasing the get-granted reference: the teardown drain
    // returns it, leaving the registry's own reference as the sole holder.
}

test "abi: the blob registry survives the publisher's death; get grants a teardown-drained reference; deinit sweeps leak-exactly" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    // The publisher runs to completion (and death) FIRST — the consumer is
    // spawned into a world where the publisher no longer exists.
    var put_probe = BlobRegistryPutProbe{};
    const publisher_bits = zap_proc_spawn(blobRegistryPublisherEntry, &put_probe);
    try testing.expect(publisher_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());
    try testing.expectEqual(ZapProcStatus.ok, put_probe.put_status);
    try testing.expectEqual(@as(u64, 1), zap_blob_live_count());

    var get_probe = BlobRegistryGetProbe{};
    const consumer_bits = zap_proc_spawn(blobRegistryConsumerEntry, &get_probe);
    try testing.expect(consumer_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());
    try testing.expect(get_probe.missing_key_is_zero);
    try testing.expect(get_probe.got_bytes_match);

    // The registry's reference is the one remaining holder; the deferred
    // runtime deinit releases it and asserts zero live blobs (the
    // shutdown leak-exactness gate).
    try testing.expectEqual(@as(u64, 1), zap_blob_live_count());
}

// ---------------------------------------------------------------------------
// Blob-backed String tier — kernel-level lifecycle proofs (P6-J3).
//
// The Zap-visible behavior is covered by
// `test_concurrency/string_blob_test.zap`; these tests pin the
// `zap_blob_string_*` ABI contract underneath it: promotion at the send
// boundary (create_flight), layout recognition + the ledger ownership gate
// (string_flight_retain / string_concat decline anything that is not the
// CALLING process's whole-blob view), the rc==1 in-place append vs the
// copy-on-shared re-promotion, and the sender-dies-receiver-survives +
// teardown leak-exactness legs.
// ---------------------------------------------------------------------------

/// Probe for the single-process string-tier semantics proof.
const StringTierSemanticsProbe = struct {
    promoted_payload_nonnull: bool = false,
    adopt_handle_nonzero: bool = false,
    whole_view_retains: bool = false,
    stale_frontier_declines: bool = false,
    append_status: i32 = std.math.minInt(i32),
    append_in_place: bool = false,
    appended_bytes_match: bool = false,
    shared_append_status: i32 = std.math.minInt(i32),
    shared_append_copied: bool = false,
    shared_base_frozen: bool = false,
    foreign_base_declines: bool = false,
    live_count_inside: u64 = 0,
};

fn stringTierSemanticsEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *StringTierSemanticsProbe = @ptrCast(@alignCast(argument.?));
    const original = "promoted string payload";

    // Promote (the send-boundary copy) and adopt the flight reference into
    // our own ledger — the exact pair a self-send performs.
    const payload = zap_blob_string_create_flight(original.ptr, original.len) orelse return;
    probe.promoted_payload_nonnull = true;
    probe.adopt_handle_nonzero = zap_blob_adopt(process, payload) != 0;

    // The whole-blob view retains (the zero-copy forward half)...
    if (zap_blob_string_flight_retain(process, payload, original.len)) |retained| {
        probe.whole_view_retains = retained == payload;
        zap_blob_flight_release(retained);
    }

    // rc==1 in-place append: same pointer out, frontier grows.
    var out_payload: ?[*]const u8 = null;
    probe.append_status = zap_blob_string_concat(
        process,
        payload,
        original.len,
        "!",
        1,
        &out_payload,
    );
    const grown_length = original.len + 1;
    probe.append_in_place = out_payload == payload;
    probe.appended_bytes_match =
        std.mem.eql(u8, payload[0..grown_length], "promoted string payload!");

    // ...after which the STALE frontier view no longer resolves (a shorter
    // alias never rides the share tier or clobbers the longer one).
    probe.stale_frontier_declines =
        zap_blob_string_flight_retain(process, payload, original.len) == null;

    // Shared → frozen: with a second (flight) reference outstanding, the
    // append must COPY into a fresh blob and leave the base untouched.
    const held = zap_blob_string_flight_retain(process, payload, grown_length).?;
    var shared_out: ?[*]const u8 = null;
    probe.shared_append_status = zap_blob_string_concat(
        process,
        payload,
        grown_length,
        "?",
        1,
        &shared_out,
    );
    probe.shared_append_copied = shared_out != null and shared_out != payload;
    probe.shared_base_frozen =
        std.mem.eql(u8, payload[0..grown_length], "promoted string payload!") and
        shared_out != null and
        std.mem.eql(u8, shared_out.?[0 .. grown_length + 1], "promoted string payload!?");
    zap_blob_flight_release(held);

    // A base that is not blob-backed declines — the runtime keeps its
    // ordinary string path. (Deterministic: even if the stack buffer lands
    // at the payload page offset by chance, no live slot's header can sit
    // on this stack page, so the address round-trip rejects it.)
    var foreign_buffer: [64]u8 = @splat('f');
    var foreign_out: ?[*]const u8 = null;
    probe.foreign_base_declines = zap_blob_string_concat(
        process,
        &foreign_buffer,
        foreign_buffer.len,
        "x",
        1,
        &foreign_out,
    ) == ZapProcStatus.string_not_blob_backed and foreign_out == null;

    // Two blobs live: the appended original + the shared-append copy, both
    // ledger-owned. Die WITHOUT releasing — the teardown drain frees both
    // (asserted by the test body and the runtime deinit's zero-live gate).
    probe.live_count_inside = zap_blob_live_count();
}

test "abi: string tier — promote/adopt, rc==1 in-place append, freeze-on-share copy, decline gates, teardown drain" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = StringTierSemanticsProbe{};
    const process_bits = zap_proc_spawn(stringTierSemanticsEntry, &probe);
    try testing.expect(process_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.promoted_payload_nonnull);
    try testing.expect(probe.adopt_handle_nonzero);
    try testing.expect(probe.whole_view_retains);
    try testing.expectEqual(ZapProcStatus.ok, probe.append_status);
    try testing.expect(probe.append_in_place);
    try testing.expect(probe.appended_bytes_match);
    try testing.expect(probe.stale_frontier_declines);
    try testing.expectEqual(ZapProcStatus.ok, probe.shared_append_status);
    try testing.expect(probe.shared_append_copied);
    try testing.expect(probe.shared_base_frozen);
    try testing.expect(probe.foreign_base_declines);
    try testing.expectEqual(@as(u64, 2), probe.live_count_inside);
    // The teardown ledger drain released both blobs.
    try testing.expectEqual(@as(u64, 0), zap_blob_live_count());
}

/// Probe for the promoted-string send / sender-dies proof.
const StringSendProbe = struct {
    receiver_pid_bits: u64 = 0,
    send_status: i32 = std.math.minInt(i32),
    /// Payload identity the SENDER observed at promotion.
    sender_identity: u64 = 0,
    /// The sender does NOT own the flight blob (promotion is flight-only):
    /// the ownership gate must decline its own probe of the payload.
    sender_probe_declined: bool = false,
    /// What the RECEIVER observed after the sender died.
    receiver_payload_len: usize = 0,
    receiver_identity: u64 = 0,
    receiver_bytes_match: bool = false,
    receiver_share_count: i64 = -99,
    receiver_append_in_place: bool = false,
    receiver_appended_bytes_match: bool = false,
};

const string_send_payload = "the string outlives its sender by riding the share tier";

fn stringSendSenderEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *StringSendProbe = @ptrCast(@alignCast(argument.?));

    // Hand the receiver our pid first (pairwise FIFO — it arrives ahead of
    // the string envelope) so it can monitor our death.
    var self_bits = zap_proc_self(process);
    _ = zap_proc_send(process, probe.receiver_pid_bits, @ptrCast(&self_bits), @sizeOf(u64));

    // Promote at the send boundary — the runtime's large-string send: one
    // copy into the blob domain, the single reference riding as flight.
    const payload = zap_blob_string_create_flight(
        string_send_payload.ptr,
        string_send_payload.len,
    ).?;
    probe.sender_identity = @intFromPtr(payload);

    // The ownership gate: this process holds NO ledger reference to the
    // flight blob, so probing it declines (flight references belong to the
    // envelope, never to a ledger).
    probe.sender_probe_declined =
        zap_blob_string_flight_retain(process, payload, string_send_payload.len) == null;

    probe.send_status = zap_proc_send_moved(
        process,
        probe.receiver_pid_bits,
        payload,
        string_send_payload.len, // the STRING length rides the envelope
        zap_blob_flight_release,
    );
    // Die immediately: nothing of the string tethers to this process.
}

fn stringSendReceiverEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *StringSendProbe = @ptrCast(@alignCast(argument.?));

    // (1) The sender's pid.
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    var envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    std.debug.assert(payload_len == @sizeOf(u64));
    var sender_bits: u64 = undefined;
    @memcpy(std.mem.asBytes(&sender_bits), payload_pointer.?[0..@sizeOf(u64)]);
    zap_proc_envelope_free(envelope);

    // (2) The string envelope: adopt the flight reference; the received
    // string is the payload view itself — zero bytes copied.
    envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    const moved_root = zap_proc_envelope_take_moved(envelope).?;
    std.debug.assert(zap_blob_adopt(process, moved_root) != 0);
    zap_proc_envelope_free(envelope);
    const received: []const u8 = moved_root[0..payload_len];

    // (3) Wait for the sender to be FULLY dead.
    _ = zap_proc_monitor(process, sender_bits);
    _ = zap_proc_await_signal(process);

    // (4) The dead sender's bytes: alive, byte-identical, SAME address.
    probe.receiver_payload_len = received.len;
    probe.receiver_identity = @intFromPtr(received.ptr);
    probe.receiver_bytes_match = std.mem.eql(u8, received, string_send_payload);

    // (5) Sole holder after the sender's death → the in-place append works
    // on the received string directly (the accumulate-received-chunks
    // pattern), pointer unchanged.
    const handle_bits = concurrency.BlobDomain.handleForPayloadPointer(received.ptr).toBits();
    probe.receiver_share_count = zap_blob_share_count(process, handle_bits);
    var out_payload: ?[*]const u8 = null;
    const append_status = zap_blob_string_concat(
        process,
        received.ptr,
        received.len,
        " -- appended by the receiver",
        28,
        &out_payload,
    );
    probe.receiver_append_in_place = append_status == ZapProcStatus.ok and
        out_payload == received.ptr;
    probe.receiver_appended_bytes_match = std.mem.eql(
        u8,
        received.ptr[0 .. received.len + 28],
        string_send_payload ++ " -- appended by the receiver",
    );
    // Die without releasing: the teardown drain is the last release.
}

test "abi: string tier — a promoted string send survives its sender at the same address; the receiver appends in place" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = StringSendProbe{};
    const receiver_bits = zap_proc_spawn(stringSendReceiverEntry, &probe);
    try testing.expect(receiver_bits != concurrency.Pid.invalid.toBits());
    probe.receiver_pid_bits = receiver_bits;
    const sender_bits = zap_proc_spawn(stringSendSenderEntry, &probe);
    try testing.expect(sender_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expectEqual(ZapProcStatus.ok, probe.send_status);
    try testing.expect(probe.sender_probe_declined);
    // Zero copy: the receiver's STRING is the sender's promoted payload —
    // pointer identity across the process boundary and the sender's death.
    try testing.expectEqual(string_send_payload.len, probe.receiver_payload_len);
    try testing.expect(probe.sender_identity != 0);
    try testing.expectEqual(probe.sender_identity, probe.receiver_identity);
    try testing.expect(probe.receiver_bytes_match);
    // After the sender's death the receiver was the SOLE holder, so the
    // append ran in place on the shared-tier buffer.
    try testing.expectEqual(@as(i64, 1), probe.receiver_share_count);
    try testing.expect(probe.receiver_append_in_place);
    try testing.expect(probe.receiver_appended_bytes_match);
    // Both processes are dead; the teardown drains freed the blob.
    try testing.expectEqual(@as(u64, 0), zap_blob_live_count());
}

// -- P6-J4: `ARSR`/`STAT` discovery, the receive-back-edge iteration reset,
// -- heap-bytes observability, and `hibernate` ---------------------------------

/// A test manager exposing the descriptor-only `ARSR` + `STAT` capabilities
/// over a single-buffer bump heap — the kernel-level double of the
/// first-party Arena manager's capability surface (the real Arena is
/// exercised end-to-end by the gate-ON Zap suite,
/// `test_concurrency/arena_server_test.zap`; the kernel tree is
/// self-contained and cannot import `src/memory/arena/manager.zig`).
const ArsrTestManager = struct {
    const buffer_capacity: usize = 256 * 1024;

    const Context = struct {
        buffer: [*]u8,
        cursor: usize,
        /// Mirrors `cursor` for the `STAT` read (atomic, like the real
        /// Arena's reserved-byte counter — introspection may read it
        /// cross-thread).
        used_bytes: std.atomic.Value(usize),
    };

    fn initThunk(options: ?*const anyopaque) callconv(.c) ?*anyopaque {
        _ = options;
        const context = backing_allocator.create(Context) catch return null;
        const buffer = backing_allocator.alloc(u8, buffer_capacity) catch {
            backing_allocator.destroy(context);
            return null;
        };
        context.* = .{ .buffer = buffer.ptr, .cursor = 0, .used_bytes = .init(0) };
        return @ptrCast(context);
    }

    fn deinitThunk(raw_context: *anyopaque) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        // Comptime-length slicing of a many-item pointer yields `*[N]u8`;
        // coerce to a runtime slice for `free`.
        const whole_buffer: []u8 = context.buffer[0..buffer_capacity];
        backing_allocator.free(whole_buffer);
        backing_allocator.destroy(context);
    }

    fn allocateThunk(raw_context: *anyopaque, byte_length: usize, alignment: u32) callconv(.c) ?[*]u8 {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        const base = @intFromPtr(context.buffer);
        const aligned = std.mem.alignForward(usize, base + context.cursor, alignment) - base;
        if (aligned + byte_length > buffer_capacity) return null;
        context.cursor = aligned + byte_length;
        context.used_bytes.store(context.cursor, .monotonic);
        return context.buffer + aligned;
    }

    fn deallocateThunk(raw_context: *anyopaque, memory: [*]u8, byte_length: usize, alignment: u32) callconv(.c) void {
        _ = raw_context;
        _ = memory;
        _ = byte_length;
        _ = alignment;
    }

    fn watermarkThunk(raw_context: *anyopaque, out_watermark: *ZapArenaWatermarkV1) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        out_watermark.* = .{
            .chunk = null,
            .bump_cursor = context.cursor,
            .chunk_end = 0,
            .next_chunk_size = 0,
        };
    }

    fn resetToWatermarkThunk(raw_context: *anyopaque, watermark: *const ZapArenaWatermarkV1) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        std.debug.assert(watermark.bump_cursor <= context.cursor);
        context.cursor = watermark.bump_cursor;
        context.used_bytes.store(context.cursor, .monotonic);
    }

    fn heapByteCountThunk(raw_context: *anyopaque) callconv(.c) usize {
        const context: *Context = @ptrCast(@alignCast(raw_context));
        return context.used_bytes.load(.monotonic);
    }

    const reset_capability = ZapArenaResetCapabilityV1{
        .watermark = watermarkThunk,
        .reset_to_watermark = resetToWatermarkThunk,
    };

    const reset_descriptor = ZapCapabilityDescV1{
        .id = ARSR_TAG,
        .version = 1,
        .size = @sizeOf(ZapArenaResetCapabilityV1),
        .flags = 0,
        .vtable = @ptrCast(&reset_capability),
    };

    const stats_capability = ZapStatsCapabilityV1{
        .heap_byte_count = heapByteCountThunk,
    };

    const stats_descriptor = ZapCapabilityDescV1{
        .id = STAT_TAG,
        .version = 1,
        .size = @sizeOf(ZapStatsCapabilityV1),
        .flags = 0,
        .vtable = @ptrCast(&stats_capability),
    };

    fn capabilityLookup(raw_context: *anyopaque, id: u32) callconv(.c) ?*const ZapCapabilityDescV1 {
        _ = raw_context;
        if (id == ARSR_TAG) return &reset_descriptor;
        if (id == STAT_TAG) return &stats_descriptor;
        return null;
    }

    const core = ZapMemoryManagerCoreV1{
        .abi_major = 1,
        .abi_minor = 0,
        .size = @sizeOf(ZapMemoryManagerCoreV1),
        .declared_caps = 0, // BULK_OR_NEVER, like the real Arena.
        .init = initThunk,
        .deinit = deinitThunk,
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .get_capability_desc = capabilityLookup,
    };
};

/// Probe for the iteration-reset semantics test: the entry samples its own
/// heap bytes around allocations and `zap_proc_receive_iteration_reset`
/// calls, exercising the watermark capture/reset protocol exactly as a
/// proven receive loop would.
const IterationResetProbe = struct {
    heap_after_spawn_era_alloc: usize = 0,
    heap_after_watermark_capture: usize = 0,
    heap_after_iteration_allocs: usize = 0,
    heap_after_first_reset: usize = 0,
    steady_state_held: bool = false,
    completed: bool = false,
};

fn iterationResetEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *IterationResetProbe = @ptrCast(@alignCast(argument.?));
    const manager = contextFromHandle(process).record.pcb.manager;

    // Spawn-era allocation: lives BELOW the watermark, never reclaimed by
    // iteration resets.
    _ = manager.allocate(1024, .of(u64)) orelse return;
    probe.heap_after_spawn_era_alloc = zap_proc_heap_byte_count(process);

    // The FIRST reset call captures the watermark and frees nothing.
    zap_proc_receive_iteration_reset(process);
    probe.heap_after_watermark_capture = zap_proc_heap_byte_count(process);

    // Iteration-era garbage.
    for (0..16) |_| _ = manager.allocate(512, .of(u64)) orelse return;
    probe.heap_after_iteration_allocs = zap_proc_heap_byte_count(process);

    // The SECOND call bulk-frees back to the watermark.
    zap_proc_receive_iteration_reset(process);
    probe.heap_after_first_reset = zap_proc_heap_byte_count(process);

    // Steady state across many iterations: allocate, reset, always back to
    // the watermark level — the bounded-server invariant in miniature.
    var held = true;
    for (0..32) |_| {
        for (0..16) |_| _ = manager.allocate(512, .of(u64)) orelse return;
        zap_proc_receive_iteration_reset(process);
        if (zap_proc_heap_byte_count(process) != probe.heap_after_first_reset) held = false;
    }
    probe.steady_state_held = held;
    probe.completed = true;
}

test "abi: iteration reset — ARSR watermark capture, bulk free, and steady state through the process binding" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_register_manager(1, @ptrCast(&ArsrTestManager.core)));

    var probe = IterationResetProbe{};
    const pid_bits = zap_proc_spawn_at(iterationResetEntry, &probe, 1);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    // BULK_OR_NEVER model bits, like the real Arena.
    try testing.expectEqual(pid_table.ReclamationModel.bulk_or_never, concurrency.Pid.fromBits(pid_bits).model);
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.completed);
    // STAT observability is live: spawn-era allocation is visible…
    try testing.expect(probe.heap_after_spawn_era_alloc >= 1024);
    // …the first reset call captured the watermark WITHOUT freeing…
    try testing.expectEqual(probe.heap_after_spawn_era_alloc, probe.heap_after_watermark_capture);
    // …iteration garbage grew the heap…
    try testing.expect(probe.heap_after_iteration_allocs > probe.heap_after_watermark_capture);
    // …and the reset bulk-freed EXACTLY back to the watermark.
    try testing.expectEqual(probe.heap_after_watermark_capture, probe.heap_after_first_reset);
    try testing.expect(probe.steady_state_held);
}

/// Probe for the no-`ARSR` conservative path: the same call shape under a
/// manager without the capability must no-op (never crash, never free).
const NoArsrResetProbe = struct {
    heap_byte_count_answer: usize = std.math.maxInt(usize),
    completed: bool = false,
};

fn noArsrResetEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *NoArsrResetProbe = @ptrCast(@alignCast(argument.?));
    const manager = contextFromHandle(process).record.pcb.manager;
    _ = manager.allocate(2048, .of(u64)) orelse return;
    zap_proc_receive_iteration_reset(process);
    _ = manager.allocate(2048, .of(u64)) orelse return;
    zap_proc_receive_iteration_reset(process);
    // No STAT capability → the heap-bytes query answers 0.
    probe.heap_byte_count_answer = zap_proc_heap_byte_count(process);
    probe.completed = true;
}

test "abi: iteration reset and heap-bytes are conservative no-ops under a manager without ARSR/STAT" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    TestManagerCore.resetAccounting();
    bindTestManager();

    var probe = NoArsrResetProbe{};
    const pid_bits = zap_proc_spawn(noArsrResetEntry, &probe);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());

    try testing.expect(probe.completed);
    try testing.expectEqual(@as(usize, 0), probe.heap_byte_count_answer);
    // The no-op reset freed nothing: both allocations were still live at
    // teardown and the wholesale free reclaimed them (exact accounting).
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total.load(.monotonic));
}

/// Deep stack excursion for the hibernate tests: `depth` frames, each
/// touching a 2 KiB buffer, checksummed so the compiler cannot elide the
/// stack traffic. Marked never-inline so every level is a real frame.
fn hibernateDeepTouch(depth: usize, seed: usize) usize {
    var frame_buffer: [2048]u8 = undefined;
    for (&frame_buffer, 0..) |*byte, index| byte.* = @truncate(seed +% index);
    var checksum: usize = 0;
    for (frame_buffer) |byte| checksum +%= byte;
    if (depth == 0) return checksum;
    return checksum +% @call(.never_inline, hibernateDeepTouch, .{ depth - 1, seed +% 1 });
}

/// Probe for the hibernate round trip. Phasing: `run_until_quiescent`
/// returns only at live-count ZERO, so a parked hibernator would hang it —
/// the parked phase is driven in ROOT mode instead (`zap_proc_run_until_exit`
/// on a marker process the hibernator handshakes with just before parking).
const HibernateProbe = struct {
    receiver_pid_bits: u64 = 0,
    marker_pid_bits: u64 = 0,
    first_deep_checksum: usize = 0,
    woke: std.atomic.Value(bool) = .init(false),
    payload_matches: bool = false,
    resumed_deep_matches: bool = false,
    completed: bool = false,

    const payload = "hibernate-wake";
    const handshake = "about-to-hibernate";
};

/// Phase marker: waits for the hibernator's "about to hibernate" handshake,
/// then yields the scheduler a bounded number of times so the hibernator's
/// park commits, then exits — ending the root-mode drive with the hibernator
/// PARKED but alive.
fn hibernateMarkerEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    _ = argument;
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    zap_proc_envelope_free(envelope);
    for (0..64) |_| zap_proc_yield_check(process);
}

fn hibernateWakerEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *HibernateProbe = @ptrCast(@alignCast(argument.?));
    std.debug.assert(zap_proc_send(
        process,
        probe.receiver_pid_bits,
        HibernateProbe.payload.ptr,
        HibernateProbe.payload.len,
    ) == ZapProcStatus.ok);
}

fn hibernateEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *HibernateProbe = @ptrCast(@alignCast(argument.?));

    // Commit a deep stack region (≈32 × 2 KiB ≈ 64 KiB touched; Debug frames
    // are fatter, still well inside the 256 KiB usable stack) BEFORE
    // hibernating — the committed pages the shrink must release.
    probe.first_deep_checksum = @call(.never_inline, hibernateDeepTouch, .{ 32, 7 });

    // Handshake: tell the phase marker the park is imminent.
    std.debug.assert(zap_proc_send(
        process,
        probe.marker_pid_bits,
        HibernateProbe.handshake.ptr,
        HibernateProbe.handshake.len,
    ) == ZapProcStatus.ok);

    zap_proc_hibernate(process);
    probe.woke.store(true, .release);

    // The message that woke us is queued, NOT consumed — consume it now.
    var payload_pointer: ?[*]const u8 = null;
    var payload_len: usize = 0;
    const envelope = zap_proc_receive_park(process, &payload_pointer, &payload_len);
    if (payload_pointer) |pointer| {
        probe.payload_matches = std.mem.eql(u8, pointer[0..payload_len], HibernateProbe.payload);
    }
    zap_proc_envelope_free(envelope);

    // Recommit-by-fault integrity: the same deep excursion after the shrink
    // must work and compute the same checksum.
    const second = @call(.never_inline, hibernateDeepTouch, .{ 32, 7 });
    probe.resumed_deep_matches = second == probe.first_deep_checksum;
    probe.completed = true;
}

test "abi: hibernate parks non-consuming, shrinks the committed stack, and wakes on the next message" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    defer zap_proc_runtime_deinit();
    bindTestManager();

    var probe = HibernateProbe{};
    const marker_bits = zap_proc_spawn(hibernateMarkerEntry, &probe);
    try testing.expect(marker_bits != concurrency.Pid.invalid.toBits());
    probe.marker_pid_bits = marker_bits;
    const pid_bits = zap_proc_spawn(hibernateEntry, &probe);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());

    // Phase 1 (root mode on the marker): the hibernator deep-touches,
    // handshakes, and PARKS; the marker's exit ends the drive with the
    // hibernator still alive and hibernated.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(marker_bits));
    try testing.expect(!probe.woke.load(.acquire));
    const stats_parked = runtime_state.backend.production_pool.statistics();
    try testing.expect(stats_parked.hibernate_park_total >= 1);
    // The deep excursion committed ≥64 KiB; the shrink released the pages
    // below the parked frame (at least half that, conservatively — the
    // parked frame chain sits near the stack top).
    try testing.expect(stats_parked.hibernate_stack_bytes_released >= 32 * 1024);

    // Phase 2: a user message wakes it (sent from a waker process — sends
    // are process-scoped intrinsics); hibernate returns WITHOUT consuming,
    // the following receive consumes, and the recommitted stack works.
    probe.receiver_pid_bits = pid_bits;
    const waker_bits = zap_proc_spawn(hibernateWakerEntry, &probe);
    try testing.expect(waker_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_quiescent());
    try testing.expect(probe.woke.load(.acquire));
    try testing.expect(probe.payload_matches);
    try testing.expect(probe.resumed_deep_matches);
    try testing.expect(probe.completed);
}

test "abi: a hibernated process is torn down cleanly at runtime deinit (no wake ever arrives)" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
    bindTestManager();

    var probe = HibernateProbe{};
    const marker_bits = zap_proc_spawn(hibernateMarkerEntry, &probe);
    try testing.expect(marker_bits != concurrency.Pid.invalid.toBits());
    probe.marker_pid_bits = marker_bits;
    const pid_bits = zap_proc_spawn(hibernateEntry, &probe);
    try testing.expect(pid_bits != concurrency.Pid.invalid.toBits());
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(marker_bits));
    try testing.expect(!probe.woke.load(.acquire));

    // Deinit with the process still hibernated: the parked-kill teardown
    // path reclaims it leak-exactly (the deinit-side ledgers assert).
    zap_proc_runtime_deinit();
    try testing.expect(!probe.completed);
}
