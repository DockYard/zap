pub module List {
  @moduledoc = """
    Functions for working with lists.

    Lists in Zap are singly-linked immutable cons cells using
    nullable pointers. An empty list is `[]` (null), and a
    non-empty list is a chain of cells each holding a head value
    and a tail pointer.

    ## Examples

        List.length([1, 2, 3])         # => 3
        List.head([10, 20, 30])        # => 10
        List.reverse([1, 2, 3])        # => [3, 2, 1]
    """

  @doc = """
    Returns `true` if the list has no elements.

    ## Examples

        List.empty?([])        # => true
        List.empty?([1, 2, 3]) # => false
    """

  pub fn empty?(list :: [element]) -> Bool {
    :zig.List.isEmpty(list)
  }

  @doc = """
    Returns the number of elements in the list.

    ## Examples

        List.length([1, 2, 3])  # => 3
        List.length([])         # => 0
    """

  pub fn length(list :: [element]) -> i64 {
    :zig.List.length(list)
  }

  @doc = """
    Returns the first element of the list.
    Returns 0 for an empty list.

    ## Examples

        List.head([10, 20, 30])  # => 10
    """

  pub fn head(list :: [element]) -> element {
    :zig.List.getHead(list)
  }

  @doc = """
    Returns the list without its first element.

    ## Examples

        List.tail([10, 20, 30])  # => [20, 30]
    """

  pub fn tail(list :: [element]) -> [element] {
    :zig.List.getTail(list)
  }

  @doc = """
    Returns the element at the given zero-based index.
    Returns 0 if the index is out of bounds.

    ## Examples

        List.at([10, 20, 30], 1)  # => 20
    """

  pub fn at(list :: [element], index :: i64) -> element {
    :zig.List.get(list, index)
  }

  @doc = """
    Returns the last element of the list.
    Returns 0 for an empty list.

    ## Examples

        List.last([1, 2, 3])  # => 3
    """

  pub fn last(list :: [element]) -> element {
    :zig.List.last(list)
  }

  @doc = """
    Returns `true` if the list contains the given value.

    ## Examples

        List.contains?([1, 2, 3], 2)  # => true
        List.contains?([1, 2, 3], 5)  # => false
    """

  pub fn contains?(list :: [element], value :: element) -> Bool {
    :zig.List.contains(list, value)
  }

  @doc = """
    Reverses the order of elements.

    ## Examples

        List.reverse([1, 2, 3])  # => [3, 2, 1]
    """

  pub fn reverse(list :: [element]) -> [element] {
    :zig.List.reverse(list)
  }

  @doc = """
    Prepends a value to the front of a list.

    ## Examples

        List.prepend([2, 3], 1)  # => [1, 2, 3]
    """

  pub fn prepend(list :: [element], value :: element) -> [element] {
    :zig.List.cons(value, list)
  }

  @doc = """
    Appends a value to the end of a list. O(n).

    ## Examples

        List.append([1, 2], 3)  # => [1, 2, 3]
    """

  pub fn append(list :: [element], value :: element) -> [element] {
    :zig.List.append(list, value)
  }

  @doc = """
    Concatenates two lists.

    ## Examples

        List.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
    """

  pub fn concat(first :: [element], second :: [element]) -> [element] {
    :zig.List.concat(first, second)
  }

  @doc = """
    Takes the first `count` elements.

    ## Examples

        List.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]
    """

  pub fn take(list :: [element], count :: i64) -> [element] {
    :zig.List.take(list, count)
  }

  @doc = """
    Drops the first `count` elements.

    ## Examples

        List.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]
    """

  pub fn drop(list :: [element], count :: i64) -> [element] {
    :zig.List.drop(list, count)
  }

  @doc = """
    Returns a new list with duplicates removed.
    Preserves the order of first occurrences.

    ## Examples

        List.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
    """

  pub fn uniq(list :: [element]) -> [element] {
    :zig.List.uniq(list)
  }

  @doc = """
    Returns the first element of the list.
    Raises if the list is empty.

    ## Examples

        List.head!([10, 20])  # => 10
        List.head!([])        # raises
    """

  pub fn head!(list :: [element]) -> element {
    is_empty = List.empty?(list)
    if is_empty {
      raise("List.head! called on empty list")
    } else {
      List.head(list)
    }
  }

  @doc = """
    Returns the last element of the list.
    Raises if the list is empty.

    ## Examples

        List.last!([1, 2, 3])  # => 3
        List.last!([])         # raises
    """

  pub fn last!(list :: [element]) -> element {
    is_empty = List.empty?(list)
    if is_empty {
      raise("List.last! called on empty list")
    } else {
      List.last(list)
    }
  }

  @doc = """
    Returns the element at the given zero-based index.
    Raises if the index is out of bounds.

    ## Examples

        List.at!([10, 20, 30], 1)  # => 20
        List.at!([10, 20], 5)      # raises
    """

  pub fn at!(list :: [element], index :: i64) -> element {
    in_bounds = index < List.length(list)
    if in_bounds {
      List.at(list, index)
    } else {
      raise("List.at! index out of bounds")
    }
  }
}
