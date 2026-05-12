@memory_manager_source = "src/memory/arena/manager.zig"

pub struct Zap.Memory.Arena {
  @structdoc = """
  Whole-program arena memory manager.

  Declared capabilities (target design): none. Once Phase 5 lands
  the real arena implementation, all allocations come from a single
  bump arena, individual deallocations are no-ops, and the entire
  arena is reclaimed at program exit. Because no per-cell refcount
  is tracked, the compiler omits the refcount header from Map,
  List, and String layouts, reducing per-cell overhead.

  ## Phase 3 status

  The current `@memory_manager_source` target is a placeholder that
  declares zero capabilities and returns null from every allocate
  call in its vtable. Phase 5 will replace it with the real arena
  implementation; the stdlib struct itself does not need to change.

  Independently of the placeholder, the Phase 3 wiring leaves the
  Zap allocate/free paths going through the runtime's built-in ARC
  implementation even when this manager is selected — only
  retain/release dispatch through the active manager's vtable
  today. Phase 4 introduces the allocate/free dispatcher
  (`allocAny`/`freeAny`), at which point a program built with
  `memory: Zap.Memory.Arena` will route allocate/free through this
  manager's vtable.
  """
}
