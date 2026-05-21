# Phase 1.3 acceptance: postfix `?` propagation operator — happy path.
#
# `parse_positive/1` returns `Result(i64, String)`. `double_it/1`
# propagates the `Ok` payload of `parse_positive(n)?` and doubles it,
# itself returning a `Result`. `main/1` unwraps the final Ok.
#
# Exercises:
#   * `?` on a cross-function call result that is `Ok(...)` -> unwraps
#     the payload and continues.
#   * `?` propagation chained across two functions.
#
# Expected output:
#
#     84

pub struct Demo {
  pub fn parse_positive(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n)
      false -> Result(i64, String).Error("not positive")
    }
  }

  pub fn double_it(n :: i64) -> Result(i64, String) {
    value = Demo.parse_positive(n)?
    Result(i64, String).Ok(value * 2)
  }
}

fn main(_args :: [String]) -> u8 {
  case Demo.double_it(42) {
    Result.Ok(doubled) -> IO.puts(Integer.to_string(doubled))
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}
