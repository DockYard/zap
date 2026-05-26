@doc = """
  Helper factory for `closure_container_return_test.zap`. Functions that RETURN
  a CONTAINER of boxed `Callable`s — a `[fn(i64) -> i64]` and a
  `%{Atom => fn(i64) -> i64}` (`Map(Atom, Callable)`). The previously-deferred
  project-mode gap was the `Map(_, Callable)` / `[Callable]` RETURN type itself.
  """

pub struct Zap.ClosureContainerReturnFactory {
  @doc = """
    A capturing `fn(i64) -> i64` — boxed `Callable`.
    """

  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  @doc = """
    RETURNS a `[fn(i64) -> i64]` (= `[Callable]`).
    """

  pub fn op_list() -> [fn(i64) -> i64] {
    [Zap.ClosureContainerReturnFactory.make_adder(10), Zap.ClosureContainerReturnFactory.make_adder(20)]
  }

  @doc = """
    RETURNS a `%{Atom => fn(i64) -> i64}` (= `Map(Atom, Callable)`).
    """

  pub fn op_map() -> %{Atom => fn(i64) -> i64} {
    %{:inc => Zap.ClosureContainerReturnFactory.make_adder(1), :dec => Zap.ClosureContainerReturnFactory.make_adder(-1)}
  }
}
