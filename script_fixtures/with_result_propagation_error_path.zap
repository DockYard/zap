# Result propagation via `with` — error path.
#
# `parse_positive/1` returns `Error("not positive")` for n <= 0.
# `double_it/1` propagates that `Error` through the `with` chain's
# `else` clause, so the `do` body's `Result.Ok(value * 2)` is never
# reached and `double_it(-5)` short-circuits with the original
# `Error`. `main/1` prints the reason.
#
# Expected output:
#
#     not positive

pub struct Demo {
  pub fn parse_positive(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n)
      false -> Result(i64, String).Error("not positive")
    }
  }

  pub fn double_it(n :: i64) -> Result(i64, String) {
    with Result.Ok(value) <- Demo.parse_positive(n) do
      Result(i64, String).Ok(value * 2)
    else
      Result.Error(reason) -> Result(i64, String).Error(reason)
    end
  }
}

fn main(_args :: [String]) -> u8 {
  case Demo.double_it(-5) {
    Result.Ok(doubled) -> IO.puts(Integer.to_string(doubled))
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}
