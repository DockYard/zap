pub module Enum {
  @moduledoc = """
    Functions for enumerating and transforming collections.

    Enum provides higher-order functions that operate on lists
    using callbacks. All functions accept a list and a function
    argument, enabling map, filter, reduce, and other functional
    patterns.

    ## Examples

        Enum.map([1, 2, 3], fn(x) { x * 2 })       # => [2, 4, 6]
        Enum.filter([1, 2, 3, 4], fn(x) { x > 2 })  # => [3, 4]
        Enum.reduce([1, 2, 3], 0, fn(acc, x) { acc + x })  # => 6
    """

  @doc = """
    Transforms each element by applying the callback function.

    ## Examples

        Enum.map([1, 2, 3], fn(x) { x * 2 })  # => [2, 4, 6]
        Enum.map([], fn(x) { x + 1 })          # => []
    """

  pub fn map(list :: [element], callback :: (element -> result)) -> [result] {
    :zig.ListCell.mapFn(list, callback)
  }

  @doc = """
    Keeps only elements for which the predicate returns true.

    ## Examples

        Enum.filter([1, 2, 3, 4], fn(x) { x > 2 })  # => [3, 4]
        Enum.filter([1, 2, 3], fn(x) { x > 10 })     # => []
    """

  pub fn filter(list :: [element], predicate :: (element -> Bool)) -> [element] {
    :zig.ListCell.filterFn(list, predicate)
  }

  @doc = """
    Removes elements for which the predicate returns true.
    The opposite of `filter/2`.

    ## Examples

        Enum.reject([1, 2, 3, 4], fn(x) { x > 2 })  # => [1, 2]
    """

  pub fn reject(list :: [element], predicate :: (element -> Bool)) -> [element] {
    :zig.ListCell.rejectFn(list, predicate)
  }

  @doc = """
    Folds the collection into a single value using an accumulator.
    The callback receives `(accumulator, element)` and returns
    the new accumulator.

    Dispatches through the Enumerable protocol — works with any
    collection type that implements Enumerable.

    ## Examples

        Enum.reduce([1, 2, 3], 0, fn(acc, x) { acc + x })  # => 6
        Enum.reduce([2, 3, 4], 1, fn(acc, x) { acc * x })   # => 24
    """

  pub fn reduce(list :: [i64], initial :: i64, callback :: (i64, i64 -> i64)) -> i64 {
    :zig.ListCell.enumReduceSimple(list, initial, callback)
  }

  @doc = """
    Folds map values into a single value using an accumulator.
    The callback receives `(accumulator, value)` and returns
    the new accumulator.

    ## Examples

        Enum.reduce_map(%{a: 1, b: 2, c: 3}, 0, fn(acc, val) { acc + val })
        # => 6
    """

  pub fn reduce_map(map :: %{Atom => i64}, initial :: i64, callback :: (i64, i64 -> i64)) -> i64 {
    :zig.MapCell.enumReduceValues(map, initial, callback)
  }

  @doc = """
    Applies the callback to each element for side effects.
    Returns the original list unchanged.

    ## Examples

        Enum.each([1, 2, 3], fn(x) { IO.puts(Integer.to_string(x)) })
    """

  pub fn each(list :: [element], callback :: (element -> element)) -> [element] {
    :zig.ListCell.eachFn(list, callback)
  }

  @doc = """
    Returns the first element for which the predicate returns true.
    Returns the default value if no element matches.

    ## Examples

        Enum.find([1, 2, 3, 4], 0, fn(x) { x > 2 })  # => 3
        Enum.find([1, 2], 0, fn(x) { x > 10 })        # => 0
    """

  pub fn find(list :: [element], default :: element, predicate :: (element -> Bool)) -> element {
    :zig.ListCell.findFn(list, default, predicate)
  }

  @doc = """
    Returns true if the predicate returns true for any element.

    ## Examples

        Enum.any?([1, 2, 3], fn(x) { x > 2 })   # => true
        Enum.any?([1, 2, 3], fn(x) { x > 10 })  # => false
    """

  pub fn any?(list :: [element], predicate :: (element -> Bool)) -> Bool {
    :zig.ListCell.anyFn(list, predicate)
  }

  @doc = """
    Returns true if the predicate returns true for all elements.

    ## Examples

        Enum.all?([2, 4, 6], fn(x) { x > 0 })   # => true
        Enum.all?([2, 4, 6], fn(x) { x > 3 })   # => false
    """

  pub fn all?(list :: [element], predicate :: (element -> Bool)) -> Bool {
    :zig.ListCell.allFn(list, predicate)
  }

  @doc = """
    Counts elements for which the predicate returns true.

    ## Examples

        Enum.count([1, 2, 3, 4, 5], fn(x) { x > 2 })  # => 3
    """

  pub fn count(list :: [element], predicate :: (element -> Bool)) -> i64 {
    :zig.ListCell.countFn(list, predicate)
  }

  @doc = """
    Returns the sum of all elements.

    ## Examples

        Enum.sum([1, 2, 3, 4])  # => 10
        Enum.sum([])             # => 0
    """

  pub fn sum(list :: [i64]) -> i64 {
    Enum.reduce(list, 0, fn(accumulator :: i64, element :: i64) -> i64 { accumulator + element })
  }

  @doc = """
    Returns the product of all elements.
    Returns 1 for an empty list.

    ## Examples

        Enum.product([2, 3, 4])  # => 24
        Enum.product([])         # => 1
    """

  pub fn product(list :: [i64]) -> i64 {
    Enum.reduce(list, 1, fn(accumulator :: i64, element :: i64) -> i64 { accumulator * element })
  }

  @doc = """
    Returns the maximum element.
    Returns 0 for an empty list.

    ## Examples

        Enum.max([3, 1, 4, 1, 5])  # => 5
    """

  pub fn max(list :: [i64]) -> i64 {
    :zig.ListCell.maxVal(list)
  }

  @doc = """
    Returns the minimum element.
    Returns 0 for an empty list.

    ## Examples

        Enum.min([3, 1, 4, 1, 5])  # => 1
    """

  pub fn min(list :: [i64]) -> i64 {
    :zig.ListCell.minVal(list)
  }

  @doc = """
    Sorts the list using a comparator function.
    The comparator returns true if the first argument should
    come before the second.

    ## Examples

        Enum.sort([3, 1, 2], fn(a, b) { a < b })  # => [1, 2, 3]
        Enum.sort([3, 1, 2], fn(a, b) { a > b })  # => [3, 2, 1]
    """

  pub fn sort(list :: [i64], comparator :: (i64, i64 -> Bool)) -> [i64] {
    :zig.ListCell.sortFn(list, comparator)
  }

  @doc = """
    Maps each element to a list and flattens the results
    into a single list.

    ## Examples

        Enum.flat_map([1, 2, 3], fn(x) { [x, x * 10] })
        # => [1, 10, 2, 20, 3, 30]
    """

  pub fn flat_map(list :: [i64], callback :: (i64 -> [i64])) -> [i64] {
    :zig.ListCell.flatMapFn(list, callback)
  }

  @doc = """
    Returns the first `count` elements from the list.

    If `count` exceeds the list length, returns the entire list.

    ## Examples

        Enum.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]
        Enum.take([1, 2], 5)            # => [1, 2]
        Enum.take([1, 2, 3], 0)         # => []
    """

  pub fn take(list :: [element], count :: i64) -> [element] {
    List.take(list, count)
  }

  @doc = """
    Drops the first `count` elements from the list.

    If `count` exceeds the list length, returns an empty list.

    ## Examples

        Enum.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]
        Enum.drop([1, 2], 5)            # => []
        Enum.drop([1, 2, 3], 0)         # => [1, 2, 3]
    """

  pub fn drop(list :: [element], count :: i64) -> [element] {
    List.drop(list, count)
  }

  @doc = """
    Reverses the order of elements in the list.

    ## Examples

        Enum.reverse([1, 2, 3])  # => [3, 2, 1]
        Enum.reverse([])          # => []
    """

  pub fn reverse(list :: [element]) -> [element] {
    List.reverse(list)
  }

  @doc = """
    Returns true if the list contains the given value.

    ## Examples

        Enum.member?([1, 2, 3], 2)  # => true
        Enum.member?([1, 2, 3], 5)  # => false
        Enum.member?([], 1)          # => false
    """

  pub fn member?(list :: [element], value :: element) -> Bool {
    List.contains?(list, value)
  }

  @doc = """
    Returns the element at the given zero-based index.
    Returns 0 if the index is out of bounds.

    ## Examples

        Enum.at([10, 20, 30], 1)  # => 20
        Enum.at([10, 20, 30], 0)  # => 10
    """

  pub fn at(list :: [element], index :: i64) -> element {
    List.at(list, index)
  }

  @doc = """
    Concatenates two lists into a single list.

    ## Examples

        Enum.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
        Enum.concat([], [1, 2])       # => [1, 2]
        Enum.concat([1, 2], [])       # => [1, 2]
    """

  pub fn concat(first :: [element], second :: [element]) -> [element] {
    List.concat(first, second)
  }

  @doc = """
    Returns a new list with duplicate values removed.
    Preserves the order of first occurrences.

    ## Examples

        Enum.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
        Enum.uniq([1, 1, 1])         # => [1]
    """

  pub fn uniq(list :: [element]) -> [element] {
    List.uniq(list)
  }

  @doc = """
    Returns true if the list has no elements.

    ## Examples

        Enum.empty?([])        # => true
        Enum.empty?([1, 2, 3]) # => false
    """

  pub fn empty?(list :: [element]) -> Bool {
    List.empty?(list)
  }
}
