# Phase 2.c acceptance: `assert(cond, "message")` renders the custom
# message alongside the stringified failing condition in the crash
# report. Always-on tier — fires in every optimize mode.
#
# Expected (any optimize mode):
#   ** (assertion_error) x must be positive: x > 0 (x = ...)
#     ...
# (exact rendering pinned by the macro; the custom message and the
# condition source text must both appear.)
#
# This fixture aborts non-zero; it never reaches the `0` return.

pub struct AssertMsg {
  pub fn check(x :: i64) -> Nil {
    assert(x > 0, "x must be positive")
  }
}

fn main(_args :: [String]) -> u8 {
  AssertMsg.check(0)
  0
}
