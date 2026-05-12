@memory_manager_source = "src/runtime/memory/arc/manager.zig"

pub struct Zap.Memory.ARC {
  @structdoc = """
  Atomic reference counting memory manager.

  Each refcounted cell carries an inline header storing the refcount
  and type tag. Retains and releases are atomic. When a release
  brings the count to zero, the manager's release function walks the
  cell's children, releases them, and frees the cell's storage.

  Declared capabilities: REFCOUNT_V1.

  ## Phase 3 behaviour

  When `Zap.Memory.ARC` appears as the `memory:` field of a
  `Zap.Manifest`, the Zap-side memory driver short-circuits: no
  external manager `.o` is compiled, and the runtime continues to
  use its built-in ARC stub. Phase 4 will rip the stub out and
  point `@memory_manager_source` at a real self-contained ARC
  manager package; the stdlib struct itself does not need to
  change.
  """
}
