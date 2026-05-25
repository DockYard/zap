# FCC Phase 3 — Residual 6. A closure capturing ANOTHER (boxed) closure.
# `make_twice(f)` captures the boxed `f :: fn(i64) -> i64` and applies it
# twice. The outer closure's env holds a `Callable` box as a field; the
# outer box's drop deep-releases the captured inner box exactly once.
#
# Expected (both managers): prints `15` (add5(add5(5)) = add5(10) = 15),
# exit 0.

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
