# Result propagation via `with` — happy path.
#
# `parse_positive/1` returns `Result(i64, String)`. `double_it/1`
# propagates the `Ok` payload of `parse_positive(n)` with a `with`
# chain and doubles it, itself returning a `Result`. `main/1`
# unwraps the final Ok.
#
# Exercises (replacing the removed `?` operator):
#   * `with Ok(value) <- call` unwraps the `Ok` payload and continues.
#   * the `else Error(e)` clause re-wraps and short-circuits the chain.
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
    with Result.Ok(value) <- Demo.parse_positive(n) {
      Result(i64, String).Ok(value * 2)
    } else {
      Result.Error(reason) -> Result(i64, String).Error(reason)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  case Demo.double_it(42) {
    Result.Ok(doubled) -> IO.puts(Integer.to_string(doubled))
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}
