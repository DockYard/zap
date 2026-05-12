@memory_manager_source = "src/memory/arc/manager.zig"

pub struct Zap.Memory.ARC {
  @structdoc = """
  Atomic reference counting memory manager.

  Each refcounted cell carries an inline header storing the refcount
  and type tag. Retains and releases are atomic. When a release
  brings the count to zero, the manager's release function walks the
  cell's children, releases them, and frees the cell's storage.

  Declared capabilities: REFCOUNT_V1.

  Implementation note (v1.0): the manager's `core.allocate` and
  `core.deallocate` slots are no-ops — they return `null` and do
  nothing, respectively. Refcounted cells in v1.0 are routed through
  a runtime-internal allocator instead: inline-header types
  (`Map(K,V)`, `List(T)`, ...) own their bespoke `bufferAlloc`
  helpers in `src/runtime.zig`, and `Arc(T)` side-table allocations
  use a per-type slab pool. A future Phase 4.x byte-level slab
  redesign will route the side-table path through `core.allocate`
  so the slots become functional; until then they exist purely to
  satisfy the spec's "every manager exposes the full
  `ZapMemoryManagerCoreV1` vtable" contract.
  """
}
