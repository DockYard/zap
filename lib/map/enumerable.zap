pub impl Enumerable for Map {
  @doc = """
    Returns the next entry from a map.

    Map iteration is not yet supported. The signature is intentionally
    simplified to `Map -> Map` rather than the protocol's
    `(state) -> {Atom, i64, any}` because emitting a tuple return
    containing the bare generic `Map` type currently fails ZIR
    materialization. Once generic-type tuple returns are wired up,
    restore the proper signature and have the body either route to a
    runtime iterator or `raise` on use.
    """

  pub fn next(map :: Map) -> Map {
    map
  }
}
