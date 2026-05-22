# Phase 1.4 acceptance: `raise "string"` shorthand.
#
# `raise "boom"` desugars to `raise %RuntimeError{message: "boom"}` and
# goes through the Error-aware abort path: the runtime extracts
# `Error.message(value)` (and the `Error.kind` tag) and aborts with a
# non-zero exit code, printing `** (RuntimeError) boom` to stderr.
#
# This fixture aborts; it never reaches the `0` return.
#
# Expected: stderr contains `** (RuntimeError) boom`, exit code 1.

pub struct Demo {
  pub fn blow_up() -> Never {
    raise "boom"
  }
}

fn main(_args :: [String]) -> u8 {
  Demo.blow_up()
  0
}
