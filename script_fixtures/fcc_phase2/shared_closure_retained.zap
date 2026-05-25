# FCC Phase 2 — Scenario 5: a boxed closure stored in two places. `add5`
# is bound, then aliased into a second local `also`; both are invoked.
# Each binding is an independent owner of the box, so the box must be
# RETAINED on the share (`__box_header__.retain` -> `retainProtocolBoxInner`)
# and released once per owner at scope exit — balanced refcount, no
# double-free, no leak.
#
# Also stores the same closure into a one-element list (a second owning
# container) to exercise the retain-into-container path.
#
# Expected under -Dmemory=Memory.Tracking: prints `15` then `15` then
# `15`, ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Maker.make_adder(5)
  also = add5
  IO.puts(Integer.to_string(add5(10)))
  IO.puts(Integer.to_string(also(10)))

  held = [add5]
  g = List.get(held, 0)
  IO.puts(Integer.to_string(g(10)))
  0
}
