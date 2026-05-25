# FCC Phase 3 — Residual 5 prerequisite. A boxed `Callable` stored into a
# plain struct field FROM A BORROWED PARAMETER. `wrap(f)` receives a boxed
# `f :: fn(i64) -> i64` (the caller still owns it) and stores it into a
# `Holder.op` field. The struct becomes a SECOND owner of the box, so the
# capture must clone-on-share: under a no-refcount manager the struct gets an
# independent inner clone (the struct-drop frees the clone, the caller's
# binding frees the original — no double-free); under a refcount manager the
# store bumps the inner's refcount.
#
# Expected (both managers): prints `15`, ZERO leaks / no invalid-free, exit 0.

pub struct Holder {
  op :: fn(i64) -> i64
}

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn wrap(f :: fn(i64) -> i64) -> Holder {
    %Holder{op: f}
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Maker.make_adder(5)
  h = Maker.wrap(add5)
  g = h.op
  IO.puts(Integer.to_string(g(10)))
  0
}
