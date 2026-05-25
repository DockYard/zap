# FCC Phase 2 — Scenario 4: a closure capturing ANOTHER (boxed) closure.
# `make_twice(f)` returns a closure that captures the boxed `f ::
# fn(i64) -> i64` and applies it twice. The outer closure's environment
# holds a `Callable` box as a field; when the outer box is dropped, the
# env's drop glue must deep-release the captured inner box exactly once
# (nested box-in-box deep-release).
#
# Both the inner `add5` box and the outer `twice` box must be released
# exactly once — no leak, no double-free.
#
# Expected under -Dmemory=Memory.Tracking: prints `20`, ZERO leaks,
# exit 0 (((5 + 5) + 5) == 15? no: twice(add5)(5) = add5(add5(5)) =
# add5(10) = 15). Prints `15`.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn make_twice(f :: fn(i64) -> i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { f(f(x)) }
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Maker.make_adder(5)
  twice = Maker.make_twice(add5)
  IO.puts(Integer.to_string(twice(5)))
  0
}
