# Golden corpus — an assertion contract violation (domain=runtime,
# sub_kind=assertion_error).
#
# A `Kernel.assert(false)` precondition fails at runtime; the crash report
# names the `assertion_error` kind, the failing expression, and the source
# location, with a symbolized backtrace. `assert` raises the typed stdlib
# `AssertionError` (a `rescue`-able recoverable raise), so reaching the top
# unrescued is domain=runtime — NOT a Zig-level safety panic.
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
