# Phase 1.4 negative acceptance: a `raise`d error not covered by the
# declared `raises` row must be rejected.
#
# `validate/1` raises `ParseError` but declares `raises i64`, which does
# NOT cover `ParseError`. The type-checker's subset check (the same one
# Phase 1.3 applies to `?`-propagated errors) must reject the program,
# proving `raise` feeds the inferred `raises` row.
#
# Expected: compilation FAILS with a `raises`-row diagnostic. Never run.

pub error ParseError {
  message :: String = "parse error"
}

pub struct Demo {
  pub fn validate(n :: i64) -> Result(i64, String) raises i64 {
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
