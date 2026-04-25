pub impl Enumerable for Map {
  @doc = """
    Returns the next entry from a map.

    Map iteration is not yet supported. This stub satisfies
    protocol conformance but will produce a compile error
    if used in a for comprehension until Map.next is
    implemented in the runtime.
    """

  pub fn next(map :: Map) -> {Atom, i64, Map} {
    :zig.Map.next(map)
  }
}
