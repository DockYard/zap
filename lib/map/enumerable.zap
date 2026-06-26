@doc = """
  Enumerable implementation for `Map`.
  """

pub impl Enumerable({map_key, map_value}) for Map(map_key, map_value) {
  @doc = """
    Returns the next entry from a map.

    Each step consumes the current state and yields `{:cont, {key, value},
    next_state}` where `next_state` may be a cursor-backed map state that
    advances iteration without cloning the source map, or `{:done, undef_pair,
    nil}` when iteration completes. Iteration order is unspecified across runs
    but stable within a single iteration. Total cost is O(n) for a map of n
    entries — one cursor cell is allocated for multi-entry maps, advanced in
    place on each subsequent step, and released when the final state is
    consumed. See `runtime.MapIter` for the cursor implementation.
    """

  pub fn next(map :: unique %{map_key => map_value}) -> {Atom, {map_key, map_value}, %{map_key => map_value}} {
    :zig.Map.next(map)
  }

  @doc = """
    Releases an unconsumed map iteration state.

    Cursor-backed map states own runtime resources when iteration stops
    before reaching `:done`; disposing the state releases that cursor
    directly without walking the remaining entries.
    """

  pub fn dispose(map :: unique %{map_key => map_value}) -> Nil {
    :zig.Map.release(map)
    nil
  }
}
