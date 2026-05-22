# Phase 1.5 acceptance: integer overflow WRAPS in fast modes.
#
# Built with `-Doptimize=ReleaseFast` (or ReleaseSmall), an overflowing
# `+` wraps two's-complement with no trap: i64 max + 1 == i64 min
# (-9223372036854775808). The program runs to completion and prints the
# wrapped value.
#
# Expected (ReleaseFast / ReleaseSmall):
#   stdout == "-9223372036854775808\n", exit code 0.
#
# (In Debug / ReleaseSafe the same source TRAPS instead — see
# phase_1_5_overflow_trap.zap.)

pub struct Wrap {
  pub fn add_one(x :: i64) -> i64 {
    x + 1
  }
}

fn main(_args :: [String]) -> u8 {
  big = 9223372036854775807
  result = Wrap.add_one(big)
  IO.puts(Integer.to_string(result))
  0
}
