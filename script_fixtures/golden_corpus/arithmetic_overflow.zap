# Golden corpus — an arithmetic overflow trap (domain=runtime,
# sub_kind=arithmetic_error) in a safe build.
#
# In Debug / ReleaseSafe an overflowing `+` traps with the canonical
# `** (arithmetic_error) integer overflow` shape and a symbolized backtrace.
# (In ReleaseFast / ReleaseSmall the same `+` wraps instead.) The safe-mode
# checked `+` raises the typed stdlib `ArithmeticError` via
# `Kernel.raise_with_kind` (a `rescue`-able recoverable raise), so reaching the
# top unrescued is domain=runtime — NOT a Zig-level safety panic.
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
