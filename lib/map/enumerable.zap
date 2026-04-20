pub impl Enumerable for Map {
  @doc = """
    Reduces a map's values using a callback with halt/cont control flow.

    The callback receives the accumulator and current value, and
    returns {:cont, new_acc} to continue or {:halt, new_acc} to
    stop early.

    ## Examples

        Enumerable.reduce(%{a: 1, b: 2, c: 3}, {:cont, 0}, fn(acc, val) { {:cont, acc + val} })
        # => {:cont, 6}
  """

  pub fn reduce(map :: Map, acc, callback :: (acc, member -> {Atom, acc})) -> {Atom, acc} {
    :zig.MapCell.reduceHaltCont(map, acc, callback)
  }
}
