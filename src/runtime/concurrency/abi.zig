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
const concurrency = @import("concurrency.zig");

const process_module = @import("process.zig");
const envelope_pool_module = @import("envelope_pool.zig");
const mailbox_module = @import("mailbox.zig");
const pid_table = @import("pid_table.zig");

/// Backing allocator for every runtime-owned structure this bridge
/// creates (pid table, envelope-pool pages, scheduler records, payload
/// ledger blocks, spawn closures, bootstrap manager states). The page
/// allocator is the one std allocator with no libc dependency, which the
/// kernel object needs because `zap_fork_compile_zig_to_object` compiles
/// it with `link_libc = false` on targets that do not require libc
/// (`~/projects/zig/src/zir_api.zig`, `compileToObjectImpl`). Page
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

    fn allocate(ledger: *Ledger, body_byte_length: usize) error{OutOfMemory}!*LedgerBlock {
        const raw = backing_allocator.alignedAlloc(
            u8,
            .of(LedgerBlock),
            @sizeOf(LedgerBlock) + body_byte_length,
        ) catch return error.OutOfMemory;
        const block: *LedgerBlock = @ptrCast(@alignCast(raw.ptr));
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
        if (block.previous) |previous| {
            previous.next = block.next;
        } else {
            ledger.head = block.next;
        }
        if (block.next) |next| next.previous = block.previous;
        std.debug.assert(ledger.live_block_count > 0);
        ledger.live_block_count -= 1;
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
/// pointers rather than the Phase-2 opaque placeholders. `get_capability_desc`
/// stays opaque because the kernel never invokes it (the runtime discovers
/// the refcount capability). Redeclared per the self-contained-manager
/// convention (spec §11.1.1); the `comptime` layout asserts below catch
/// drift from the canonical definition. A newer-minor manager advertises a
/// larger `size` and appends trailing fields (spec §2.3); the kernel reads
/// only this v1.0 prefix, so it stays forward-compatible.
const ZapMemoryManagerCoreV1 = extern struct {
    abi_major: u16,
    abi_minor: u16,
    size: u32,
    declared_caps: u64,
    init: *const fn (options: ?*const anyopaque) callconv(.c) ?*anyopaque,
    deinit: *const fn (context: *anyopaque) callconv(.c) void,
    allocate: *const fn (context: *anyopaque, byte_length: usize, alignment: u32) callconv(.c) ?[*]u8,
    deallocate: *const fn (context: *anyopaque, memory: [*]u8, byte_length: usize, alignment: u32) callconv(.c) void,
    get_capability_desc: *const anyopaque,
};

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
/// The layout is FROZEN and mirrored on the runtime side (`src/runtime.zig`,
/// `ProcessManagerBinding`): `core` first, `context` second, both non-optional
/// (a bound process always has both). `extern struct` pins the field order.
const ProcessManagerBinding = extern struct {
    core: *const ZapMemoryManagerCoreV1,
    context: *anyopaque,
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
    binding.* = .{ .core = core, .context = context };
    return .{ .manager_state = binding, .vtable = &process_manager_vtable };
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

/// Advisory only (plan item 1.6): the v1.0 core ABI exposes no per-context
/// live-byte query, so report 0. Per-process byte accounting is a manager
/// capability follow-on; teardown returns the whole heap regardless.
fn processHeapByteCountThunk(manager_state: ?*anyopaque) usize {
    _ = manager_state;
    return 0;
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
    scheduler: concurrency.Scheduler,
    ledger: Ledger,
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
    runtime_state.scheduler = concurrency.Scheduler.init(
        backing_allocator,
        &runtime_state.pid_table,
        &runtime_state.envelope_pool,
        .{},
    );
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
    runtime_state.scheduler.shutdownAllProcesses();
    runtime_state.scheduler.deinit();
    runtime_state.envelope_pool.deinit();
    runtime_state.pid_table.deinit();
    runtime_state.ledger.sweep();
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
    runtime_state.scheduler.runUntilQuiescent() catch |err| switch (err) {
        // Unreachable under the production idle strategy (the Phase 2
        // runtime always parks); surfaced defensively for completeness.
        error.AllProcessesWaiting => return ZapProcStatus.not_initialized,
    };
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
    runtime_state.scheduler.runUntilProcessExits(target) catch |err| switch (err) {
        // Unreachable under the production idle strategy (the Phase 2
        // runtime always parks); surfaced defensively for completeness.
        error.AllProcessesWaiting => return ZapProcStatus.not_initialized,
    };
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
    return @ptrCast(runtime_state.scheduler.currentProcessContext());
}

// ---------------------------------------------------------------------------
// Intrinsics — spawn (driver thread or process body; same OS thread)
// ---------------------------------------------------------------------------

/// Spawn a process under the MANIFEST default manager (registry slot 0) — the
/// no-option `Process.spawn(f)` path. Equivalent to `zap_proc_spawn_at(entry,
/// argument, 0)`; kept as the ABI-stable convenience the Phase-2 surface and
/// the root-process bootstrap already call.
export fn zap_proc_spawn(entry: ZapProcEntry, argument: ?*anyopaque) callconv(.c) u64 {
    return zap_proc_spawn_at(entry, argument, 0);
}

/// Spawn a process running `entry(process_handle, argument)` under the manager
/// in registry slot `manager_index` (plan item 3.1/3.3, P3-J3 — the
/// `spawn(f, .{ .manager = X })` surface). The spawn mints a FRESH private
/// per-process context from that manager's core vtable (wholesale-freed at the
/// process's teardown) and stamps the pid's model bits from the manager's
/// `declared_caps` (`reclamationModelForCaps`) so a sender reads the target's
/// reclamation model together with its generation (§2.4 invariant). The
/// returned `u64` is the new pid's raw encoding; `0` (the invalid pid — never
/// issued) signals failure: runtime not initialized, `manager_index` out of
/// range or unregistered (no manager selected — the no-fallbacks spawn gate),
/// manager `init` failure, allocation failure, or process-table exhaustion.
export fn zap_proc_spawn_at(entry: ZapProcEntry, argument: ?*anyopaque, manager_index: u32) callconv(.c) u64 {
    if (!runtime_initialized) return concurrency.Pid.invalid.toBits();
    if (manager_index >= MAX_MANAGER_SLOTS) return concurrency.Pid.invalid.toBits();
    // No fallback bootstrap arena (the no-fallbacks rule): a process cannot
    // spawn until the selected registry slot has a manager registered.
    const core = runtime_state.manager_registry[manager_index] orelse
        return concurrency.Pid.invalid.toBits();

    // Per-process instance (plan item 3.1): mint a FRESH private manager
    // context (a private heap) for this process from the SELECTED manager's
    // core `init`. On any downstream spawn failure it is wholesale-freed via
    // `manager_context.teardown()` so the private heap never leaks.
    const manager_context = createProcessBinding(core) orelse
        return concurrency.Pid.invalid.toBits();

    // Pid model bits (plan §2.4, J3): the reclamation model of the process's
    // OWN manager, decoded from its declared capabilities.
    const model = reclamationModelForCaps(core.declared_caps);

    const closure_block = runtime_state.ledger.allocate(@sizeOf(SpawnClosure)) catch {
        manager_context.teardown();
        return concurrency.Pid.invalid.toBits();
    };
    const closure: *SpawnClosure = @ptrCast(@alignCast(closure_block.bodyPointer()));
    closure.* = .{ .c_entry = entry, .c_argument = argument };

    const pid = runtime_state.scheduler.spawn(.{
        .entry = spawnTrampoline,
        .argument = closure_block,
        // The process runs on its OWN private context; the per-process vtable's
        // teardown wholesale-frees it at exit (`ProcessManagerBinding`).
        .manager = manager_context,
        .model = model,
    }) catch {
        runtime_state.ledger.free(closure_block);
        manager_context.teardown();
        return concurrency.Pid.invalid.toBits();
    };
    return pid.toBits();
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

/// Park the calling process until its mailbox is nonempty, then return
/// the oldest deliverable envelope as an opaque reference, with the
/// payload view written through the out-parameters (`null`/`0` for
/// payload-less messages). The payload view BORROWS from the envelope:
/// it is valid until `zap_proc_envelope_free`, which the caller MUST
/// eventually invoke on the returned reference. If the process is
/// killed while parked, the call never returns.
export fn zap_proc_receive_park(
    process: *anyopaque,
    out_payload_pointer: *?[*]const u8,
    out_payload_len: *usize,
) callconv(.c) *anyopaque {
    const context = contextFromHandle(process);
    const envelope = context.receive();
    out_payload_pointer.* = envelope.fragment.payload_pointer;
    out_payload_len.* = envelope.fragment.payload_byte_length;
    return @ptrCast(envelope);
}

/// Release an envelope returned by `zap_proc_receive_park`: frees the
/// payload ledger block (when present) and returns the envelope header
/// to the shared pool. Exactly-once per received envelope.
export fn zap_proc_envelope_free(envelope_handle: *anyopaque) callconv(.c) void {
    const envelope: *mailbox_module.Envelope = @ptrCast(@alignCast(envelope_handle));
    if (envelope.fragment.payload_pointer) |payload| {
        // P2-J1 transport invariant: a non-null payload with a null
        // origin page is a ledger block (module doc). P2-J5's pool-carved
        // fragments set `payload_origin_page` and take the other branch.
        std.debug.assert(envelope.fragment.payload_origin_page == null);
        runtime_state.ledger.free(LedgerBlock.fromBodyPointer(payload));
        envelope.fragment = .{};
    }
    envelope_pool_module.free(envelope);
}

/// Terminate the calling process at this point: teardown through the
/// kernel's kill path (see the module doc's exit-semantics seam). Never
/// returns.
export fn zap_proc_exit(process: *anyopaque) callconv(.c) noreturn {
    const context = contextFromHandle(process);
    // Self-kill: mark, then yield at a safepoint. The scheduler observes
    // `pending_kill` when the quantum ends and tears the process down
    // instead of resuming it — the yield cannot return.
    _ = context.kill(context.selfPid());
    context.yieldNow();
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
    const context = runtime_state.scheduler.currentProcessContext() orelse return;
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

/// Park the calling process until a message is at its mailbox head or
/// `timeout_nanoseconds` elapses — the `receive … after` timeout
/// mechanism (plan item 2.3, P2-J3). Returns
/// `ZapProcWaitOutcome.message_available` (a following
/// `zap_proc_receive_park` then pops it WITHOUT blocking) or `.timed_out`.
/// `timeout_nanoseconds == 0` polls once WITHOUT parking (`after 0`). The
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

    // Factory-wide accounting across every context this double mints.
    var init_total: usize = 0;
    var deinit_total: usize = 0;
    var live_context_count: usize = 0;
    var live_bytes_total: usize = 0;

    /// Zero the factory accounting at the start of a per-instance test so its
    /// assertions start from a known baseline.
    fn resetAccounting() void {
        init_total = 0;
        deinit_total = 0;
        live_context_count = 0;
        live_bytes_total = 0;
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
        .get_capability_desc = @ptrCast(&unusedThunk),
    };

    fn unusedThunk() callconv(.c) void {}

    fn initThunk(options: ?*const anyopaque) callconv(.c) ?*anyopaque {
        _ = options;
        const context = backing_allocator.create(Context) catch return null;
        context.* = .{ .arena = std.heap.ArenaAllocator.init(backing_allocator), .live_bytes = 0 };
        init_total += 1;
        live_context_count += 1;
        return @ptrCast(context);
    }

    fn deinitThunk(context_pointer: *anyopaque) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(context_pointer));
        // Wholesale free: the arena releases every still-live allocation in
        // one call — the leak-exact per-process teardown this double proves.
        std.debug.assert(live_bytes_total >= context.live_bytes);
        live_bytes_total -= context.live_bytes;
        context.arena.deinit();
        backing_allocator.destroy(context);
        deinit_total += 1;
        std.debug.assert(live_context_count > 0);
        live_context_count -= 1;
    }

    fn allocateThunk(context_pointer: *anyopaque, byte_length: usize, alignment: u32) callconv(.c) ?[*]u8 {
        const context: *Context = @ptrCast(@alignCast(context_pointer));
        const memory = context.arena.allocator().rawAlloc(
            byte_length,
            std.mem.Alignment.fromByteUnits(alignment),
            @returnAddress(),
        ) orelse return null;
        context.live_bytes += byte_length;
        live_bytes_total += byte_length;
        return memory;
    }

    fn deallocateThunk(context_pointer: *anyopaque, memory: [*]u8, byte_length: usize, alignment: u32) callconv(.c) void {
        const context: *Context = @ptrCast(@alignCast(context_pointer));
        context.arena.allocator().rawFree(memory[0..byte_length], std.mem.Alignment.fromByteUnits(alignment), @returnAddress());
        std.debug.assert(context.live_bytes >= byte_length);
        context.live_bytes -= byte_length;
        std.debug.assert(live_bytes_total >= byte_length);
        live_bytes_total -= byte_length;
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
    try testing.expectEqual(@as(usize, 2), TestManagerCore.init_total);
    try testing.expectEqual(@as(usize, 2), TestManagerCore.live_context_count);

    // Allocate into the first context and DELIBERATELY do not free it — the
    // killed-process shape whose live cells must be reclaimed wholesale.
    const block = first.allocate(48, .of(u64)) orelse return error.TestUnexpectedResult;
    block[0] = 0x5A;
    block[47] = 0xA5;
    try testing.expectEqual(@as(usize, 48), TestManagerCore.live_bytes_total);

    // heapByteCount is advisory 0 (no per-context query on the v1.0 core).
    try testing.expectEqual(@as(usize, 0), first.heapByteCount());

    // teardown is a REAL wholesale free (Phase 3): it reclaims the still-live
    // block and destroys the private context — no per-cell free needed.
    first.teardown();
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total);
    try testing.expectEqual(@as(usize, 1), TestManagerCore.deinit_total);
    try testing.expectEqual(@as(usize, 1), TestManagerCore.live_context_count);

    // The second context is independent — untouched by the first's teardown.
    second.teardown();
    try testing.expectEqual(@as(usize, 2), TestManagerCore.deinit_total);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count);
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
        .get_capability_desc = @ptrCast(&TestManagerCore.unusedThunk),
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
    .get_capability_desc = @ptrCast(&TestManagerCore.unusedThunk),
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
        .get_capability_desc = @ptrCast(&TestManagerCore.unusedThunk),
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
    try testing.expectEqual(@as(usize, 2), probe.processes_run);
    try testing.expectEqual(@as(usize, 2), TestManagerCore.init_total);
    try testing.expectEqual(@as(usize, 2), TestManagerCore.deinit_total);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total);
}

