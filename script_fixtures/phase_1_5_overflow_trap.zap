# Phase 1.5 acceptance: integer overflow TRAPS in safe modes.
#
# Built in Debug or ReleaseSafe, an overflowing `+` aborts with the
# canonical Zap arithmetic-error shape and a non-zero exit — the same
# observable behavior as `raise %ArithmeticError{}`.
#
# Expected (Debug / ReleaseSafe): stderr contains
#   `** (arithmetic_error) integer overflow`
# and exit code is non-zero. This fixture never reaches the `0` return.
#
# (In ReleaseFast / ReleaseSmall the same source WRAPS instead — see
# phase_1_5_overflow_wrap.zap.)

pub struct Overflow {
  pub fn boom(x :: i64) -> i64 {
    x + 1
  }
}

fn main(_args :: [String]) -> u8 {
  # i64 max — adding 1 overflows.
  big = 9223372036854775807
  result = Overflow.boom(big)
  IO.puts(Integer.to_string(result))
  0
}
