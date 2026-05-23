# Phase 3.c: `with` macro — every step matches, runs the `do` body.
#
# Two `Result`-returning steps both succeed, so the `do` body runs and
# combines the bound values. Exercises multi-step binding and the
# all-match path.
#
# Expected output:
#   sum: 30

pub struct Calc {
  pub fn parse_ten(input :: String) -> Result(i64, String) {
    case input {
      "ten" -> Result(i64, String).Ok(10)
      _ -> Result(i64, String).Error("not ten")
    }
  }

  pub fn parse_twenty(input :: String) -> Result(i64, String) {
    case input {
      "twenty" -> Result(i64, String).Ok(20)
      _ -> Result(i64, String).Error("not twenty")
    }
  }

  pub fn add_two(a :: String, b :: String) -> Result(i64, String) {
    with Result.Ok(x) <- parse_ten(a),
         Result.Ok(y) <- parse_twenty(b) {
      Result(i64, String).Ok(x + y)
    } else {
      Result.Error(msg) -> Result(i64, String).Error(msg)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  result = Calc.add_two("ten", "twenty")
  case result {
    Result.Ok(total) -> IO.puts("sum: " <> Integer.to_string(total))
    Result.Error(e) -> IO.puts("err: " <> e)
  }
  0
}
