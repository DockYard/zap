@doc = """
  Boxed-`Callable` combinator factory used by `Zap.CombinatorBoxedTest`. Each
  function returns capturing closures that escape and are therefore boxed as
  `Callable` existentials, plus the `[fn(i64) -> i64]` collection over which the
  FCC Phase-3 filter/reject (return-the-boxed-elements) path is exercised in
  PROJECT mode. Kept in its own file because a Zest test file must declare
  exactly one struct.
  """

pub struct Zap.CombinatorFactory {
  @doc = """
    Returns a closure that adds the captured `n` to its argument.
    """

  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  @doc = """
    A `[fn(i64) -> i64]` list of two capturing adders (`+1`, `+2`), each
    boxed as `Callable({i64}, i64)`.
    """

  pub fn ops() -> [fn(i64) -> i64] {
    [Zap.CombinatorFactory.make_adder(1), Zap.CombinatorFactory.make_adder(2)]
  }
}
