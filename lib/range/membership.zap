pub impl Membership for Range {
  @doc = """
    Numeric containment — true when `value` is between `range.start`
    and `range.end` (inclusive of both ends, regardless of step).
    """

  pub fn member?(range :: Range, value :: i64) -> Bool {
    :zig.Range.contains(range, value)
  }
}
