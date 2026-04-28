pub impl Membership for Range {
  @doc = """
    Step-aware containment. Returns true when `value` lies
    within `range.start..range.end` (inclusive of both ends)
    AND lies on a step boundary measured from `range.start`.

    For the default-step case (`1..10`), every integer in
    `[1, 10]` is on a step boundary, so the check reduces to
    a pure bounds test. For an explicit step (`1..10:3`),
    only values reachable from `range.start` by repeated
    `step` increments — `1, 4, 7, 10` — are members.
    Direction follows from the `start..end` ordering, but
    the modular test is direction-agnostic because the
    remainder is zero exactly when `step` divides the
    signed difference.

    ## Examples

        5 in 1..10        # => true  (default step 1)
        2 in 1..10:3      # => false (not on step from 1)
        4 in 1..10:3      # => true  (1, 4, 7, 10)
        3 in 1..100:10    # => false (1, 11, 21, ...)
    """

  pub fn member?(range :: Range, value :: i64) -> Bool {
    if :zig.Range.contains(range, value) {
      :zig.Kernel.remainder(value - range.start, range.step) == 0
    } else {
      false
    }
  }
}
