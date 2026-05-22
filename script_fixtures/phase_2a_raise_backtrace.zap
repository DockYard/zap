# Phase 2.a acceptance: an unrescued `raise %Error{}` prints the
# `** (<kind>) <message>` header AND a symbolized Zap backtrace.
#
# The raise happens three Zap frames deep (`main` -> `blow_up` ->
# `deeper`) so the captured backtrace must show distinct Zap symbols
# with Zap `file:line` source locations — not mangled Zig names, not
# Zig stdlib frames.
#
# Expected (default ZAP_BACKTRACE=short or full):
#   ** (boom_error) kaboom from deeper
#     Demo.deeper at phase_2a_raise_backtrace.zap:<line>
#     Demo.blow_up at phase_2a_raise_backtrace.zap:<line>
#     Demo.main at phase_2a_raise_backtrace.zap:<line>
#
# With ZAP_BACKTRACE=0 only the header line is printed.
#
# This fixture aborts non-zero; it never reaches the `0` return.

@code Z3001
pub error BoomError {
  message :: String = "boom"

  pub fn message(self :: BoomError) -> String {
    self.detail
  }

  detail :: String
}

pub struct Demo {
  pub fn deeper() -> Never {
    raise %BoomError{detail: "kaboom from deeper"}
  }

  pub fn blow_up() -> Never {
    Demo.deeper()
  }
}

fn main(_args :: [String]) -> u8 {
  Demo.blow_up()
  0
}
