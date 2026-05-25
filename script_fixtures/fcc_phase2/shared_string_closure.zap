# FCC Phase 2 — Shared boxed closure capturing a `String`. `greet` captures
# the prefix `"hi "`, then is aliased into `again`; BOTH are invoked. Each
# binding is an independent owner of the boxed environment. Under a
# no-refcount manager the share clones the env; the captured `String` is a
# `[]const u8` slice into the global runtime arena, so the clone shares the
# arena-backed bytes safely (the arena outlives every owner — no double-free
# of the string, no leak). Under a refcount manager the share bumps the env's
# refcount.
#
# Expected under BOTH managers: prints `hi there` twice, ZERO leaks, exit 0.

pub struct Greeter {
  pub fn make_appender(prefix :: String) -> fn(String) -> String {
    fn(suffix :: String) -> String { String.join([prefix, suffix], "") }
  }
}

fn main(_args :: [String]) -> u8 {
  greet = Greeter.make_appender("hi ")
  again = greet
  IO.puts(greet("there"))
  IO.puts(again("there"))
  0
}
