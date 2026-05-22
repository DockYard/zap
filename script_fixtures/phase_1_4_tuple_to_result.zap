# Phase 1.4 acceptance: `Result.tuple_to_result/1` migration shim.
#
# Converts a bare `{:ok, v}` / `{:error, e}` tuple to the canonical
# `Result` variants:
#
#   tuple_to_result({:ok, v})    -> Result.Ok(v)
#   tuple_to_result({:error, e}) -> Result.Error(e)
#
# Round-trips both variants and prints which one it matched.
#
# Expected output:
#
#     ok:42
#     err:nope

pub struct Demo {
  pub fn classify(r :: Result(i64, String)) -> String {
    case r {
      Result.Ok(v) -> "ok:" <> Integer.to_string(v)
      Result.Error(e) -> "err:" <> e
    }
  }
}

fn main(_args :: [String]) -> u8 {
  ok_result = Result.tuple_to_result({:ok, 42})
  err_result = Result.tuple_to_result({:error, "nope"})
  IO.puts(Demo.classify(ok_result))
  IO.puts(Demo.classify(err_result))
  0
}
