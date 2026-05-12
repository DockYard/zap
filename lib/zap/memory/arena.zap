@memory_manager_source = "src/memory/arena/manager.zig"

pub struct Zap.Memory.Arena {
  @structdoc = """
  Whole-program arena memory manager.

  All allocations come from a single arena. Individual deallocations
  are no-ops; the entire arena is reclaimed at program exit. Because
  no per-cell refcount is tracked, the compiler omits the refcount
  header from Map, List, and String layouts, reducing per-cell
  overhead.

  Declared capabilities: none.

  ## Phase 3 status

  The current `@memory_manager_source` target is a placeholder that
  declares zero capabilities and returns null from every allocate
  call. Phase 5 will replace it with a real arena implementation
  (single bump allocator, no individual deallocation, reset at
  shutdown). The stdlib struct itself does not need to change.
  """
}
