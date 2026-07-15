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

  pub fn to_list(collection :: unique Enumerable(element)) -> [element] {
    collect_next(collection, [])
  }

  @doc = """
    Transforms each element by applying the callback function.

    ## Examples

        Enum.map([1, 2, 3], fn(x) { x * 2 })  # => [2, 4, 6]
        Enum.map(1..3, fn(x) { x * 2 })       # => [2, 4, 6]
    """

  pub fn map(collection :: unique Enumerable(element), callback :: fn(element) -> mapped) -> [mapped] {
    List.reverse(map_next(collection, callback, []))
  }

  @doc = """
    Keeps only elements for which the predicate returns true.

    ## Examples

        Enum.filter([1, 2, 3, 4], fn(x) { x > 2 })  # => [3, 4]
        Enum.filter(1..5, fn(x) { x > 3 })          # => [4, 5]
    """

  pub fn filter(collection :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> [element] {
    List.reverse(filter_next(collection, predicate, []))
  }

  @doc = """
    Removes elements for which the predicate returns true.
    The opposite of `filter/2`.

    ## Examples

        Enum.reject([1, 2, 3, 4], fn(x) { x > 2 })  # => [1, 2]
    """

  pub fn reject(collection :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> [element] {
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

  pub fn reduce(collection :: unique Enumerable(element), initial :: accumulator, callback :: fn(accumulator, element) -> accumulator) -> accumulator {
    reduce_next(collection, initial, callback)
  }

  @doc = """
    Folds the collection with early termination. The callback receives
    `(accumulator, element)` and returns `{:cont, accumulator}` to keep
    folding or `{:halt, accumulator}` to stop immediately; the
    accumulator carried by `:halt` becomes the result.

    On `:halt` the remaining iteration state is disposed through
    `Enumerable.dispose/1`, releasing any cursor resources without
    walking the rest of the collection — the same short-circuit
    discipline as `find/3` and `any?/2`.

    Follows Elixir's `Enum.reduce_while/3` semantics, with this
    module's `(accumulator, element)` callback argument order.

    ## Examples

        Enum.reduce_while([1, 2, 3, 4, 5], 0, fn(acc, x) {
          if acc + x > 5 { {:halt, acc} } else { {:cont, acc + x} }
        })
        # => 3

        Enum.reduce_while(1..4, 0, fn(acc, x) { {:cont, acc + x} })
        # => 10
    """

  pub fn reduce_while(collection :: unique Enumerable(element), initial :: accumulator, callback :: fn(accumulator, element) -> {Atom, accumulator}) -> accumulator {
    reduce_while_next(collection, initial, callback)
  }

  @doc = """
    Applies the callback to each element for side effects.
    Returns `nil` after the collection has been exhausted.

    ## Examples

        Enum.each([1, 2, 3], fn(x) { IO.puts(Integer.to_string(x)) })
    """

  pub fn each(collection :: unique Enumerable(element), callback :: fn(element) -> result) -> Nil {
    each_next(collection, callback)
  }

  @doc = """
    Returns the first element for which the predicate returns true.
    Returns the default value if no element matches.

    ## Examples

        Enum.find([1, 2, 3, 4], 0, fn(x) { x > 2 })  # => 3
        Enum.find(1..2, 0, fn(x) { x > 10 })         # => 0
    """

  pub fn find(collection :: unique Enumerable(element), default :: element, predicate :: fn(element) -> Bool) -> element {
    find_next(collection, default, predicate)
  }

  @doc = """
    Returns true if the predicate returns true for any element.

    ## Examples

        Enum.any?([1, 2, 3], fn(x) { x > 2 })   # => true
        Enum.any?(1..3, fn(x) { x > 10 })       # => false
    """

  pub fn any?(collection :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> Bool {
    any_next(collection, predicate)
  }

  @doc = """
    Returns true if the predicate returns true for all elements.

    ## Examples

        Enum.all?([2, 4, 6], fn(x) { x > 0 })   # => true
        Enum.all?(1..3, fn(x) { x > 2 })        # => false
    """

  pub fn all?(collection :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> Bool {
    all_next(collection, predicate)
  }

  @doc = """
    Counts elements for which the predicate returns true.

    ## Examples

        Enum.count([1, 2, 3, 4, 5], fn(x) { x > 2 })  # => 3
    """

  pub fn count(collection :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> i64 {
    count_next(collection, predicate, 0)
  }

  @doc = """
    Returns the sum of all elements.
    Type-specific clauses handle integer lists, floating-point lists,
    and ranges.

    ## Examples

        Enum.sum([1, 2, 3, 4])  # => 10
        Enum.sum([])             # => 0
        Enum.sum(1..10)          # => 55
    """

  pub fn sum(collection :: unique Enumerable(i64)) -> i64 {
    sum_next(collection, 0)
  }

  pub fn sum(list :: List(i64)) -> i64 {
    :zig.List.sum(list)
  }

  pub fn sum(list :: List(f64)) -> f64 {
    :zig.List.sum(list)
  }

  pub fn sum(range :: Range) -> i64 {
    n = range_count(range)
    n * (range.start + range_last(range)) / 2
  }

  @doc = """
    Returns the product of all elements.
    Returns 1 for an empty collection.

    ## Examples

        Enum.product([2, 3, 4])  # => 24
        Enum.product([])         # => 1
    """

  pub fn product(collection :: unique Enumerable(i64)) -> i64 {
    product_next(collection, 1)
  }

  @doc = """
    Returns the maximum element.
    Returns 0 for an empty collection.

    ## Examples

        Enum.max([3, 1, 4, 1, 5])  # => 5
    """

  pub fn max(collection :: unique Enumerable(i64)) -> i64 {
    max_next(collection, 0, false)
  }

  @doc = """
    Returns the minimum element.
    Returns 0 for an empty collection.

    ## Examples

        Enum.min([3, 1, 4, 1, 5])  # => 1
    """

  pub fn min(collection :: unique Enumerable(i64)) -> i64 {
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

  pub fn sort(collection :: unique Enumerable(element), comparator :: fn(element, element) -> Bool) -> [element] {
    merge_sort(collect_next(collection, []), comparator)
  }

  @doc = """
    Maps each element to a list and flattens the results
    into a single list.

    ## Examples

        Enum.flat_map([1, 2, 3], fn(x) { [x, x * 10] })
        # => [1, 10, 2, 20, 3, 30]
    """

  pub fn flat_map(collection :: unique Enumerable(element), callback :: fn(element) -> [mapped]) -> [mapped] {
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

  pub fn take(collection :: unique Enumerable(element), count :: i64) -> [element] {
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

  pub fn drop(collection :: unique Enumerable(element), count :: i64) -> [element] {
    drop_next(collection, count)
  }

  @doc = """
    Reverses the order of elements in the enumerable collection.

    ## Examples

        Enum.reverse([1, 2, 3])  # => [3, 2, 1]
        Enum.reverse(1..3)       # => [3, 2, 1]
    """

  pub fn reverse(collection :: unique Enumerable(element)) -> [element] {
    reverse_next(collection, [])
  }

  @doc = """
    Returns true if the enumerable collection contains the given value.

    ## Examples

        Enum.member?([1, 2, 3], 2)  # => true
        Enum.member?(1..3, 5)       # => false
        Enum.member?([], 1)         # => false
    """

  pub fn member?(collection :: unique Enumerable(element), value :: element) -> Bool {
    member_next(collection, value)
  }

  @doc = """
    Returns the element at the given zero-based index.
    Returns `default` if the index is out of bounds.

    ## Examples

        Enum.at([10, 20, 30], 1, 0)  # => 20
        Enum.at(["a"], 2, "none")  # => "none"
    """

  pub fn at(collection :: unique Enumerable(element), index :: i64, default :: element) -> element {
    at_next(collection, index, 0, default)
  }

  @doc = """
    Concatenates two enumerable collections into a single list.

    ## Examples

        Enum.concat([1, 2], [3, 4])  # => [1, 2, 3, 4]
        Enum.concat(1..2, 3..4)      # => [1, 2, 3, 4]
    """

  pub fn concat(first :: unique Enumerable(element), second :: unique Enumerable(element)) -> [element] {
    List.concat(collect_next(first, []), collect_next(second, []))
  }

  @doc = """
    Returns a new list with duplicate values removed.
    Preserves the order of first occurrences.

    ## Examples

        Enum.uniq([1, 2, 2, 3, 1])  # => [1, 2, 3]
        Enum.uniq(1..3)             # => [1, 2, 3]
    """

  pub fn uniq(collection :: unique Enumerable(element)) -> [element] {
    uniq_next(collection, [])
  }

  @doc = """
    Returns true if the enumerable collection has no elements.

    ## Examples

        Enum.empty?([])    # => true
        Enum.empty?(1..3)  # => false
    """

  pub fn empty?(collection :: unique Enumerable(element)) -> Bool {
    case Enumerable.next(collection) {
      {:done, _, _} -> true
      {:cont, _, next_state} -> dispose_and_return(next_state, false)
    }
  }

  @doc = """
    Returns the first element of the collection. Panics on an empty
    collection — use `first/2` to supply a default for that case.

    ## Examples

        Enum.first([10, 20, 30])  # => 10
        Enum.first(5..15)         # => 5
    """

  pub fn first(collection :: unique Enumerable(element)) -> element {
    case Enumerable.next(collection) {
      {:done, _, _} -> panic("Enum.first/1 called on an empty collection")
      {:cont, value, next_state} -> dispose_and_return(next_state, value)
    }
  }

  @doc = """
    Returns the first element of the collection, or `default` when
    the collection is empty.

    ## Examples

        Enum.first([10, 20], -1)  # => 10
        Enum.first([], -1)        # => -1
    """

  pub fn first(collection :: unique Enumerable(element), default :: element) -> element {
    case Enumerable.next(collection) {
      {:done, _, _} -> default
      {:cont, value, next_state} -> dispose_and_return(next_state, value)
    }
  }

  @doc = """
    Returns the last element of the collection. Panics on an empty
    collection — use `last/2` to supply a default for that case.
    The generic implementation walks the collection; `Range` and
    other types with closed-form last-element formulas can override
    via type-specific clauses for an O(1) result.

    ## Examples

        Enum.last([10, 20, 30])  # => 30
        Enum.last(1..10:3)       # => 10
        Enum.last(10..1)         # => 1
    """

  pub fn last(collection :: unique Enumerable(element)) -> element {
    case Enumerable.next(collection) {
      {:done, _, _} -> panic("Enum.last/1 called on an empty collection")
      {:cont, value, next_state} -> last_walk(next_state, value)
    }
  }

  @doc = """
    Returns the last element of the collection, or `default` when
    the collection is empty.
    The `Range` clause returns the last range value in O(1) and
    ignores the default because ranges are never empty.
    """

  pub fn last(collection :: unique Enumerable(element), default :: element) -> element {
    case Enumerable.next(collection) {
      {:done, _, _} -> default
      {:cont, value, next_state} -> last_walk(next_state, value)
    }
  }

  pub fn last(range :: Range) -> i64 {
    range_last(range)
  }

  pub fn last(range :: Range, _default :: i64) -> i64 {
    range_last(range)
  }

  fn last_walk(state :: unique Enumerable(element), seen :: element) -> element {
    case Enumerable.next(state) {
      {:done, _, _} -> seen
      {:cont, value, next_state} -> last_walk(next_state, value)
    }
  }

  fn range_last(range :: Range) -> i64 {
    n = range_count(range) - 1
    if range.start <= range.end {
      range.start + range.step * n
    } else {
      range.start - range.step * n
    }
  }

  fn range_count(range :: Range) -> i64 {
    diff = if range.start <= range.end {
      range.end - range.start
    } else {
      range.start - range.end
    }
    diff / range.step + 1
  }

  @doc = """
    Returns the number of elements in the collection. The generic
    implementation walks the entire collection; the `Range` clause
    computes `|end - start| / step + 1` in O(1).

    `Enum.count/2` (with a predicate) counts only elements that
    satisfy the predicate.

    ## Examples

        Enum.count([10, 20, 30])  # => 3
        Enum.count(1..10:3)       # => 4
    """

  pub fn count(collection :: unique Enumerable(element)) -> i64 {
    count_total_next(collection, 0)
  }

  pub fn count(range :: Range) -> i64 {
    range_count(range)
  }

  fn count_total_next(state :: unique Enumerable(element), total :: i64) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> total
      {:cont, _, next_state} -> count_total_next(next_state, total + 1)
    }
  }

  fn collect_next(state :: unique Enumerable(element), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> List.reverse(accumulator)
      {:cont, value, next_state} -> collect_next(next_state, List.prepend(accumulator, value))
    }
  }

  fn map_next(state :: unique Enumerable(element), callback :: fn(element) -> mapped, accumulator :: [mapped]) -> [mapped] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> map_next(next_state, callback, List.prepend(accumulator, callback(value)))
    }
  }

  fn filter_next(state :: unique Enumerable(element), predicate :: fn(element) -> Bool, accumulator :: [element]) -> [element] {
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

  fn reject_next(state :: unique Enumerable(element), predicate :: fn(element) -> Bool, accumulator :: [element]) -> [element] {
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

  fn reduce_next(state :: unique Enumerable(element), accumulator :: accumulator_type, callback :: fn(accumulator_type, element) -> accumulator_type) -> accumulator_type {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> reduce_next(next_state, callback(accumulator, value), callback)
    }
  }

  fn reduce_while_next(state :: unique Enumerable(element), accumulator :: accumulator_type, callback :: fn(accumulator_type, element) -> {Atom, accumulator_type}) -> accumulator_type {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} ->
        case callback(accumulator, value) {
          {:cont, continued_accumulator} -> reduce_while_next(next_state, continued_accumulator, callback)
          {:halt, halted_accumulator} -> dispose_and_return(next_state, halted_accumulator)
        }
    }
  }

  fn each_next(state :: unique Enumerable(element), callback :: fn(element) -> result) -> Nil {
    case Enumerable.next(state) {
      {:done, _, _} -> nil
      {:cont, value, next_state} ->
        {
          callback(value)
          each_next(next_state, callback)
        }
    }
  }

  fn count_next(state :: unique Enumerable(element), predicate :: fn(element) -> Bool, total :: i64) -> i64 {
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

  fn sum_next(state :: unique Enumerable(i64), total :: i64) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> total
      {:cont, value, next_state} -> sum_next(next_state, total + value)
    }
  }

  fn product_next(state :: unique Enumerable(i64), product :: i64) -> i64 {
    case Enumerable.next(state) {
      {:done, _, _} -> product
      {:cont, value, next_state} -> product_next(next_state, product * value)
    }
  }

  fn member_next(state :: unique Enumerable(element), expected :: element) -> Bool {
    case Enumerable.next(state) {
      {:done, _, _} -> false
      {:cont, value, next_state} ->
        if value == expected {
          dispose_and_return(next_state, true)
        } else {
          member_next(next_state, expected)
        }
    }
  }

  fn find_next(state :: unique Enumerable(element), default :: element, predicate :: fn(element) -> Bool) -> element {
    case Enumerable.next(state) {
      {:done, _, _} -> default
      {:cont, value, next_state} ->
        if predicate(value) {
          dispose_and_return(next_state, value)
        } else {
          find_next(next_state, default, predicate)
        }
    }
  }

  fn any_next(state :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> Bool {
    case Enumerable.next(state) {
      {:done, _, _} -> false
      {:cont, value, next_state} ->
        if predicate(value) {
          dispose_and_return(next_state, true)
        } else {
          any_next(next_state, predicate)
        }
    }
  }

  fn all_next(state :: unique Enumerable(element), predicate :: fn(element) -> Bool) -> Bool {
    case Enumerable.next(state) {
      {:done, _, _} -> true
      {:cont, value, next_state} ->
        if predicate(value) {
          all_next(next_state, predicate)
        } else {
          dispose_and_return(next_state, false)
        }
    }
  }

  fn max_next(state :: unique Enumerable(i64), current :: i64, has_value :: Bool) -> i64 {
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

  fn min_next(state :: unique Enumerable(i64), current :: i64, has_value :: Bool) -> i64 {
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

  fn merge_sort(values :: [element], comparator :: fn(element, element) -> Bool) -> [element] {
    length = List.length(values)
    if length <= 1 {
      values
    } else {
      midpoint = length / 2
      left = List.take(values, midpoint)
      right = List.drop(values, midpoint)
      merge_sorted(merge_sort(left, comparator), merge_sort(right, comparator), comparator, [])
    }
  }

  fn merge_sorted(left :: [element], right :: [element], comparator :: fn(element, element) -> Bool, accumulator :: [element]) -> [element] {
    case left {
      [] -> List.concat(List.reverse(accumulator), right)
      [left_head | left_tail] ->
        case right {
          [] -> List.concat(List.reverse(accumulator), left)
          [right_head | right_tail] ->
            if comparator(right_head, left_head) {
              merge_sorted(left, right_tail, comparator, List.prepend(accumulator, right_head))
            } else {
              merge_sorted(left_tail, right, comparator, List.prepend(accumulator, left_head))
            }
        }
    }
  }

  fn flat_map_next(state :: unique Enumerable(element), callback :: fn(element) -> [mapped], accumulator :: [mapped]) -> [mapped] {
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

  fn take_next(state :: unique Enumerable(element), count :: i64, accumulator :: [element]) -> [element] {
    if count <= 0 {
      dispose_and_return(state, List.reverse(accumulator))
    } else {
      case Enumerable.next(state) {
        {:done, _, _} -> List.reverse(accumulator)
        {:cont, value, next_state} ->
          if count == 1 {
            dispose_and_return(next_state, List.reverse(List.prepend(accumulator, value)))
          } else {
            take_next(next_state, count - 1, List.prepend(accumulator, value))
          }
      }
    }
  }

  fn drop_next(state :: unique Enumerable(element), count :: i64) -> [element] {
    if count <= 0 {
      collect_next(state, [])
    } else {
      case Enumerable.next(state) {
        {:done, _, _} -> []
        {:cont, _, next_state} -> drop_next(next_state, count - 1)
      }
    }
  }

  fn reverse_next(state :: unique Enumerable(element), accumulator :: [element]) -> [element] {
    case Enumerable.next(state) {
      {:done, _, _} -> accumulator
      {:cont, value, next_state} -> reverse_next(next_state, List.prepend(accumulator, value))
    }
  }

  fn at_next(state :: unique Enumerable(element), target_index :: i64, current_index :: i64, default :: element) -> element {
    case Enumerable.next(state) {
      {:done, _, _} -> default
      {:cont, value, next_state} ->
        if current_index == target_index {
          dispose_and_return(next_state, value)
        } else {
          at_next(next_state, target_index, current_index + 1, default)
        }
    }
  }

  fn uniq_next(state :: unique Enumerable(element), accumulator :: [element]) -> [element] {
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

  fn dispose_and_return(state :: unique Enumerable(element), value :: result) -> result {
    Enumerable.dispose(state)
    value
  }
}