// -- per-process private instances (plan item 3.1, P3-J1) -----------------------

/// Probe for the per-process-instance tests: each process body allocates
/// `byte_length` bytes into ITS OWN private manager context and deliberately
/// never frees it — the still-live-at-death shape the wholesale teardown must
/// reclaim. `processes_run` counts bodies that reached the allocation.
const PerProcessAllocProbe = struct {
    byte_length: usize,
    processes_run: usize = 0,
};

/// Allocate into this process's own private heap (through the PCB manager
/// context reached from the entry handle), then return — the normal-exit
/// path whose teardown wholesale-frees the never-freed block.
fn perProcessAllocatingEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *PerProcessAllocProbe = @ptrCast(@alignCast(argument.?));
    const context = contextFromHandle(process);
    const block = context.record.pcb.manager.allocate(probe.byte_length, .of(u64)) orelse return;
    block[0] = 0x11;
    probe.processes_run += 1;
}

/// Allocate into this process's own private heap, then park forever — the
/// killed-with-live-allocations shape torn down by `shutdownAllProcesses`.
fn allocateThenParkEntry(process: *anyopaque, argument: ?*anyopaque) callconv(.c) void {
    const probe: *PerProcessAllocProbe = @ptrCast(@alignCast(argument.?));
    const context = contextFromHandle(process);
    const block = context.record.pcb.manager.allocate(probe.byte_length, .of(u64)) orelse return;
    block[0] = 0x22;
    probe.processes_run += 1;
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
    try testing.expectEqual(process_count, probe.processes_run);
    try testing.expectEqual(process_count, TestManagerCore.init_total);
    // Every process's context was wholesale-freed at its teardown, reclaiming
    // the never-freed 64-byte block — leak-exact, zero residue.
    try testing.expectEqual(process_count, TestManagerCore.deinit_total);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total);
}

