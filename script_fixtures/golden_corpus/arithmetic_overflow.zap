# Golden corpus — an arithmetic overflow trap (domain=panic,
# sub_kind=arithmetic_error) in a safe build.
#
# In Debug / ReleaseSafe an overflowing `+` traps with the canonical
# `** (arithmetic_error) integer overflow` shape and a symbolized backtrace.
# (In ReleaseFast / ReleaseSmall the same `+` wraps instead.)
pub struct ArithmeticOverflow {
  pub fn boom(value :: i64) -> i64 {
    value + 1
  }
}

fn main(_args :: [String]) -> u8 {
  largest = 9223372036854775807
  ArithmeticOverflow.boom(largest)
  0
}
