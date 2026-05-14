@memory_manager_source = "src/memory/tracking/manager.zig"

@doc = """
Diagnostic tracking memory manager. CI tool.

Declared capabilities: none. Wraps a `page_allocator`-backed inner
allocator and adds bookkeeping to detect three classes of bug:

  * **Leaks**: any allocation still present in the live-allocation
    hash map when `core.deinit` runs prints
    `LEAK: ptr=0x..., size=N, alignment=A` to stderr.
  * **Invalid frees**: a `core.deallocate` for a pointer not
    present in the map prints
    `INVALID FREE: ptr=0x... not allocated by this manager`.
  * **Use-after-free / out-of-bounds writes**: 16 bytes of `0xCC`
    canary padding on each side of every user region; canary
    tampering detected on `core.deallocate` prints
    `USE-AFTER-FREE or OOB: canary corrupted at ptr=0x...`.

## Phase 7 status

As of Phase 7, the manager source at `@memory_manager_source` is
the production Tracking implementation: every `core.allocate`
request becomes an inner `page_allocator` allocation of
`leading_canary + size + trailing_canary` bytes, with the user
pointer offset past the leading canary. Records are kept in an
`AutoHashMapUnmanaged(usize, AllocRecord)` keyed by user pointer
value; mutations are serialised by a `cmpxchg`-based spinlock.
The `.zapmem` section declares zero capabilities.

## Intended use cases

Tracking is a CI / development tool, not a production manager.
Two use cases motivate it:

### 1. Catching ARC bugs

Phase 6's codegen elision means programs built without
`REFCOUNT_V1` route Map/List/String allocations through raw
`core.allocate` (no refcount call sites). Building such a
program with `memory: Zap.Memory.Tracking` exercises the
elision path under canary checks: any compiler-emitted alloc
not matched by a corresponding `deallocate` becomes a leak
report at exit, and any buffer overflow into the trailing
canary becomes a UAF report.

### 2. Verifying memory lifecycle

Tests that exercise edge cases in the runtime's allocation
paths can be run under Tracking to confirm every `allocate`
has a matching `deallocate`. The hash-map-based bookkeeping
catches both single-allocation leaks and double frees (the
second `deallocate` for a pointer hits the
`INVALID FREE` branch because the first removed the record).

## Performance

Tracking is significantly slower than the default ARC manager —
every alloc/free takes a spinlock, a hash-map insert/remove,
and a 16-byte canary fill/check. This is intentional: the
manager is for diagnostic CI runs, not production workloads.

## Not for production

Long-running processes built with Tracking accumulate hash-map
entries proportional to the number of live allocations. The
bookkeeping itself can leak (the hash map's backing storage)
if the program does not drive `core.deinit` on a clean exit
path; in CI use this is acceptable because the OS reclaims
everything at process exit. For production, use
`Zap.Memory.ARC` (default) or `Zap.Memory.Arena`.
"""

pub struct Zap.Memory.Tracking {
}
