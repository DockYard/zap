@doc = """
  Functions for enumerating and transforming collections.

  Enum provides higher-order functions that operate on any value
  implementing the `Enumerable` protocol. Functions that produce a
  collection materialize their result as a list.

  ## Examples

      Enum.map([1, 2, 3], fn(x) { x * 2 })       # => [2, 4, 6]
      Enum.filter(1..5, fn(x) { x > 2 })          # => [3, 4, 5]
      Enum.reduce(%{a: 1, b: 2}, 0, fn(acc, entry) {
        case entry {
          {_key, value} -> acc + value
        }
      })                                         # => 3
  """

pub struct Enum {
  @doc = """
    Converts an enumerable collection to a list.

    ## Examples

        Enum.to_list(1..3)   # => [1, 2, 3]
        Enum.to_list("ab")   # => ["a", "b"]
    """

  pub fn to_list(collection :: Enumerable(element)) -> [element] {
    collect_next(collection, [])
  }

  @doc = """
    Transforms each element by applying the callback function.

    ## Examples

        Enum.map([1, 2, 3], fn(x) { x * 2 })  # => [2, 4, 6]
        Enum.map(1..3, fn(x) { x * 2 })       # => [2, 4, 6]
    """

  pub fn map(collection :: Enumerable(element), callback :: (element -> mapped)) -> [mapped] {
    List.reverse(map_next(collection, callback, []))
  }

  @doc = """
    Keeps only elements for which the predicate returns true.

    ## Examples

        Enum.filter([1, 2, 3, 4], fn(x) { x > 2 })  # => [3, 4]
        Enum.filter(1..5, fn(x) { x > 3 })          # => [4, 5]
    """

  pub fn filter(collection :: Enumerable(element), predicate :: (element -> Bool)) -> [element] {
    List.reverse(filter_next(collection, predicate, []))
  }

  @doc = """
    Removes elements for which the predicate returns true.
    The opposite of `filter/2`.

    ## Examples

        Enum.reject([1, 2, 3, 4], fn(x) { x > 2 })  # => [1, 2]
    """

  pub fn reject(collection :: Enumerable(element), predicate :: (element -> Bool)) -> [element] {
    List.reverse(reject_next(collection, predicate, []))
  }

  @doc = """
    Folds the collection into a single value using an accumulator.
    The callback receives `(accumulator, element)` and returns
    the new accumulator.

    Dispatches through the Enumerable protocol — works with any
    collection type that implements Enumerable.

    ## Examples

        Enum.reduce([1, 2, 3], 0, fn(acc, x) { acc + x })  # => 6
        Enum.reduce(1..4, 0, fn(acc, x) { acc + x })       # => 10
    """

  pub fn reduce(collection :: Enumerable(element), initial :: accumulator, callback :: (accumulator, element -> accumulator)) -> accumulator {
    reduce_next(collection, initial, callback)
  }

  @doc = """
    Applies the callback to each element for side effects.
    Returns `nil` after the collection has been exhausted.

    ## Examples

        Enum.each([1, 2, 3], fn(x) { IO.puts(Integer.to_string(x)) })
    """

  pub fn each(collection :: Enumerable(element), callback :: (element -> result)) -> Nil {
    each_next(collection, callback)
  }

  @doc = """
    Returns the first element for which the predicate returns true.
    Returns the default value if no element matches.

    ## Examples

        Enum.find([1, 2, 3, 4], 0, fn(x) { x > 2 })  # => 3
        Enum.find(1..2, 0, fn(x) { x > 10 })         # => 0
    """

  pub fn find(collection :: Enumerable(element), default :: element, predicate :: (element -> Bool)) -> element {
    find_next(collection, default, predicate)
  }

  @doc = """
    Returns true if the predicate returns true for any element.

    ## Examples

        Enum.any?([1, 2, 3], fn(x) { x > 2 })   # => true
        Enum.any?(1..3, fn(x) { x > 10 })       # => false
    """

  pub fn any?(collection :: Enumerable(element), predicate :: (element -> Bool)) -> Bool {
    any_next(collection, predicate)
  }

