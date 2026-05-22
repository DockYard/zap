# Phase 2.b acceptance: a runtime integer divide-by-zero in safe mode
# (Debug / ReleaseSafe) must route through the Zap crash printer and
# produce the unified `** (arithmetic_error) <message>` header plus a
# symbolized Zap backtrace — NOT Zig's default panic text.
#
# The divisor is computed at runtime (`DivCrash.zero/0`) so the compiler
# cannot fold the division away or reject it as a comptime divide-by-zero.
# The division happens two Zap frames deep (`main` -> `crash` -> `divide`)
# so the captured backtrace shows distinct Zap symbols with Zap
# `file:line` source locations.
#
# Expected (Debug or ReleaseSafe, default ZAP_BACKTRACE=short):
#   ** (arithmetic_error) division by zero
#     DivCrash.divide/2 at phase_2b_divide_by_zero.zap:<line>
#     DivCrash.crash/0 at phase_2b_divide_by_zero.zap:<line>
#
# This fixture aborts non-zero; it never reaches the `0` return.

pub struct DivCrash {
  pub fn zero() -> i64 {
    0
  }

  pub fn divide(numerator :: i64, denominator :: i64) -> i64 {
    numerator / denominator
  }

  pub fn crash() -> i64 {
    DivCrash.divide(10, DivCrash.zero())
  }
}

fn main(_args :: [String]) -> u8 {
  DivCrash.crash()
  0
}
