pub impl Enumerable for Map(K, V) {
  @doc = """
    Returns the next entry from a map.

    Each step yields `{:cont, {key, value}, remaining_map}` or
    `{:done, undef_pair, map}` when the map is empty. Iteration order
    is unspecified across runs but stable within a single iteration.
    Total cost is O(n log n) for a map of n entries — each step
    removes the yielded entry and returns the persistent remainder.
    """

  pub fn next(map :: Map(K, V)) -> {Atom, {K, V}, Map(K, V)} {
    :zig.Map.next(map)
  }
}
