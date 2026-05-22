# Phase 2.d ARC acceptance: an ARC-managed value (a String) referenced by
# the deferred cleanup must be balanced (no leak, no double-free) on BOTH
# the success and `?`-Error paths under default ARC (Memory.Tracking).
#
# `process(n)` builds an ARC-managed String, schedules `defer IO.puts(label)`
# (which reads `label` at scope exit), then `step(n)?` either Oks (success
# path) or Errors (error early-return). On the error path the defer still
# fires (reading `label`); on success it fires at normal exit. Either way
# the String is retained/released in balance — the deferred read keeps it
# alive to its release point (no leak), and there is no double-free (the
# run exits 0 rather than aborting on a refcount underflow).
#
# Run with ZAP_ARC_STATS=1 (project build) and assert
# releases_total >= retains_total. Via `zap run` the output is:
#
#   resource-X
#   resource-X
#   stopped

pub struct ArcClean {
  pub fn step(n :: i64) -> Result(i64, String) {
    case n > 0 {
      true -> Result(i64, String).Ok(n - 1)
      false -> Result(i64, String).Error("stopped")
    }
  }

  pub fn process(n :: i64) -> Result(i64, String) {
    label = String.concat("resource-", "X")
    defer IO.puts(label)
    next = ArcClean.step(n)?
    Result(i64, String).Ok(next)
  }
}

fn main(_args :: [String]) -> u8 {
  _success = ArcClean.process(2)
  case ArcClean.process(0) {
    Result.Ok(_v) -> IO.puts("ok")
    Result.Error(reason) -> IO.puts(reason)
  }
  0
}
