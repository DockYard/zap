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
//! ## Process-heap manager seam (plan item 2.4)
//!
//! Spawned processes bind a bootstrap arena manager (wholesale free on
//! exit — the plan item 1.4 shape). Binding the real manifest (ARC)
//! manager ABI for receiver-side adoption REPLACES this binding in plan
//! item 2.4, per the no-fallbacks rule; `process.zig`'s "Manager
//! binding" module doc carries the same citation.
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
// Bootstrap process-heap manager (plan item 2.4 seam — see module doc)
// ---------------------------------------------------------------------------

/// Per-process bootstrap manager state: an arena over the backing
/// allocator with byte accounting for the plan-1.6 heap-bytes
/// observability surface. One state block per live process, allocated at
/// spawn and destroyed by its own vtable `teardown` (the kernel
/// guarantees exactly one teardown per spawned record on EVERY exit
/// path, including kill-before-first-quantum).
const BootstrapManagerState = struct {
    arena: std.heap.ArenaAllocator,
    live_heap_bytes: usize,

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn create() error{OutOfMemory}!*BootstrapManagerState {
        const state = backing_allocator.create(BootstrapManagerState) catch return error.OutOfMemory;
        state.* = .{
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
            .live_heap_bytes = 0,
        };
        return state;
    }

    fn managerContext(state: *BootstrapManagerState) process_module.ManagerContext {
        return .{ .manager_state = state, .vtable = &vtable };
    }

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const state: *BootstrapManagerState = @ptrCast(@alignCast(manager_state.?));
        const memory = state.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        state.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const state: *BootstrapManagerState = @ptrCast(@alignCast(manager_state.?));
        state.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        state.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const state: *BootstrapManagerState = @ptrCast(@alignCast(manager_state.?));
        state.arena.deinit();
        backing_allocator.destroy(state);
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const state: *BootstrapManagerState = @ptrCast(@alignCast(manager_state.?));
        return state.live_heap_bytes;
    }
};

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

/// Spawn a process running `entry(process_handle, argument)` under the
/// manifest manager binding (Phase 2 scope: manifest manager only — the
/// bootstrap arena manager until plan item 2.4 binds the real manager
/// ABI). The returned `u64` is the new pid's raw encoding; `0` (the
/// invalid pid — never issued) signals failure (runtime not initialized,
/// allocation failure, or process-table exhaustion).
export fn zap_proc_spawn(entry: ZapProcEntry, argument: ?*anyopaque) callconv(.c) u64 {
    if (!runtime_initialized) return concurrency.Pid.invalid.toBits();

    const closure_block = runtime_state.ledger.allocate(@sizeOf(SpawnClosure)) catch
        return concurrency.Pid.invalid.toBits();
    const closure: *SpawnClosure = @ptrCast(@alignCast(closure_block.bodyPointer()));
    closure.* = .{ .c_entry = entry, .c_argument = argument };

    const manager_state = BootstrapManagerState.create() catch {
        runtime_state.ledger.free(closure_block);
        return concurrency.Pid.invalid.toBits();
    };

    const pid = runtime_state.scheduler.spawn(.{
        .entry = spawnTrampoline,
        .argument = closure_block,
        .manager = manager_state.managerContext(),
    }) catch {
        // The failed spawn never registered the manager context, so the
        // kernel will not run its teardown — destroy it here, along with
        // the closure that will never reach the trampoline.
        BootstrapManagerState.teardownThunk(manager_state);
        runtime_state.ledger.free(closure_block);
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
