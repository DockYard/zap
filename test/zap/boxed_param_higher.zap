@doc = """
  Higher-order helper whose method `apply` takes a boxed `Callable` PARAMETER
  (`f :: fn(i64) -> i64`) and invokes it. Used cross-struct by
  `Zap.BoxedParamTest`, which passes a boxed closure manufactured in
  `Zap.BoxedParamMaker` — exercising cross-struct emission + dispatch of a
  method with a boxed-`Callable` parameter in PROJECT mode. Kept in its own file
  because a Zest test file must declare exactly one struct.
  """

pub struct Zap.BoxedParamHigher {
  @doc = """
    Invokes the boxed `Callable` parameter `f` on `v`, dispatching through the
    box `call` slot.
    """

  pub fn apply(f :: fn(i64) -> i64, v :: i64) -> i64 {
    f(v)
  }

  @doc = """
    Invokes the boxed `Callable` twice (composition), to exercise multiple
    dispatches through the same boxed parameter within one cross-struct method.
    """

  pub fn apply_twice(f :: fn(i64) -> i64, v :: i64) -> i64 {
    f(f(v))
  }
}
