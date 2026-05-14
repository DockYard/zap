@doc = """
  Whole-program arena memory manager.

  Declared capabilities: none. All allocations come from a single
  process-wide arena backed by `std.heap.page_allocator`; individual
  deallocations are no-ops, and the entire arena is reclaimed at
  program exit. The wrapped Zig 0.16 `std.heap.ArenaAllocator` is
  lock-free, so multi-threaded programs incur no synchronization
  overhead inside `allocate`.

  Because Arena declares no `REFCOUNT_V1` capability, programs that
  construct `Map`, `List`, `String`, or `MapIter` under this manager
  panic on first refcount dispatch — those types currently route
  retain/release through the active manager's vtable and Arena does
  not service that capability. Phase 6 (conditional layout + codegen
  elision) is the planned follow-up that:

    * drops the inline `ArcHeader` from `Map`/`List`/`String`/`MapIter`
      cell layouts under a no-REFCOUNT_V1 manager, and
    * elides every retain/release call site at codegen.

  After Phase 6, an Arena build will produce a binary with zero
  refcount overhead — matching the BEAM-style process-heap model
  this manager is intended to approximate at the binary level. Until
  then, Arena is fully usable for programs whose allocations all
  flow through raw `core.allocate` (non-refcounted data structures,
  transient scratch, compiler-emitted byte allocations).
  """

pub struct Memory.Arena {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.Arena`.
  """

pub impl Memory.Manager for Memory.Arena {
  @doc = """
    Binds the Arena manager type to its primitive backend.
    """

  pub fn backend(manager :: Memory.Arena) -> Bool {
    :zig.Memory.backend(manager)
  }
}
