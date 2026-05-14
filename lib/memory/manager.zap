@doc = """
  Adapter contract for Zap memory managers.

  A memory manager adapter is a Zap-level value that identifies the
  low-level primitive manager implementation selected for a binary.
  First-party managers and third-party managers use the same protocol:
  the public adapter name is user-facing, the primitive source path is
  the implementation identity consumed by the compiler/runtime bridge,
  and the capability mask declares which optional ABI extensions the
  manager supports.

  The adapter is intentionally independent of `Process`: future APIs
  such as per-process manager selection can accept values that implement
  this protocol without changing the first-party manager model.
  """

pub protocol Memory.Manager {
  @doc = """
    Returns the public dotted adapter name used in manifests,
    diagnostics, and documentation.
    """

  fn name(manager) -> String

  @doc = """
    Returns the relative Zig primitive source path for this manager.

    The path identifies the implementation unit that exports the
    `.zapmem` metadata section and runtime vtables. The compiler/runtime
    bridge resolves it; ordinary Zap code should treat it as opaque
    manager metadata.
    """

  fn primitive_source_path(manager) -> String

  @doc = """
    Returns the ABI capability bitmask declared by this manager.

    Bit 0 is `REFCOUNT_V1`. Managers that return `0` provide only the
    mandatory allocation core.
    """

  fn capability_mask(manager) -> i64

  @doc = """
    Returns true when the manager declares the `REFCOUNT_V1`
    capability.
    """

  fn refcount_v1?(manager) -> Bool
}
