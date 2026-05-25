# FCC Phase 2 — Shared boxed closure capturing a STRUCT by value. `shifted`
# captures a `Point` and adds its components to its argument; it is aliased
# into `again` and BOTH are invoked. Each binding is an independent owner of
# the boxed environment (which holds the captured `Point` by value). Under a
# no-refcount manager the share clones the env; the captured `Point` is a
# plain by-value struct with no ARC children, so the clone's bit-copy is
# already independent. Under a refcount manager the share bumps the env's
# refcount.
#
# Exercises the gap-loop "shared closure capturing a struct".
#
# Expected under BOTH managers: prints `16` twice, ZERO leaks, exit 0.

pub struct Point {
  x :: i64
  y :: i64
}

pub struct Shifter {
  pub fn make(origin :: Point) -> fn(i64) -> i64 {
    fn(n :: i64) -> i64 { n + origin.x + origin.y }
  }
}

fn main(_args :: [String]) -> u8 {
  shifted = Shifter.make(%Point{x: 1, y: 5})
  again = shifted
  IO.puts(Integer.to_string(shifted(10)))
  IO.puts(Integer.to_string(again(10)))
  0
}
