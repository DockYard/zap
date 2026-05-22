# Phase 2.a acceptance: the legacy string `raise "msg"` also produces a
# symbolized Zap backtrace via the same crash printer, with the
# `RuntimeError` kind. The `Kernel.raise/1` runtime plumbing frame is
# suppressed just like `Kernel.do_raise/1` is for the Error form.
#
# Expected (default short):
#   ** (RuntimeError) string boom from inner
#     Helper.inner/0 at phase_2a_raise_string_backtrace.zap:<line>
#     Helper.outer/0 at phase_2a_raise_string_backtrace.zap:<line>
#     ...

pub struct Helper {
  pub fn inner() -> Never {
    raise "string boom from inner"
  }

  pub fn outer() -> Never {
    Helper.inner()
  }
}

fn main(_args :: [String]) -> u8 {
  Helper.outer()
  0
}
