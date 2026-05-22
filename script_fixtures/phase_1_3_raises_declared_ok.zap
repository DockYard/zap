# Phase 1.3 acceptance: explicit `raises` annotation that matches the
# inferred error row.
#
# `double_it/1` propagates the `String` error of `parse_positive(n)?`
# and declares `raises String`. The declared row exactly covers the
# inferred row, so the function type-checks and runs end-to-end.
#
# Exercises:
#   * `raises Type` parsing on a function signature.
#   * the type-checker's subset check accepting a declared row that
#     covers every `?`-propagated error.
#
# Expected output:
#
#     84

pub struct Demo {
  pub fn parse_positive(n :: i64) -> Result(i64, String) raises String {
    case n > 0 {
      true -> Result(i64, String).Ok(n)
      false -> Result(i64, String).Error("not positive")
    }
  }

  pub fn double_it(n :: i64) -> Result(i64, String) raises String {
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
