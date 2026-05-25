# FCC Phase 2 — Scenario 5: a `[fn(String) -> String]` list of closures, each
# CAPTURING a `String`. The list is partially consumed, then dropped. Each
# un-extracted box element must be deep-released along with its captured
# `String`'s ARC-managed children. (`String` itself is an arena slice, but a
# closure capturing a String boxes an env whose inner is the captured value —
# the box inner is the eagerly-freed allocation that must not leak.)
#
# Expected under -Dmemory=Memory.Tracking: prints `hi alice`, ZERO leaks,
# exit 0.

pub struct Greeter {
  pub fn make_greeter(name :: String) -> fn(String) -> String {
    fn(greeting :: String) -> String { greeting <> " " <> name }
  }

  pub fn greeters() -> [fn(String) -> String] {
    [Greeter.make_greeter("alice"), Greeter.make_greeter("bob"), Greeter.make_greeter("carol")]
  }
}

fn main(_args :: [String]) -> u8 {
  gs = Greeter.greeters()
  first = List.get(gs, 0)
  IO.puts(first("hi"))
  0
}
