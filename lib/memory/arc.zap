@doc = """
  Atomic reference counting memory manager.

  The manager declares `REFCOUNT_V1` and services two cell shapes
  through a single capability vtable:

  - **Inline-header cells** (`Map(K, V)`, `List(T)`, `MapIter`): the
    cell carries a 4-byte refcount at offset 0. Retains and releases
    use the vtable's `retain` / `release` slots, which perform an
    atomic increment / decrement on those first 4 bytes. On the
    zero-transition the manager invokes the runtime-supplied
    per-type `deep_walk` callback that walks children and frees the
    cell's variable-length backing buffer.

  - **Generic `Arc(T)` cells** (side-table layout): allocated from a
    byte-keyed multi-class slab pool inside the manager. Each slab
    is 64 KiB-aligned and carries a per-slot side-table refcount in
    its header so the slot bytes are 100% user payload (no per-cell
    ArcHeader overhead, no alignment padding). Allocations above
    4096 bytes fall back to `page_allocator` directly. The vtable
    exposes `allocate_refcounted` / `retain_sized` / `release_sized`
    / `refcount_sized` for this path; the runtime's `allocAny` /
    `retainAny` / `releaseAny` / `refCountAny` helpers dispatch
    through them.

  The slab-pool size classes cover the 1.5× progression from
  16 bytes to 4096 bytes (16, 24, 32, 48, 64, 96, 128, 192, 256,
  384, 512, 768, 1024, 1536, 2048, 3072, 4096). The class lookup
  is O(1) via a comptime-built table; alignment-induced class
  escalation traverses at most 2-3 classes.

  Declared capabilities: REFCOUNT_V1.
  """

pub struct Memory.ARC {
}

@doc = """
  `Memory.Manager` adapter implementation for `Memory.ARC`.
  """

pub impl Memory.Manager for Memory.ARC {
  @doc = """
    Returns the public adapter name for the ARC manager.
    """

  pub fn name(_manager :: Memory.ARC) -> String {
    "Memory.ARC"
  }

  @doc = """
    Returns the primitive source path for the ARC manager.
    """

  pub fn primitive_source_path(_manager :: Memory.ARC) -> String {
    "src/memory/arc/manager.zig"
  }

  @doc = """
    Returns the ARC manager's declared capability bitmask.
    """

  pub fn capability_mask(_manager :: Memory.ARC) -> i64 {
    1
  }

  @doc = """
    Returns true because ARC declares `REFCOUNT_V1`.
    """

  pub fn refcount_v1?(_manager :: Memory.ARC) -> Bool {
    true
  }
}