  @doc = """
    Returns true if the predicate returns true for all elements.

    ## Examples

        Enum.all?([2, 4, 6], fn(x) { x > 0 })   # => true
        Enum.all?(1..3, fn(x) { x > 2 })        # => false
    """

  pub fn all?(collection :: Enumerable(element), predicate :: (element -> Bool)) -> Bool {
    all_next(collection, predicate)
  }

  @doc = """
    Counts elements for which the predicate returns true.

    ## Examples

        Enum.count([1, 2, 3, 4, 5], fn(x) { x > 2 })  # => 3
    """

  pub fn count(collection :: Enumerable(element), predicate :: (element -> Bool)) -> i64 {
    count_next(collection, predicate, 0)
  }

  @doc = """
    Returns the sum of all elements.

    ## Examples

        Enum.sum([1, 2, 3, 4])  # => 10
        Enum.sum([])             # => 0
    """

  pub fn sum(collection :: Enumerable(i64)) -> i64 {
    sum_next(collection, 0)
  }

  @doc = """
    Returns the product of all elements.
    Returns 1 for an empty collection.

    ## Examples

        Enum.product([2, 3, 4])  # => 24
        Enum.product([])         # => 1
    """

  pub fn product(collection :: Enumerable(i64)) -> i64 {
    product_next(collection, 1)
  }

  @doc = """
    Returns the maximum element.
    Returns 0 for an empty collection.

    ## Examples

        Enum.max([3, 1, 4, 1, 5])  # => 5
    """

  pub fn max(collection :: Enumerable(i64)) -> i64 {
    max_next(collection, 0, false)
  }

  @doc = """
    Returns the minimum element.
    Returns 0 for an empty collection.

    ## Examples

        Enum.min([3, 1, 4, 1, 5])  # => 1
    """

  pub fn min(collection :: Enumerable(i64)) -> i64 {
    min_next(collection, 0, false)
  }

  @doc = """
    Sorts the enumerable values using a comparator function.
    The comparator returns true if the first argument should
    come before the second.

    ## Examples

        Enum.sort([3, 1, 2], fn(a, b) { a < b })  # => [1, 2, 3]
        Enum.sort(1..3, fn(a, b) { a > b })       # => [3, 2, 1]
    """

  pub fn sort(collection :: Enumerable(element), comparator :: (element, element -> Bool)) -> [element] {
    sort_next(collection, comparator, [])
  }

  @doc = """
    Maps each element to a list and flattens the results
    into a single list.

    ## Examples

        Enum.flat_map([1, 2, 3], fn(x) { [x, x * 10] })
        # => [1, 10, 2, 20, 3, 30]
    """

  pub fn flat_map(collection :: Enumerable(element), callback :: (element -> [mapped])) -> [mapped] {
    List.reverse(flat_map_next(collection, callback, []))
  }

  @doc = """
    Returns the first `count` elements from the enumerable collection.

    If `count` exceeds the collection length, returns the entire
    collection as a list.

    ## Examples

        Enum.take([1, 2, 3, 4, 5], 3)  # => [1, 2, 3]
        Enum.take(1..5, 3)             # => [1, 2, 3]
        Enum.take([1, 2, 3], 0)        # => []
    """

  pub fn take(collection :: Enumerable(element), count :: i64) -> [element] {
    take_next(collection, count, [])
  }

  @doc = """
    Drops the first `count` elements from the enumerable collection
    and returns the remaining elements as a list.

    If `count` exceeds the collection length, returns an empty list.

    ## Examples

        Enum.drop([1, 2, 3, 4, 5], 2)  # => [3, 4, 5]
        Enum.drop(1..5, 2)             # => [3, 4, 5]
        Enum.drop([1, 2, 3], 0)        # => [1, 2, 3]
    """

  pub fn drop(collection :: Enumerable(element), count :: i64) -> [element] {
    drop_next(collection, count)
  }

  @doc = """
    Reverses the order of elements in the enumerable collection.

    ## Examples

        Enum.reverse([1, 2, 3])  # => [3, 2, 1]
        Enum.reverse(1..3)       # => [3, 2, 1]
    """

  pub fn reverse(collection :: Enumerable(element)) -> [element] {
    reverse_next(collection, [])
  }

