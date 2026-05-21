# Round 2 Blocker A fixture (script mode) — multi-arg parametric union.
#
# Result(i64, String).Ok(42) and .Err("bad") in non-return position,
# bound to a local, then destructured. Verifies the consistent
# threading rule for the multi-type-arg case (Result_i64_String).
#
# Expected output:
#
#   42
#   -1
#
# Exit code 0.

pub union Result(t, e) {
  Ok :: t
  Err :: e
}

pub struct Demo {
  pub fn unwrap_ok() -> i64 {
    r = Result(i64, String).Ok(42)
    case r {
      Result.Ok(v) -> v
      Result.Err(_) -> 0
    }
  }

  pub fn unwrap_err() -> i64 {
    r = Result(i64, String).Err("bad")
    case r {
      Result.Ok(v) -> v
      Result.Err(_) -> -1
    }
  }
}

fn main(_args :: [String]) -> u8 {
  Kernel.inspect(Demo.unwrap_ok())
  Kernel.inspect(Demo.unwrap_err())
  0
}
