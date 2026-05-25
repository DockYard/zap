@doc = """
  Closure factory used by `Zap.ClosureBoxedTest`. Each function returns a
  capturing closure that escapes its defining frame and is therefore boxed
  as a `Callable` existential. Kept in its own file because a Zest test
  file must declare exactly one struct.
  """

pub struct Zap.ClosureFactory {
  @doc = """
    Returns a closure that adds the captured `n` to its argument.
    """

  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  @doc = """
    Returns a two-argument closure that sums its arguments with the
    captured `base`.
    """

  pub fn make_combiner(base :: i64) -> fn(i64, i64) -> i64 {
    fn(x :: i64, y :: i64) -> i64 { x + y + base }
  }

  @doc = """
    Returns a zero-argument closure yielding the captured `value`.
    """

  pub fn make_constant(value :: i64) -> fn() -> i64 {
    fn() -> i64 { value }
  }

  @doc = """
    A heterogeneous `[fn(i64) -> i64]` list: a non-capturing inline
    closure followed by a capturing `make_adder(5)`. Both elements box as
    `Callable({i64}, i64)`.
    """

  pub fn adders() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { x + 1 }, Zap.ClosureFactory.make_adder(5)]
  }
}