  @doc = """
    Returns true if the enumerable collection contains the given value.

    ## Examples

        Enum.member?([1, 2, 3], 2)  # => true
        Enum.member?(1..3, 5)       # => false
        Enum.member?([], 1)         # => false
    """

  pub fn member?(collection :: Enumerable(element), value :: element) -> Bool {
    member_next(collection, value)
  }

  @doc = """
    Returns the element at the given zero-based index.
    Returns `default` if the index is out of bounds.

    ## Examples

        Enum.at([10, 20, 30], 1, 0)  # => 20
        Enum.at(["a"], 2, "none")  # => "none"
    """

  pub fn at(collection :: Enumerable(element), index :: i64, default :: element) -> element {
    at_next(collection, index, 0, default)
  }

  @doc = """
    Concatenates two enumerable collections into a single list.

    ## Examples

        Enum.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
        Enum.concat(1..2, 3..4)      # => [1, 2, 3, 4]
    """

  pub fn concat(first :: Enumerable(element), second :: Enumerable(element)) -> [element] {
    List.concat(collect_next(first, []), collect_next(second, []))
  }

  @doc = """
    Returns a new list with duplicate values removed.
    Preserves the order of first occurrences.

    ## Examples

        Enum.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
        Enum.uniq(1..3)             # => [1, 2, 3]
    """

  pub fn uniq(collection :: Enumerable(element)) -> [element] {
    uniq_next(collection, [])
  }

  @doc = """
    Returns true if the enumerable collection has no elements.

    ## Examples

        Enum.empty?([])    # => true
        Enum.empty?(1..3)  # => false
    """

  pub fn empty?(collection :: Enumerable(element)) -> Bool {
    case Enumerable.next(collection) {
      {:done, _, _} -> true
      {:cont, _, _} -> false
    }
  }

