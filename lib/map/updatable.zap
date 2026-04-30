@doc = "Updatable implementation for `Map`."

pub impl Updatable for Map(K, V) {
  @doc = """
    Map functional update — equivalent to `Map.put/3`. Returns a new map
    with `key` mapped to `value`; the original map is unchanged.
    """

  pub fn update(map :: %{K => V}, key :: K, value :: V) -> %{K => V} {
    :zig.Map.put(map, key, value)
  }
}
