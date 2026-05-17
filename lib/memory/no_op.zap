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
  `Memory.Manager` conformance marker for `Memory.NoOp`.

  The protocol declares no methods; this empty impl marks
  `Memory.NoOp` as a selectable memory manager. The compiler resolves
  the NoOp primitive backend from this adapter's declaring source file.
  """

pub impl Memory.Manager for Memory.NoOp {}
