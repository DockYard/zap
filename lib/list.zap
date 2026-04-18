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

  pub fn empty?(list :: [i64]) -> Bool {
    :zig.ListCell.isEmpty(list)
  }

  @doc = """
    Returns the number of elements in the list.

    ## Examples

        List.length([1, 2, 3])  # => 3
        List.length([])         # => 0
    """

  pub fn length(list :: [i64]) -> i64 {
    :zig.ListCell.length(list)
  }

  @doc = """
    Returns the first element of the list.
    Returns 0 for an empty list.

    ## Examples

        List.head([10, 20, 30])  # => 10
    """

  pub fn head(list :: [element]) -> element {
    :zig.ListCell.getHead(list)
  }

  @doc = """
    Returns the list without its first element.

    ## Examples

        List.tail([10, 20, 30])  # => [20, 30]
    """

  pub fn tail(list :: [i64]) -> [i64] {
    :zig.ListCell.getTail(list)
  }

  @doc = """
    Returns the element at the given zero-based index.
    Returns 0 if the index is out of bounds.

    ## Examples

        List.at([10, 20, 30], 1)  # => 20
    """

  pub fn at(list :: [i64], index :: i64) -> i64 {
    :zig.ListCell.get(list, index)
  }

  @doc = """
    Returns the last element of the list.
    Returns 0 for an empty list.

    ## Examples

        List.last([1, 2, 3])  # => 3
    """

  pub fn last(list :: [i64]) -> i64 {
    :zig.ListCell.last(list)
  }

  @doc = """
    Returns `true` if the list contains the given value.

    ## Examples

        List.contains?([1, 2, 3], 2)  # => true
        List.contains?([1, 2, 3], 5)  # => false
    """

  pub fn contains?(list :: [i64], value :: i64) -> Bool {
    :zig.ListCell.contains(list, value)
  }

  @doc = """
    Reverses the order of elements.

    ## Examples

        List.reverse([1, 2, 3])  # => [3, 2, 1]
    """

  pub fn reverse(list :: [i64]) -> [i64] {
    :zig.ListCell.reverse(list)
  }

  @doc = """
    Prepends a value to the front of a list.

    ## Examples

        List.prepend([2, 3], 1)  # => [1, 2, 3]
    """

  pub fn prepend(list :: [i64], value :: i64) -> [i64] {
    :zig.ListCell.cons(value, list)
  }

  @doc = """
    Appends a value to the end of a list. O(n).

    ## Examples

        List.append([1, 2], 3)  # => [1, 2, 3]
    """

  pub fn append(list :: [i64], value :: i64) -> [i64] {
    :zig.ListCell.append(list, value)
  }

  @doc = """
    Concatenates two lists.

    ## Examples

        List.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
    """

  pub fn concat(first :: [i64], second :: [i64]) -> [i64] {
    :zig.ListCell.concat(first, second)
  }

  @doc = """
    Takes the first `count` elements.

    ## Examples

        List.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]
    """

  pub fn take(list :: [i64], count :: i64) -> [i64] {
    :zig.ListCell.take(list, count)
  }

  @doc = """
    Drops the first `count` elements.

    ## Examples

        List.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]
    """

  pub fn drop(list :: [i64], count :: i64) -> [i64] {
    :zig.ListCell.drop(list, count)
  }

  @doc = """
    Returns a new list with duplicates removed.
    Preserves the order of first occurrences.

    ## Examples

        List.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
    """

  pub fn uniq(list :: [i64]) -> [i64] {
    :zig.ListCell.uniq(list)
  }
}
