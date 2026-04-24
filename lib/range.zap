@doc = """
  A range of integers with a start, end, and step.

  Ranges are created with the `..` syntax:

      1..10       # start: 1, end: 10, step: 1
      1..10:3     # start: 1, end: 10, step: 3
      100..1      # reverse range, iterates downward
      -10..10     # negative start

  Ranges are direction-aware. The step is always a positive
  magnitude — the direction is determined by comparing start
  and end.

  ## Examples

      r = 1..10
      r.start   # => 1
      r.end     # => 10
      r.step    # => 1

      5 in 1..10        # => true
      3 in 1..10:2      # => false (only 1, 3, 5, 7, 9)
  """

pub struct Range {
  start :: i64
  end :: i64
  step :: i64 = 1

  @doc = """
    Converts a range to a list of integers.

    The direction is determined by comparing start and end.
    Step is always a positive magnitude.

    ## Examples

        Range.to_list(1..5)       # => [1, 2, 3, 4, 5]
        Range.to_list(1..10:3)    # => [1, 4, 7, 10]
        Range.to_list(3..1)       # => [3, 2, 1]
    """

  pub fn to_list(range :: Range) -> [i64] {
    :zig.Range.to_list(range)
  }
}
