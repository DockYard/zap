@doc = """
  Diagnostic leak-everything memory manager. CI tool.

  Declared capabilities: none. Every allocation comes directly from
  `std.heap.page_allocator`; every individual deallocation is a
  deliberate no-op. Memory is intentionally leaked for the entire
  lifetime of the process — the OS reclaims pages on exit.

  ## Intended use cases

  Leak is NOT a general-purpose manager. Two CI use cases motivate
  it:

  ### 1. Codegen elision verification

  A Zap binary built with `memory: Memory.Leak` declares zero
  capabilities (no `REFCOUNT_V1`). Under Phase 6's conditional
  layout + codegen elision the compiler must emit zero retain/
  release call sites. The output binary's `.text` should contain no
  references to the manager's retain/release vtable at all — if
  elision regresses and the compiler keeps emitting retains/releases
  against a manager that has no `REFCOUNT_V1` slot, the resulting
  symbol references either fail to link or call into uninitialised
  vtable slots, which CI catches immediately.

  ### 2. Bounded-memory benchmarks

  A short-lived program built with Leak runs to completion without
  freeing anything; the OS reclaims the address space on exit. This
  baselines what raw allocator throughput looks like with zero
  deallocation overhead and zero refcount overhead, isolating
  whatever performance characteristic the benchmark is meant to
  measure from manager-side bookkeeping.

  ## Not for production

  Leak is a CI / benchmarking tool. Long-running processes built
  with Leak will exhaust the process's address space and abort with
  OOM the moment `mmap` (or the host-OS equivalent) refuses another
  page. For BEAM-style "leak until exit but bulk-free on shutdown"
  semantics, use `Memory.Arena` instead — it has the same
  no-individual-deallocation surface but reclaims its backing
  storage in a single bulk free at `core.deinit`.
  """

pub struct Memory.Leak {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.Leak`.
  """

pub impl Memory.Manager for Memory.Leak {
  @doc = """
    Binds the Leak manager type to its primitive backend.
    """

  pub fn backend(manager :: Memory.Leak) -> Bool {
    :zig.Memory.backend(manager)
  }
}
