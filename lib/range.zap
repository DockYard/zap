@native_type = "range"

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
  direction :: i64 = 0

  @doc = """
    Flip a range's direction by swapping its `start` and `end` while
    preserving the step magnitude. Returns a new `Range` — the input
    is unchanged. Distinct from `Enum.reverse/1`, which materialises
    the range as a `[i64]` in reverse order.

    ## Examples

        Range.reverse(1..10)    # => 10..1
        Range.reverse(100..1)   # => 1..100
        Range.reverse(1..10:3)  # => 10..1:3
    """

  pub fn reverse(range :: Range) -> Range {
    :zig.Range.reverse(range)
  }
}
