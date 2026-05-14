@doc = """
  Adapter contract for Zap memory managers.

  A memory manager adapter is a Zap-level value that identifies the
  low-level primitive manager implementation selected for a binary.
  Stdlib managers and third-party managers use the same protocol:
  the public adapter name is user-facing, the primitive source path is
  the implementation identity consumed by the compiler/runtime bridge,
  and the capability mask declares which optional ABI extensions the
  manager supports.

  The adapter is intentionally independent of `Process`: future APIs
  such as per-process manager selection can accept values that implement
  this protocol without changing the adapter model.
  """

pub protocol Memory.Manager {
  @doc = """
    Returns the public dotted adapter name used in manifests,
    diagnostics, and documentation.
    """

  fn name(manager) -> String

  @doc = """
    Returns the Zig primitive source reference for this manager.

    The reference identifies the implementation unit that exports the
    `.zapmem` metadata section and runtime vtables. `zap:<path>` is
    resolved relative to the Zap source tree, `project:<path>` is
    resolved relative to the current project root, and
    `dep:<name>:<path>` is resolved relative to the named dependency
    source root. Ordinary Zap code should treat the value as opaque
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
