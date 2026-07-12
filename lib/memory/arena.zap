@doc = """
  Arena memory manager: bump allocation, elided frees, one bulk free
  at heap teardown.

  Declared capabilities: none (reclamation model `BULK_OR_NEVER`).
  Allocations are served by bump-pointer from the owning heap's arena
  (a wrapped Zig `std.heap.ArenaAllocator` over `page_allocator`);
  individual deallocations are no-ops, and the arena's backing chunks
  are reclaimed in a single bulk free when the owning heap is torn
  down — at process exit for a per-spawn Arena process, at program
  exit when Arena is the manifest manager.

  ## Selecting Arena

  Arena is a per-spawn manager option, bound at the spawn site:

  ```zap
  Process.spawn(&MyServer.run/0, Memory.Arena)
  ```

  or the whole-binary manifest manager (`-Dmemory=Memory.Arena`). Under
  the concurrency runtime every process owns its own heap, so an Arena
  process's allocation and teardown are entirely process-local.

  ## Zero refcount overhead (comptime elision)

  Because Arena declares no `REFCOUNT_V1` capability, the compiler's
  `BULK_OR_NEVER` specialization elides every `retain`/`release` call
  site and drops the inline `ArcHeader` from `Map`/`List`/`String`/
  `MapIter` cell layouts for code monomorphized against this manager.
  `Map`, `List`, `String`, and every other allocating type are fully
  usable; no refcount op is ever emitted or dispatched — the BEAM-style
  process-heap model at the binary level.

  ## The bounded arena server (automatic receive-loop reset)

  A long-lived Arena server whose receive loop the compiler can prove
  loop-closed — no allocation from one iteration reachable when control
  returns to the `receive` — gets an automatic O(1) arena reset at the
  receive back-edge: per-message garbage never accumulates and the heap
  holds exactly steady across message storms. The proof is conservative
  and per receive site; a loop that retains state across iterations is
  simply never reset. `Process.hibernate()` between messages composes
  with the reset for the full BEAM-hibernation effect. See the
  "Per-spawn memory managers" section of `docs/guides/concurrency.md`.

  ## When to pick Arena

  Short-lived processes whose whole heap dies with them, and long-lived
  bounded servers whose per-message garbage should vanish every
  iteration. For workloads that accumulate unbounded live state across
  iterations, prefer `Memory.ARC` (prompt per-drop reclamation) or
  `Memory.GC` (tracing collection) — an Arena heap only shrinks at a
  proven receive back-edge or at teardown.
  """

pub struct Memory.Arena {
}

@doc = """
  `Memory.Manager` conformance marker for `Memory.Arena`.

  The protocol declares no methods; this empty impl marks
  `Memory.Arena` as a selectable memory manager. The compiler resolves
  the Arena primitive backend from this adapter's declaring source
  file.
  """

pub impl Memory.Manager for Memory.Arena {}
