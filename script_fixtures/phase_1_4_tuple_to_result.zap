# Phase 1.4 acceptance: `Result.tuple_to_result/1` migration shim.
#
# Converts a bare `{:ok, v}` / `{:error, e}` tuple to the canonical
# `Result` variants:
#
#   tuple_to_result({:ok, v})    -> Result.Ok(v)
#   tuple_to_result({:error, e}) -> Result.Error(e)
#
# The shim shares one payload type parameter across both variants, so
# this fixture uses homogeneous (i64) payloads. It round-trips both
# variants and prints which one it matched.
#
# Expected output:
#
#     ok:42
#     err:7

pub struct Demo {
  pub fn classify(r :: Result(i64, i64)) -> String {
    case r {
      Result.Ok(v) -> "ok:" <> Integer.to_string(v)
      Result.Error(e) -> "err:" <> Integer.to_string(e)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  ok_result = Result.tuple_to_result({:ok, 42})
  err_result = Result.tuple_to_result({:error, 7})
  IO.puts(Demo.classify(ok_result))
  IO.puts(Demo.classify(err_result))
  0
}
