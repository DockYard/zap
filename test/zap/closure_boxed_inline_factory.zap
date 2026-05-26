@doc = """
  Helper factory for `closure_boxed_inline_test.zap`. A Zest test file must
  declare exactly one struct, so the boxed-`Callable` producers live here.

  `make_adder/1` returns a CAPTURING `fn(i64) -> i64` (closes over `n`) — an
  escaping capturing closure, so it is a BOXED `Callable({i64}, i64)`
  existential. `ops/0` collects them into a `[fn(i64) -> i64]` =
  `[Callable]` list (heterogeneous-collection boxing).
  """

pub struct Zap.ClosureBoxedInlineFactory {
  @doc = """
    A capturing `fn(i64) -> i64` returned by value — boxed `Callable`.
    """

  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  @doc = """
    A `[fn(i64) -> i64]` (= `[Callable]`) of boxed capturing closures.
    """

  pub fn ops() -> [fn(i64) -> i64] {
    [Zap.ClosureBoxedInlineFactory.make_adder(1), Zap.ClosureBoxedInlineFactory.make_adder(2)]
  }
}