  fn collect_next(state :: Enumerable(element), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> List.reverse(accumulator)
      {:cont, value, next_state} -> collect_next(next_state, List.prepend(accumulator, value))
    }
  }

  fn map_next(state :: Enumerable(element), callback :: (element -> mapped), accumulator :: [mapped]) -> [mapped] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> map_next(next_state, callback, List.prepend(accumulator, callback(value)))
    }
  }

  fn filter_next(state :: Enumerable(element), predicate :: (element -> Bool), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} ->
        if predicate(value) {
          filter_next(next_state, predicate, List.prepend(accumulator, value))
        } else {
          filter_next(next_state, predicate, accumulator)
        }
    }
  }

  fn reject_next(state :: Enumerable(element), predicate :: (element -> Bool), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} ->
        if predicate(value) {
          reject_next(next_state, predicate, accumulator)
        } else {
          reject_next(next_state, predicate, List.prepend(accumulator, value))
        }
    }
  }

  fn reduce_next(state :: Enumerable(element), accumulator :: accumulator_type, callback :: (accumulator_type, element -> accumulator_type)) -> accumulator_type {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> reduce_next(next_state, callback(accumulator, value), callback)
    }
  }

  fn each_next(state :: Enumerable(element), callback :: (element -> result)) -> Nil {
    case Enumerable.next(state) {
      {:done, _, _} -> nil
      {:cont, value, next_state} -> each_continue(callback(value), next_state, callback)
    }
  }

  fn each_continue(_ignored_result :: result, next_state :: Enumerable(element), callback :: (element -> result)) -> Nil {
    each_next(next_state, callback)
  }

  fn count_next(state :: Enumerable(element), predicate :: (element -> Bool), total :: i64) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> total
      {:cont, value, next_state} ->
        if predicate(value) {
          count_next(next_state, predicate, total + 1)
        } else {
          count_next(next_state, predicate, total)
        }
    }
  }

  fn sum_next(state :: Enumerable(i64), total :: i64) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> total
      {:cont, value, next_state} -> sum_next(next_state, total + value)
    }
  }

  fn product_next(state :: Enumerable(i64), product :: i64) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> product
      {:cont, value, next_state} -> product_next(next_state, product * value)
    }
  }

  fn member_next(state :: Enumerable(element), expected :: element) -> Bool {
    case Enumerable.next(state) {
      {:done, _, _} -> false
      {:cont, value, next_state} ->
        if value == expected {
          true
        } else {
          member_next(next_state, expected)
        }
    }
  }

  fn find_next(state :: Enumerable(element), default :: element, predicate :: (element -> Bool)) -> element {
    case Enumerable.next(state) {
      {:done, _, _} -> default
      {:cont, value, next_state} ->
        if predicate(value) {
          value
        } else {
          find_next(next_state, default, predicate)
        }
    }
  }

  fn any_next(state :: Enumerable(element), predicate :: (element -> Bool)) -> Bool {
    case Enumerable.next(state) {
      {:done, _, _} -> false
      {:cont, value, next_state} ->
        if predicate(value) {
          true
        } else {
          any_next(next_state, predicate)
        }
    }
  }

  fn all_next(state :: Enumerable(element), predicate :: (element -> Bool)) -> Bool {
    case Enumerable.next(state) {
      {:done, _, _} -> true
      {:cont, value, next_state} ->
        if predicate(value) {
          all_next(next_state, predicate)
        } else {
          false
        }
    }
  }

  fn max_next(state :: Enumerable(i64), current :: i64, has_value :: Bool) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> current
      {:cont, value, next_state} ->
        if has_value {
          if value > current {
            max_next(next_state, value, true)
          } else {
            max_next(next_state, current, true)
          }
        } else {
          max_next(next_state, value, true)
        }
    }
  }

  fn min_next(state :: Enumerable(i64), current :: i64, has_value :: Bool) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> current
      {:cont, value, next_state} ->
        if has_value {
          if value < current {
            min_next(next_state, value, true)
          } else {
            min_next(next_state, current, true)
          }
        } else {
          min_next(next_state, value, true)
        }
    }
  }

  fn sort_next(state :: Enumerable(element), comparator :: (element, element -> Bool), sorted :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> sorted
      {:cont, value, next_state} -> sort_next(next_state, comparator, insert_sorted(sorted, value, comparator))
    }
  }

  fn insert_sorted([] :: [element], value :: element, comparator :: (element, element -> Bool)) -> [element] {
    [value]
  }

  fn insert_sorted([head | tail] :: [element], value :: element, comparator :: (element, element -> Bool)) -> [element] {
    if comparator(value, head) {
      [value | [head | tail]]
    } else {
      [head | insert_sorted(tail, value, comparator)]
    }
  }

  fn flat_map_next(state :: Enumerable(element), callback :: (element -> [mapped]), accumulator :: [mapped]) -> [mapped] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> flat_map_next(next_state, callback, prepend_each(callback(value), accumulator))
    }
  }

  fn prepend_each(list :: [element], accumulator :: [element]) -> [element] {
    case list {
      [] -> accumulator
      [head | tail] -> prepend_each(tail, List.prepend(accumulator, head))
    }
  }

  fn take_next(state :: Enumerable(element), count :: i64, accumulator :: [element]) -> [element] {
    if count <= 0 {
      List.reverse(accumulator)
    } else {
      case Enumerable.next(state) {
        {:done, _, _} -> List.reverse(accumulator)
        {:cont, value, next_state} -> take_next(next_state, count - 1, List.prepend(accumulator, value))
      }
    }
  }

  fn drop_next(state :: Enumerable(element), count :: i64) -> [element] {
    if count <= 0 {
      collect_next(state, [])
    } else {
      case Enumerable.next(state) {
        {:done, _, _} -> []
        {:cont, _, next_state} -> drop_next(next_state, count - 1)
      }
    }
  }

  fn reverse_next(state :: Enumerable(element), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> reverse_next(next_state, List.prepend(accumulator, value))
    }
  }

  fn at_next(state :: Enumerable(element), target_index :: i64, current_index :: i64, default :: element) -> element {
    case Enumerable.next(state) {
      {:done, _, _} -> default
      {:cont, value, next_state} ->
        if current_index == target_index {
          value
        } else {
          at_next(next_state, target_index, current_index + 1, default)
        }
    }
  }

  fn uniq_next(state :: Enumerable(element), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> List.reverse(accumulator)
      {:cont, value, next_state} ->
        if List.contains?(accumulator, value) {
          uniq_next(next_state, accumulator)
        } else {
          uniq_next(next_state, List.prepend(accumulator, value))
        }
    }
  }
}
