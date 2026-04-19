pub impl Enumerable for List {
  @doc = """
    Applies the callback to each element of the list, returning a new
    list with the transformed values.

    ## Examples

        Enumerable.each([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
        # => [2, 4, 6]
  """

  pub fn each(list :: [member], callback :: (member -> member)) -> [member] {
    :zig.ListCell.eachFn(list, callback)
  }
}
