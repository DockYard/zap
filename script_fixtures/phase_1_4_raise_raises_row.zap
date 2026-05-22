# Phase 1.4 acceptance: `raise %CustomError{...}` contributes the raised
# error's type to the enclosing function's inferred `raises` row.
#
# `validate/1` raises `ParseError` on the bad branch and declares
# `raises ParseError`. The declared row exactly covers the inferred
# row (the `raise` contributes `ParseError`), so the function
# type-checks. The good branch returns a `Result.Ok`, the bad branch
# diverges via `raise`.
#
# Exercises:
#   * `raise %E{}` recording `E` into `current_raises` (the same
#     accumulator the `?` operator feeds, Phase 1.3).
#   * an explicit `raises E` row that covers a `raise`d error.
#
# Expected output:
#
#     ok:5

pub error ParseError {
  message :: String = "parse error"
}

pub struct Demo {
  pub fn validate(n :: i64) -> Result(i64, String) raises ParseError {
    case n > 0 {
      true -> Result(i64, String).Ok(n)
      false -> raise %ParseError{}
    }
  }
}

fn main(_args :: [String]) -> u8 {
  case Demo.validate(5) {
    Result.Ok(v) -> IO.puts("ok:" <> Integer.to_string(v))
    Result.Error(e) -> IO.puts("err:" <> e)
  }
  0
}
