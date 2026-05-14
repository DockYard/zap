@doc = """
  Adapter contract for Zap memory managers.

  A memory manager adapter is a Zap-level value that binds a manager
  type to the low-level primitive backend selected for a binary.
  Stdlib managers and third-party managers use the same protocol:
  the adapter calls the backend primitive for its own type, and the
  compiler/runtime bridge derives the implementation identity from
  that type plus the package-level manager backend convention.

  The adapter is intentionally independent of `Process`: future APIs
  such as per-process manager selection can accept values that implement
  this protocol without changing the adapter model.
  """

pub protocol Memory.Manager {
  @doc = """
    Binds this manager type to its primitive backend.

    Implementations should delegate directly to
    `:zig.Memory.backend(manager)`. The backend primitive records the
    selected manager type during build-time evaluation; no adapter
    should expose manager names, source paths, or capability masks in
    Zap code.
    """

  fn backend(manager) -> Bool
}
