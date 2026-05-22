# Phase 1.3 negative acceptance: an explicit `raises` row that is
# narrower than the body's inferred error row must be rejected.
#
# `parse_positive/1` returns `Result(i64, String)`, so `parse_positive(n)?`
# in `double_it/1` propagates a `String` error. `double_it/1` declares
# `raises i64` — which does NOT cover `String` — so the type-checker
# must emit a rich diagnostic and reject the program.
#
# Expected: compilation FAILS with a diagnostic of the form
#
#   this function's body can raise an error its `raises` row does not declare
#   ... declares `raises i64` but the body can also raise `String` here
#
# This fixture is a compile-error case; it is never executed.

pub struct Demo {
  pub fn parse_positive(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n)
      false -> Result(i64, String).Error("not positive")
    }
  }

  pub fn double_it(n :: i64) -> Result(i64, String) raises i64 {
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
