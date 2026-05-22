# Phase 2.f GP2 acceptance: a failed `assert(...)` (a macro that expands to
# a `case` whose template body lives in kernel.zap) must attribute the
# crashing user frame to the user's `assert(...)` CALL-SITE line, not the
# `kernel.zap` macro-expansion line.
#
# Before GP2 the backtrace frame for `Guard.require/1` read
# `kernel.zap:457` (the macro template's `case` arm). After GP2 the
# call-site span resolves through the macro expansion to the user line,
# so the frame reads `phase_2f_gp2_assert_callsite_line.zap:<the assert
# line>` — line 22 below.
#
# Expected (any optimize mode, default ZAP_BACKTRACE=short):
#   ** (assertion_error) assertion failed: count > 0 (at ...:21)
#     Guard.require/1 at ...:21       <- the user assert line, not kernel.zap:457
#     ...
#
# The crash-report MESSAGE location and the user frame's BACKTRACE line now
# agree (both line 21) — before GP2 the message said the user line but the
# frame pointed at the macro template line in kernel.zap.
#
# This fixture aborts non-zero; it never reaches the `0` return.

pub struct Guard {
  pub fn require(count :: Integer) -> Nil {
    assert(count > 0)
  }
}

fn main(_args :: [String]) -> u8 {
  Guard.require(0)
  0
}
