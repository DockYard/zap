# FCC Phase 2 — Scenario 1: a capturing closure over an `i64`, boxed
# (returned across a call boundary into a `fn(i64) -> i64`-typed local,
# forcing the boxed `Callable` existential), invoked, then dropped at
# scope exit.
#
# The boxed environment (`__closure_N{ n: i64 }`) is heap-allocated by
# `box_as_protocol`. Under `Memory.Tracking` that allocation MUST be
# released exactly once at the local's scope exit via the vtable
# `__box_header__.drop`. Before Phase 2 it leaks (no scope-exit drop is
# scheduled for the parametric `Callable` box). The `i64` capture itself
# is trivial (no nested ARC release), so this isolates the box-drop.
#
# Expected under -Dmemory=Memory.Tracking: prints `15`, ZERO leaks,
# exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Maker.make_adder(5)
  IO.puts(Integer.to_string(add5(10)))
  0
}
