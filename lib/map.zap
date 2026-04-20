pub module Map {
  @moduledoc = """
    Functions for working with maps.

    Maps in Zap are immutable key-value collections that support
    any key and value types. The compiler specializes map operations
    at compile time based on the concrete types used.

    ## Examples

        m = %{name: "Alice", age: 30}
        Map.get(m, :name, "")    # => "Alice"
        Map.has_key?(m, :name)   # => true
        Map.size(m)              # => 2
    """

  @doc = """
    Returns the value for the given key, or the default if
    the key is not found.

    ## Examples

        Map.get(%{a: 1, b: 2}, :a, 0)  # => 1
        Map.get(%{a: 1}, :z, 99)        # => 99
    """

  pub fn get(map :: %{key => value}, lookup_key :: key, default :: value) -> value {
    :zig.Map.get(map, lookup_key, default)
  }

  @doc = """
    Returns `true` if the map contains the given key.

    ## Examples

        Map.has_key?(%{a: 1, b: 2}, :a)  # => true
        Map.has_key?(%{a: 1}, :z)         # => false
    """

  pub fn has_key?(map :: %{key => value}, lookup_key :: key) -> Bool {
    :zig.Map.hasKey(map, lookup_key)
  }

  @doc = """
    Returns the number of entries in the map.

    ## Examples

        Map.size(%{a: 1, b: 2, c: 3})  # => 3
        Map.size(%{})                    # => 0
    """

  pub fn size(map :: %{key => value}) -> i64 {
    :zig.Map.size(map)
  }

  @doc = """
    Returns `true` if the map has no entries.

    ## Examples

        Map.empty?(%{})       # => true
        Map.empty?(%{a: 1})  # => false
    """

  pub fn empty?(map :: %{key => value}) -> Bool {
    :zig.Map.isEmpty(map)
  }

  @doc = """
    Returns a new map with the key set to the given value.
    If the key already exists, its value is updated.

    ## Examples

        Map.put(%{a: 1}, :b, 2)  # => %{a: 1, b: 2}
        Map.put(%{a: 1}, :a, 9)  # => %{a: 9}
    """

  pub fn put(map :: %{key => value}, new_key :: key, new_value :: value) -> %{key => value} {
    :zig.Map.put(map, new_key, new_value)
  }

  @doc = """
    Returns a new map with the given key removed.
    Returns the map unchanged if the key doesn't exist.

    ## Examples

        Map.delete(%{a: 1, b: 2}, :a)  # => %{b: 2}
        Map.delete(%{a: 1}, :z)         # => %{a: 1}
    """

  pub fn delete(map :: %{key => value}, remove_key :: key) -> %{key => value} {
    :zig.Map.delete(map, remove_key)
  }

  @doc = """
    Merges two maps. Keys from the second map override keys
    from the first.

    ## Examples

        Map.merge(%{a: 1, b: 2}, %{b: 9, c: 3})
        # => %{a: 1, b: 9, c: 3}
    """

  pub fn merge(map_a :: %{key => value}, map_b :: %{key => value}) -> %{key => value} {
    :zig.Map.merge(map_a, map_b)
  }

  @doc = """
    Returns a list of all keys in the map.

    ## Examples

        Map.keys(%{a: 1, b: 2})  # => [:a, :b]
    """

  pub fn keys(map :: %{key => value}) -> [key] {
    :zig.Map.keys(map)
  }

  @doc = """
    Returns a list of all values in the map.

    ## Examples

        Map.values(%{a: 1, b: 2})  # => [1, 2]
    """

  pub fn values(map :: %{key => value}) -> [value] {
    :zig.Map.values(map)
  }
}
