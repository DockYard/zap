@doc = """
  Whole-program arena memory manager.

  Declared capabilities: none. All allocations come from a single
  process-wide arena backed by `std.heap.page_allocator`; individual
  deallocations are no-ops, and the entire arena is reclaimed at
  program exit. The wrapped Zig 0.16 `std.heap.ArenaAllocator` is
  lock-free, so multi-threaded programs incur no synchronization
  overhead inside `allocate`.

  ## Phase 5 status

  As of Phase 5, `Memory.Manager.primitive_source_path/1` identifies
  the production arena implementation: a real allocator backs
  `core.allocate`, `core.deallocate` is a no-op, and
  `core.get_capability_desc` returns `null` for every ID. The `.zapmem`
  section declares zero capabilities.

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
    Returns the public adapter name for the Arena manager.
    """

  pub fn name(_manager :: Memory.Arena) -> String {
    "Memory.Arena"
  }

  @doc = """
    Returns the primitive source path for the Arena manager.
    """

  pub fn primitive_source_path(_manager :: Memory.Arena) -> String {
    "zap:src/memory/arena/manager.zig"
  }

  @doc = """
    Returns the Arena manager's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: Memory.Arena) -> i64 {
    0
  }

  @doc = """
    Returns false because Arena does not declare `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: Memory.Arena) -> Bool {
    false
  }
}
