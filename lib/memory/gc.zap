@doc = """
  Conservative tracing garbage-collected memory manager.

  Declared capability axis: `TRACED` (Axis A = `0b10`). Allocations are
  served from a managed heap that the manager tracks; reclamation happens
  by a periodic stop-the-world conservative mark-sweep collection rather
  than by reference counting or static free-at-last-use.

  ## Why TRACED reuses the BULK_OR_NEVER codegen contract

  From the compiler's point of view a `TRACED` build is byte-identical to
  a `BULK_OR_NEVER` (Arena/NoOp/Leak) build: the compiler elides every
  `retain`/`release`/individual-`free`, lays out no inline `ArcHeader`,
  and routes every allocation through the active manager's `core.allocate`
  vtable slot. No refcount op is ever emitted or dispatched. The manager
  is the only component that reclaims — at collection time, not at any
  compiler-inserted drop site.

  Two language properties make this sound with **zero** garbage-collection
  codegen:

    * **Immutability ⇒ no write barriers, ever.** A heap object's outgoing
      pointers are fixed at construction; an already-constructed object can
      never gain a new reference to another heap object. A tracing collector
      needs write barriers only to catch mutations of the object graph
      between collections — in Zap there are none, so the collector never
      needs the compiler to instrument stores.

    * **Conservative root scanning ⇒ no root maps or safepoints.** Rather
      than consult compiler-emitted stack maps to find precise roots, the
      collector treats every word-aligned value on the stack, in the
      flushed registers, and in the global data/bss segments as a *potential*
      pointer: if it falls inside a tracked allocation, that allocation is
      pinned (conservatively retained). The compiler therefore needs neither
      stack maps nor safepoint polls.

  Because both obligations are discharged at runtime by the manager, the
  compiler emits exactly the same code it emits for `Memory.Arena`. Phase 5
  of the capability-driven memory model adds the collector backend without
  any new compiler emission.

  ## Collection model

  The backend (`src/memory/gc/manager.zig`) implements a single-threaded,
  stop-the-world, conservative mark-sweep collector:

    * **Managed heap.** Every live allocation is recorded as a
      `[base, base + size)` interval; an address landing anywhere inside an
      interval pins that object (interior pointers are honoured).
    * **Trigger.** When live-heap bytes cross a growth threshold,
      `allocate` runs a full collection before satisfying the request, so a
      long allocate-and-drop loop stays bounded in resident memory.
    * **Roots.** The collector captures the stack bottom at manager `init`
      as the OS thread stack base (the fixed high end of the thread's
      stack, so the scan covers the program's entry frame regardless of how
      deeply `init` is nested), flushes callee-saved registers to the stack,
      and scans the live stack span, the flushed registers, and the global
      segments for pointer-like words.
    * **Mark.** Reachable objects are marked via an explicit worklist
      (never deep native recursion), scanning each marked object's bytes for
      further tracked-heap pointers.
    * **Sweep.** Every tracked, unmarked object is returned to the OS; marks
      are cleared for the next cycle.

  Conservatism is safe-by-over-retention: a non-pointer word that happens
  to look like a heap address keeps an object alive one cycle longer than
  strictly necessary. This never frees a live object, so program behaviour
  is always correct; it can only delay reclamation. `core.deallocate` is a
  no-op — the collector owns all reclamation.

  Unlike `Memory.NoOp` and `Memory.Leak`, which never reclaim and grow
  resident memory without bound, a `Memory.GC` build reclaims unreachable
  allocations and keeps RSS bounded across an allocate-and-drop workload.
  """

pub struct Memory.GC {
}

@doc = """
  `Memory.Manager` conformance marker for `Memory.GC`.

  The protocol declares no methods; this empty impl marks `Memory.GC` as a
  selectable memory manager. The compiler resolves the conservative
  mark-sweep backend (`src/memory/gc/manager.zig`) from this adapter's
  declaring source file by package convention, and reads the `TRACED`
  reclamation model from the backend's declared capabilities — never from
  the manager's name.
  """

pub impl Memory.Manager for Memory.GC {}
