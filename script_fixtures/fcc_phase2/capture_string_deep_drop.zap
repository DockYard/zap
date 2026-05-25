# FCC Phase 2 — Scenario 2: a capturing closure over a `String` (an
# ARC-managed value), boxed and invoked. The captured `String` lives in
# the heap-allocated environment struct; when the box is dropped at scope
# exit, the env type's drop glue must DEEP-DROP the captured `String`
# exactly once (no leak, no double-free).
#
# This is the box-in-struct deep-release path (Phase 4.c) applied to a
# closure environment: the env struct has an ARC-managed field, so its
# `releaseAny` deep-walk reclaims the captured `String`.
#
# Expected under -Dmemory=Memory.Tracking: prints `hello world`, ZERO
# leaks, exit 0.

pub struct Greeter {
  pub fn make_appender(prefix :: String) -> fn(String) -> String {
    fn(suffix :: String) -> String { String.join([prefix, suffix], "") }
  }
}

fn main(_args :: [String]) -> u8 {
  greet = Greeter.make_appender("hello ")
  IO.puts(greet("world"))
  0
}
