@doc = """
  No-op memory manager. Declares zero capabilities, the manager's
  `allocate` vtable slot always returns null, and `deallocate` is a
  no-op.

  ## Behavior

  Every allocation routes through the active manager, so a heap
  running under `memory: Memory.NoOp` terminates at its FIRST
  allocation: `allocate` returns null and the runtime aborts with
  the documented OOM diagnostic. Because NoOp declares no
  `REFCOUNT_V1` capability, the compiler's `BULK_OR_NEVER`
  specialization also elides every retain/release call site — the
  only manager surface a NoOp binary can reach is the always-null
  `allocate`.

  ## Intended use case

  NoOp is a build-pipeline validation fixture, not a runnable
  manager: it proves the manager toolchain end-to-end with the
  smallest possible backend — the manager `.zig` source compiles
  cleanly through the in-process Zig fork, the `.zapmem` capability
  section round-trips through the section parser, the build driver
  appends the resulting `.o` to the link line, and the runtime
  bootstrap binds the external vtable. An allocation-free program is
  the only program that runs to completion under NoOp; anything else
  exercises the deliberate first-allocation abort.
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