test "abi: a killed process's live allocations are wholesale-freed at teardown (crash-teardown leak-exactness)" {
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_runtime_init());
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
    try testing.expectEqual(@as(usize, 1), probe.processes_run);
    try testing.expect(TestManagerCore.live_bytes_total >= 128);
    try testing.expect(TestManagerCore.live_context_count >= 1);

    // Program shutdown kills the straggler; its teardown wholesale-frees the
    // live allocation — every minted context deinit'd, zero residue.
    zap_proc_runtime_deinit();
    try testing.expectEqual(TestManagerCore.init_total, TestManagerCore.deinit_total);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count);
    try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total);
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
        try testing.expectEqual(spawned_total, TestManagerCore.init_total);
        try testing.expectEqual(spawned_total, TestManagerCore.deinit_total);
        try testing.expectEqual(@as(usize, 0), TestManagerCore.live_context_count);
        try testing.expectEqual(@as(usize, 0), TestManagerCore.live_bytes_total);
    }
    try testing.expectEqual(spawned_total, probe.processes_run);
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
    const stats = runtime_state.scheduler.statistics();
    try testing.expectEqual(@as(u32, 0), stats.live_process_count);
    try testing.expectEqual(@as(u64, 2), stats.spawn_total);
    // Receiver returned (normal); sender used the exit intrinsic (the
    // Phase 2 kill-path exit — module doc).
    try testing.expectEqual(@as(u64, 1), stats.normal_exit_total);
    try testing.expectEqual(@as(u64, 1), stats.kill_total);
    const envelope_stats = runtime_state.envelope_pool.statistics();
    try testing.expectEqual(@as(u32, 0), envelope_stats.live_page_count);
    try testing.expectEqual(@as(u32, 0), envelope_stats.abandoned_page_count);
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

    // The root is gone; the parked straggler is still live.
    try testing.expectEqual(@as(usize, 4), probe.received_payload_len);
    try testing.expectEqual(@as(u32, 1), runtime_state.scheduler.statistics().live_process_count);

    // Joining a dead pid returns immediately.
    try testing.expectEqual(ZapProcStatus.ok, zap_proc_run_until_exit(root_pid_bits));

    // Program-shutdown semantics: deinit tears the straggler down.
    zap_proc_runtime_deinit();
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
    try testing.expectEqual(ZapProcWaitOutcome.timed_out, probe.wait_outcome);
    // A poll never parks the scheduler thread.
    try testing.expectEqual(@as(u64, 0), runtime_state.scheduler.statistics().park_count);
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
    const stats = runtime_state.scheduler.statistics();
    // Non-silent: exactly one unexpected-message dead letter recorded.
    try testing.expectEqual(@as(u64, 1), stats.unexpected_message_total);
    // Both processes are gone; the offending one via the kill path.
    try testing.expectEqual(@as(u32, 0), stats.live_process_count);
    try testing.expect(stats.kill_total >= 1);
    try testing.expectEqual(@as(usize, 0), payloadLedgerLiveBlockCount());
}
