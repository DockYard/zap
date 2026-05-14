@native_type = "list"

@doc = """
  A flat-buffer sequence of elements.

  `List(t)` is backed by the runtime's single-allocation contiguous
  buffer. Lists support O(1) indexed reads, copy-on-write mutation, and
  ARC-managed lifetime for elements that own runtime resources.
  """

pub struct List {
  @doc = """
    Allocate a list of `size` elements, each initialized to `init`.
    """

  pub fn new_filled(size :: i64, init :: t) -> List(t) {
    :zig.List.new_filled(size, init)
  }

  @doc = """
    Allocate an empty list with at least `initial_capacity` reserved slots.
    """

  pub fn new_empty(initial_capacity :: i64) -> List(t) {
    :zig.List.new_empty(initial_capacity)
  }

  @doc = """
    Returns `true` when the list has no elements.
    """

  pub fn empty?(list :: List(t)) -> Bool {
    :zig.List.isEmpty(list)
  }

  @doc = """
    Returns the number of elements in the list.
    """

  pub fn length(list :: List(t)) -> i64 {
    :zig.List.length(list)
  }

  @doc = """
    Returns the list's reserved capacity.
    """

  pub fn capacity(list :: List(t)) -> i64 {
    :zig.List.capacity(list)
  }

  @doc = """
    Returns the element at `index`.
    """

  pub fn get(list :: List(t), index :: i64) -> t {
    :zig.List.get(list, index)
  }

  @doc = """
    Returns the element at `index`.
    """

  pub fn at(list :: List(t), index :: i64) -> t {
    List.get(list, index)
  }

  @doc = """
    Returns a list with `value` stored at `index`.
    """

  pub fn set(list :: List(t), index :: i64, value :: t) -> List(t) {
    :zig.List.set(list, index, value)
  }

  @doc = """
    Returns a list with `value` added to the end.
    """

  pub fn push(list :: List(t), value :: t) -> List(t) {
    :zig.List.push(list, value)
  }

  @doc = """
    Removes the last element and returns `{list, value}`.
    """

  pub fn pop(list :: List(t)) -> {List(t), t} {
    value = List.last(list)
    next = :zig.List.pop(list)
    {next, value}
  }

  @doc = """
    Concatenates two lists.
    """

  pub fn append(first :: List(t), second :: List(t)) -> List(t) {
    :zig.List.append(first, second)
  }

  @doc = """
    Concatenates two lists.
    """

  pub fn concat(first :: List(t), second :: List(t)) -> List(t) {
    List.append(first, second)
  }

  @doc = """
    Returns the first element, or the element type's default for an empty list.
    """

  pub fn head(list :: List(t)) -> t {
    :zig.List.getHead(list)
  }

  @doc = """
    Returns all elements after the first as a new list.
    """

  pub fn tail(list :: List(t)) -> List(t) {
    :zig.List.getTail(list)
  }

  @doc = """
    Returns `value` followed by the contents of `list`.
    """

  pub fn prepend(list :: List(t), value :: t) -> List(t) {
    :zig.List.cons(value, list)
  }

  @doc = """
    Returns the last element, or the element type's default for an empty list.
    """

  pub fn last(list :: List(t)) -> t {
    :zig.List.last(list)
  }

  @doc = """
    Returns `true` when `value` is present in the list.
    """

  pub fn contains?(list :: List(t), value :: t) -> Bool {
    :zig.List.contains(list, value)
  }

  @doc = """
    Returns a new list with elements in reverse order.
    """

  pub fn reverse(list :: List(t)) -> List(t) {
    :zig.List.reverse(list)
  }

  @doc = """
    Returns the first `count` elements.
    """

  pub fn take(list :: List(t), count :: i64) -> List(t) {
    :zig.List.take(list, count)
  }

  @doc = """
    Returns the list after dropping the first `count` elements.
    """

  pub fn drop(list :: List(t), count :: i64) -> List(t) {
    :zig.List.drop(list, count)
  }

  @doc = """
    Returns a list with duplicate values removed.
    """

  pub fn uniq(list :: List(t)) -> List(t) {
    :zig.List.uniq(list)
  }

  @doc = """
    Transforms each element with `callback`.
    """

  pub fn map(list :: List(t), callback :: (t -> mapped)) -> List(mapped) {
    map_walk(list, callback, 0, List.length(list), List.new_empty(List.length(list)))
  }

  @doc = """
    Keeps elements for which `predicate` returns true.
    """

  pub fn filter(list :: List(t), predicate :: (t -> Bool)) -> List(t) {
    filter_walk(list, predicate, 0, List.length(list), List.new_empty(List.length(list)))
  }

  @doc = """
    Folds the list from left to right.
    """

  pub fn reduce(list :: List(t), initial :: accumulator, callback :: (accumulator, t -> accumulator)) -> accumulator {
    reduce_walk(list, callback, 0, List.length(list), initial)
  }

  @doc = """
    Returns the first element. Raises when the list is empty.
    """

  pub fn head!(list :: List(t)) -> t {
    if List.empty?(list) {
      raise("List.head! called on empty list")
    } else {
      List.head(list)
    }
  }

  @doc = """
    Returns the last element. Raises when the list is empty.
    """

  pub fn last!(list :: List(t)) -> t {
    if List.empty?(list) {
      raise("List.last! called on empty list")
    } else {
      List.last(list)
    }
  }

  @doc = """
    Returns the element at `index`. Raises when `index` is out of bounds.
    """

  pub fn at!(list :: List(t), index :: i64) -> t {
    if index >= 0 and index < List.length(list) {
      List.at(list, index)
    } else {
      raise("List.at! index out of bounds")
    }
  }

  fn map_walk(list :: List(t), callback :: (t -> mapped), index :: i64, total :: i64, accumulator :: List(mapped)) -> List(mapped) {
    if index < total {
      map_walk(list, callback, index + 1, total, List.push(accumulator, callback(List.get(list, index))))
    } else {
      accumulator
    }
  }

  fn filter_walk(list :: List(t), predicate :: (t -> Bool), index :: i64, total :: i64, accumulator :: List(t)) -> List(t) {
    if index < total {
      value = List.get(list, index)
      next_accumulator = if predicate(value) {
        List.push(accumulator, value)
      } else {
        accumulator
      }
      filter_walk(list, predicate, index + 1, total, next_accumulator)
    } else {
      accumulator
    }
  }

  fn reduce_walk(list :: List(t), callback :: (accumulator, t -> accumulator), index :: i64, total :: i64, current :: accumulator) -> accumulator {
    if index < total {
      reduce_walk(list, callback, index + 1, total, callback(current, List.get(list, index)))
    } else {
      current
    }
  }
}
