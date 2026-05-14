@doc = """
  No-op memory manager. Declares zero capabilities, the manager's
  `allocate` vtable slot returns null, and `deallocate` is a no-op.

  ## Phase 3 status

  In the Phase 3 ABI wiring, Zap's allocate/free paths still go
  through the runtime's built-in ARC implementation regardless of
  which manager is active — only retain/release dispatch through
  the active manager today. The `allocate` vtable slot on this
  manager is therefore reachable only via the Phase 4 dispatcher
  refactor (`allocAny`/`freeAny`), at which point a program built
  with `memory: Memory.NoOp` will terminate at its first
  allocation with the documented OOM diagnostic.

  Phase 3's role for this manager is to validate the build pipeline
  end-to-end: the manager `.zig` source compiles cleanly through
  the in-process Zig fork, the `.zapmem` section round-trips
  through the section parser, the build driver appends the
  resulting `.o` to the link line, and the runtime bootstrap binds
  the external vtable in place of the built-in ARC core.
  """

pub struct Memory.NoOp {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.NoOp`.
  """

pub impl Memory.Manager for Memory.NoOp {
  @doc = """
    Returns the public adapter name for the NoOp manager.
    """

  pub fn name(_manager :: Memory.NoOp) -> String {
    "Memory.NoOp"
  }

  @doc = """
    Returns the primitive source path for the NoOp manager.
    """

  pub fn primitive_source_path(_manager :: Memory.NoOp) -> String {
    "src/memory/no_op/manager.zig"
  }

  @doc = """
    Returns the NoOp manager's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: Memory.NoOp) -> i64 {
    0
  }

  @doc = """
    Returns false because NoOp does not declare `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: Memory.NoOp) -> Bool {
    false
  }
}
