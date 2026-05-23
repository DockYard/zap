# Golden corpus — an assertion contract violation (domain=panic,
# sub_kind=assertion_error).
#
# A `Kernel.assert(false)` precondition fails at runtime; the crash report
# names the `assertion_error` kind, the failing expression, and the source
# location, with a symbolized backtrace.
pub struct AssertionError {
  pub fn check(value :: Bool) -> Atom {
    assert(value)
    :ok
  }
}

fn main(_args :: [String]) -> u8 {
  AssertionError.check(false)
  0
}
