# Phase 2.d acceptance: `defer` runs on the `?` operator's Error
# early-return path.
#
# `step(0)?` takes the Error prong and early-returns out of `run/0`.
# The `defer` registered before the `?` must still fire before the
# error propagates.
#
# Expected output:
#
#   cleanup-ran
#   stop

pub struct DeferTryError {
  pub fn step(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n - 1)
      false -> Result(i64, String).Error("stop")
    }
  }

  pub fn run() -> Result(i64, String) {
    defer IO.puts("cleanup-ran")
    next = DeferTryError.step(0)?
    Result(i64, String).Ok(next)
  }
}

fn main(_args :: [String]) -> u8 {
  case DeferTryError.run() {
    Result.Ok(_v) -> IO.puts("ok")
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}
