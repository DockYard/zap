@doc = """
  ORC-over-ARC cyclic reclamation memory manager.

  ORC is Zap's cyclic reclamation model: atomic reference counting
  (exactly `Memory.ARC`) plus a **Bacon–Rajan trial-deletion cycle
  collector** — the same "ARC + a cycle collector" design Nim's ORC
  ships. It reclaims reference cycles that `Memory.ARC` alone cannot:
  a struct or closure that references itself, or a set of cells with
  mutual references. Acyclic data keeps ARC's prompt, deterministic
  reclamation; only genuine cycles wait for a collection point.

  ## Selecting ORC

  ORC is a per-spawn manager option, bound at the spawn site:

  ```zap
  Process.spawn(worker, Memory.ORC)
  ```

  or as the whole-binary manifest manager (`-Dmemory=Memory.ORC`).

  ## Deeply per-process, no stack scanning

  Unlike `Memory.GC` (conservative mark-sweep, `TRACED`), ORC works on
  the reference-count graph, not the stack — it needs no conservative
  scan of a fiber's saved registers or private stack. Each spawned
  process owns its own ORC collector (thread-local candidate buffer,
  thread-local collection at the owning process's yield points and
  teardown, never a global stop-the-world). ORC therefore ships on
  every target `Memory.ARC` does.

  ## Declared capabilities

  ORC declares **REFCOUNT_V1** — its reclamation model is REFCOUNTED
  on Axis A, byte-identical to `Memory.ARC` (`declared_caps == 0x1`).
  The compiler emits the identical `retain`/`release` code for an ORC
  process and an ARC process (they share one codegen specialization);
  the cycle collector is entirely manager-internal — the Bacon–Rajan
  cycle-root candidate buffering lives inside the manager's `release`
  implementation, advertised through a separate cycle-collection
  capability descriptor, never a new Axis-A model. The compiler
  resolves the ORC primitive backend from this adapter's declaring
  source file (`src/memory/orc/manager.zig`) by package convention.
  """

pub struct Memory.ORC {
}

@doc = """
  `Memory.Manager` conformance marker for `Memory.ORC`.

  The protocol declares no methods; this empty impl marks `Memory.ORC`
  as a selectable memory manager. The compiler resolves the ORC
  cyclic-reclamation backend (`src/memory/orc/manager.zig`) from this
  adapter's declaring source file by package convention, and reads the
  `REFCOUNTED` reclamation model from the backend's declared
  capabilities — never from the manager's name.
  """

pub impl Memory.Manager for Memory.ORC {}
