pub impl Enumerable for List {
  @doc = """
    Reduces a list using a callback with halt/cont control flow.

    The callback receives the accumulator and current element, and
    returns {:cont, new_acc} to continue or {:halt, new_acc} to
    stop early.

    Returns {Atom, accumulator} where the atom indicates whether
    the list was fully traversed (:cont) or halted early (:halt).

    ## Examples

        Enumerable.reduce([1, 2, 3], {:cont, 0}, fn(acc, x) { {:cont, acc + x} })
        # => {:cont, 6}
  """

  pub fn reduce(list :: [member], acc :: acc, callback :: (acc, member -> {Atom, acc})) -> {Atom, acc} {
    :zig.ListCell.reduceHaltCont(list, acc, callback)
  }
}
