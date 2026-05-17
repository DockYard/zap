@doc = """
  Conformance marker for Zap memory managers.

  `Memory.Manager` is a zero-method protocol: it declares no methods
  and carries no behavior. A manager type opts in purely by declaring
  `impl Memory.Manager for X`, which marks `X` as a selectable memory
  manager. Stdlib managers and third-party managers use the same
  marker.

  The primitive backend for a selected manager is resolved by the
  compiler from the adapter's declaring source file via the package
  convention — the adapter exposes no manager names, source paths, or
  capability masks in Zap code. Because the protocol declares no
  methods, conforming impls are empty.

  The marker is intentionally independent of `Process`: future APIs
  such as per-process manager selection can accept values that implement
  this protocol without changing the adapter model.
  """

pub protocol Memory.Manager {}
