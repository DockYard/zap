# Phase 3.c: `with` macro — the first step fails to match, so the `with`
# falls through to the `else` clauses. The non-matching value
# (`Result.Error("not ten")`) is matched by the `else` clause, which
# rewraps the error message.
#
# Exercises:
#   * first-step mismatch short-circuits (parse_twenty never runs);
#   * the `else` clause pattern-matches the non-matching value;
#   * the bound message flows into the else body.
#
# Expected output:
#   wrapped: not ten

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
      Result.Error(msg) -> Result(i64, String).Error("wrapped: " <> msg)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  result = Calc.add_two("nope", "twenty")
  case result {
    Result.Ok(total) -> IO.puts("sum: " <> Integer.to_string(total))
    Result.Error(e) -> IO.puts(e)
  }
  0
}
