# Phase 2.c acceptance: a failed `assert(false)` aborts the process in
# EVERY optimize mode (Debug, ReleaseSafe, ReleaseFast, ReleaseSmall)
# with the unified Zap crash report — the `** (assertion_error) <cond>`
# header (carrying the stringified failing condition) plus a symbolized
# Zap backtrace.
#
# `assert` is the always-on contract tier: it is never elided.
#
# The assertion fires two Zap frames deep (`main` -> `check`) so the
# captured backtrace shows distinct Zap symbols with Zap `file:line`
# source locations.
#
# Expected (any optimize mode, default ZAP_BACKTRACE=short):
#   ** (assertion_error) assertion failed: false
#     AssertCrash.check/0 at phase_2c_assert_false.zap:<line>
#     ...
#
# This fixture aborts non-zero; it never reaches the `0` return.

pub struct AssertCrash {
  pub fn check() -> Nil {
    assert(false)
  }
}

fn main(_args :: [String]) -> u8 {
  AssertCrash.check()
  0
}
