//! Shared test-support declarations for the concurrency kernel's OWN
//! test blocks. TEST-ONLY by contract: this file must be imported only
//! from `test`-scoped code (each kernel module's test section), never
//! from production kernel declarations — `deterministic.Harness`, whose
//! per-process manager is reachable from non-test builds, deliberately
//! keeps its own implementation (`deterministic.zig`,
//! `HarnessProcessManager`) for exactly that reason.
//!
//! One declaration lives here: `CountingArenaManager`, the standard
//! Phase 1 test-manager shape (arena + byte accounting + counted
//! wholesale teardown) that was previously duplicated per test file
//! (`process.zig` TestManager, `scheduler.zig` TestProcessManager,
//! `crash_report.zig` ReportTestManager, `adversarial_stress.zig`
//! StressManager). The real per-process manager binding replaces the
//! `ManagerVTable` seam itself in Phase 2 item 2.4 / Phase 3 items
//! 3.1/3.3 (see `process.zig`, "Manager binding").

const std = @import("std");
const process_module = @import("process.zig");

/// Arena-backed per-process test manager: the Phase 1 stand-in for a
/// real manager instance. `teardown` is the wholesale free-on-exit shape
/// plan item 1.4 prescribes, counted so tests can assert exactly one
/// teardown per spawn; `live_heap_bytes`/`allocation_count` back the
/// item-1.6 heap-byte observability assertions. Reusable across
/// sequential process lifetimes (teardown re-arms the arena) but never
/// shared between concurrently-live processes.
pub const CountingArenaManager = struct {
    arena: std.heap.ArenaAllocator,
    allocation_count: usize = 0,
    live_heap_bytes: usize = 0,
    teardown_count: usize = 0,

    pub fn init(backing_allocator: std.mem.Allocator) CountingArenaManager {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_allocator) };
    }

    /// Release the backing arena itself (the test's `defer`); process
    /// teardown goes through the vtable's `teardown` instead.
    pub fn deinitBacking(manager: *CountingArenaManager) void {
        manager.arena.deinit();
    }

    /// The `ManagerContext` view to hand to spawn. `manager` must stay
    /// pinned while any process holds the context.
    pub fn managerContext(manager: *CountingArenaManager) process_module.ManagerContext {
        return .{ .manager_state = manager, .vtable = &vtable };
    }

    const vtable = process_module.ManagerVTable{
        .allocate = allocateThunk,
        .deallocate = deallocateThunk,
        .teardown = teardownThunk,
        .heapByteCount = heapByteCountThunk,
    };

    fn allocateThunk(manager_state: ?*anyopaque, byte_length: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const manager: *CountingArenaManager = @ptrCast(@alignCast(manager_state.?));
        const memory = manager.arena.allocator().rawAlloc(byte_length, alignment, @returnAddress()) orelse return null;
        manager.allocation_count += 1;
        manager.live_heap_bytes += byte_length;
        return memory;
    }

    fn deallocateThunk(manager_state: ?*anyopaque, memory: [*]u8, byte_length: usize, alignment: std.mem.Alignment) void {
        const manager: *CountingArenaManager = @ptrCast(@alignCast(manager_state.?));
        manager.arena.allocator().rawFree(memory[0..byte_length], alignment, @returnAddress());
        manager.allocation_count -= 1;
        manager.live_heap_bytes -= byte_length;
    }

    fn teardownThunk(manager_state: ?*anyopaque) void {
        const manager: *CountingArenaManager = @ptrCast(@alignCast(manager_state.?));
        manager.teardown_count += 1;
        // Capture the child allocator BEFORE deinit: reading through the
        // arena after `deinit` is use-after-deinit. Re-arming keeps the
        // manager reusable and the test's outer `deinitBacking` valid.
        const backing_allocator = manager.arena.child_allocator;
        manager.arena.deinit();
        manager.arena = std.heap.ArenaAllocator.init(backing_allocator);
        manager.allocation_count = 0;
        manager.live_heap_bytes = 0;
    }

    fn heapByteCountThunk(manager_state: ?*anyopaque) usize {
        const manager: *CountingArenaManager = @ptrCast(@alignCast(manager_state.?));
        return manager.live_heap_bytes;
    }
};
