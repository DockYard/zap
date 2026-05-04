@doc = """
  Demo `Doubler` struct that defines a `double/1` macro.

  The macro lowers to `value + value` at compile time, so
  `Doubler.compute(5)` evaluates to `(5 * 3) + (5 * 3) = 30`
  with the doubling baked in by the macro expander rather than
  computed at runtime.
  """

pub struct Doubler {
  pub macro double(value :: i64) -> i64 {
    quote {
      unquote(value) + unquote(value)
    }
  }

  pub fn compute(x :: i64) -> i64 {
    double(x * 3)
  }
}
