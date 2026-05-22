# Phase 1.4 acceptance: `raise %CustomError{...}` is Error-aware.
#
# `raise` accepts any value whose type implements the `Error` protocol.
# The runtime extracts `Error.message(value)` and the `Error.kind` tag
# and aborts non-zero, printing `** (<kind>) <message>`.
#
# `ParseError` carries a custom default `message` plus user fields. The
# abort prints the constructed message.
#
# This fixture aborts; it never reaches the `0` return.
#
# Expected: stderr contains `** (parse_error) bad token at 7`, exit code 1.

pub error ParseError {
  message :: String = "parse error"
  position :: i64

  pub fn message(self :: ParseError) -> String {
    "bad token at " <> Integer.to_string(self.position)
  }
}

pub struct Demo {
  pub fn blow_up() -> Never {
    raise %ParseError{position: 7}
  }
}

fn main(_args :: [String]) -> u8 {
  Demo.blow_up()
  0
}
