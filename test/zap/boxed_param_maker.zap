@doc = """
  Factory for the cross-struct boxed-`Callable`-param corpus test
  (`Zap.BoxedParamTest`). Manufactures capturing closures that escape and are
  boxed as `Callable({i64}, i64)` existentials. Kept in its own file because a
  Zest test file must declare exactly one struct.
  """

pub struct Zap.BoxedParamMaker {
  @doc = """
    Returns a closure that adds the captured `n` to its argument, boxed as a
    `Callable({i64}, i64)` existential when it escapes this frame.
    """

  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}
