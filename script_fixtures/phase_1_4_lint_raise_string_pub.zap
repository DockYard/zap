# Phase 1.4 lint (warn-only): `raise "string"` on a `pub` API surface.
#
# `Demo.boom/0` is a public function that raises a bare string literal.
# The compiler emits a WARNING suggesting a named `pub error`, but the
# program still compiles and runs (the lint is advisory, not fatal).
#
# Expected: a `warning:` line mentioning a named `pub error`; the program
# then runs and prints `ok` (it never calls boom, so no abort).

pub struct Demo {
  pub fn boom() -> Never {
    raise "ad-hoc public failure"
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts("ok")
  0
}
