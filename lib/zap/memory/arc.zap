@memory_manager_source = "src/memory/arc/manager.zig"

pub struct Zap.Memory.ARC {
  @structdoc = """
  Atomic reference counting memory manager.

  Each refcounted cell carries an inline header storing the refcount
  and type tag. Retains and releases are atomic. When a release
  brings the count to zero, the manager's release function walks the
  cell's children, releases them, and frees the cell's storage.

  Declared capabilities: REFCOUNT_V1.
  """
}
