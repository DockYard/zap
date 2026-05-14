@doc = """
Enumerable implementation for `Map`.
"""

pub impl Enumerable({map_key, map_value}) for Map(map_key, map_value) {
  @doc = """
    Returns the next entry from a map.

    Each step yields `{:cont, {key, value}, iter}` where `iter` is
    an opaque cursor cell that advances the iteration without
    cloning the source map, or `{:done, undef_pair, nil}` when
    iteration completes. Iteration order is unspecified across
    runs but stable within a single iteration. Total cost is O(n)
    for a map of n entries — one cursor cell is allocated on the
    first step, advanced in place on each subsequent step, and
    released automatically on the DONE step. See
    `runtime.MapIter` for the cursor implementation.
    """

  pub fn next(map :: %{map_key => map_value}) -> {Atom, {map_key, map_value}, %{map_key => map_value}} {
    :zig.Map.next(map)
  }
}
