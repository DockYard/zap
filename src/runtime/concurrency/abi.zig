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
            .{ .core_count = core_count, .signal_runtime = &runtime_state.signal_runtime },
        ) catch {
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
            .{ .core_options = .{ .signal_runtime = &runtime_state.signal_runtime } },
        ) catch {
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
    const simulator = concurrency.MnSimulator.create(
        backing_allocator,
        &runtime_state.pid_table,
        &runtime_state.envelope_pool,
        seed,
        .{ .core_count = core_count, .signal_runtime = &runtime_state.signal_runtime },
    ) catch {
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
    // core's per-scheduler resources on its own thread.
    const spawn_core = concurrency.Scheduler.currentThreadScheduler() orelse runtime_state.backend.primaryCore();
    const pid = spawn_core.spawn(.{
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

/// Blocking receive of the next SIGNAL message (raw J1 surface): pops the
/// mailbox head (which MUST be an exit/`DOWN` signal), caches its fields, frees
/// it, and returns the reason term. `zap_proc_last_signal_*` read the other
/// fields. Aborts if the head is an ordinary user message.
export fn zap_proc_await_signal(process: *anyopaque) callconv(.c) u64 {
    return contextFromHandle(process).awaitSignal();
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
        .get_capability_desc = @ptrCast(&unusedThunk),
    };

    fn unusedThunk() callconv(.c) void {}

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
