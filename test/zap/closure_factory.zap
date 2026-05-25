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

  @doc = """
    A three-element `[fn(i64) -> i64]` list of capturing closures. Used to
    exercise the box-in-container deep-release for a partially-consumed list
    (extract one, drop the rest) and a never-extracted list (drop all): the
    un-extracted boxed environments must be released by the list-drop.
    """

  pub fn triple_adders() -> [fn(i64) -> i64] {
    [Zap.ClosureFactory.make_adder(1), Zap.ClosureFactory.make_adder(2), Zap.ClosureFactory.make_adder(3)]
  }

  @doc = """
    Returns a closure capturing a `String`, used to prove the box-in-container
    deep-release reclaims a closure's captured ARC value when its boxed
    environment is freed by the list-drop.
    """

  pub fn make_greeter(name :: String) -> fn(String) -> String {
    fn(greeting :: String) -> String { greeting <> " " <> name }
  }

  @doc = """
    A three-element `[fn(String) -> String]` list of String-capturing closures.
    """

  pub fn greeters() -> [fn(String) -> String] {
    [Zap.ClosureFactory.make_greeter("alice"), Zap.ClosureFactory.make_greeter("bob"), Zap.ClosureFactory.make_greeter("carol")]
  }
}
