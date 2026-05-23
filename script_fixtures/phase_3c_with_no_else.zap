# Phase 3.c: `with` macro — the `else`-less form. When a step fails to
# match and there is no `else`, the whole `with` evaluates to the
# non-matching value itself (Elixir semantics).
#
# Here the second step fails, so `with` returns `Result.Error("not
# twenty")` unchanged — no rewrapping.
#
# Exercises:
#   * else-less form returns the non-matching value verbatim;
#   * a later-step mismatch (first step matched, bound x) still
#     short-circuits to the raw value.
#
# Expected output:
#   raw: not twenty

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
    }
  }
}

fn main(_args :: [String]) -> u8 {
  result = Calc.add_two("ten", "nope")
  case result {
    Result.Ok(total) -> IO.puts("sum: " <> Integer.to_string(total))
    Result.Error(e) -> IO.puts("raw: " <> e)
  }
  0
}
