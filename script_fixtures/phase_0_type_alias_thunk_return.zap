# Phase 0: an alias of a function type used in RETURN position — the
# closure-feature's motivating case. `type Thunk = fn() -> i64` then
# `pub fn make() -> Thunk { fn() -> i64 { 42 } }`. The alias must resolve
# in the return-type position so the non-capturing closure literal type-
# checks against it. The returned value is then invoked through a higher-
# order parameter (the existing Gap E direct-call path), proving the
# returned-as-Thunk value is type-compatible with `fn() -> i64`.
#
# Expected output:
#   42

type Thunk = fn() -> i64

pub struct Factory {
  pub fn make() -> Thunk {
    fn() -> i64 { 42 }
  }

  pub fn run(f :: fn() -> i64) -> i64 {
    f()
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(Factory.run(Factory.make())))
  0
}
