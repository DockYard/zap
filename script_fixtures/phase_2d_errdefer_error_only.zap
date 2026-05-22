# Phase 2.d acceptance: `errdefer` fires on the `?` Error path but is
# SKIPPED on the normal/success return path; `defer` fires on both.
# defer + errdefer share ONE LIFO stack — source order `defer; errdefer`
# unwinds errdefer first (it was registered later).
#
# run(0): step Errors -> errdefer + defer fire (LIFO), main prints err.
# run(1): step Oks    -> only defer fires (errdefer skipped), main prints ok.
#
# Expected output:
#
#   --- error path ---
#   on-error-only
#   always
#   err
#   --- success path ---
#   always
#   ok

pub struct ErrdeferOnly {
  pub fn step(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n - 1)
      false -> Result(i64, String).Error("stop")
    }
  }

  pub fn run(n :: i64) -> Result(i64, String) {
    defer IO.puts("always")
    errdefer IO.puts("on-error-only")
    next = ErrdeferOnly.step(n)?
    Result(i64, String).Ok(next)
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts("--- error path ---")
  case ErrdeferOnly.run(0) {
    Result.Ok(_v) -> IO.puts("ok")
    Result.Error(_r) -> IO.puts("err")
  }
  IO.puts("--- success path ---")
  case ErrdeferOnly.run(1) {
    Result.Ok(_v) -> IO.puts("ok")
    Result.Error(_r) -> IO.puts("err")
  }
  0
}
