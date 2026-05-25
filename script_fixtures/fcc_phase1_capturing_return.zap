# FCC Phase 1 — a capturing closure returned across a call boundary is a
# boxed `Callable` existential, invoked through the protocol-box vtable.
#
# `make_adder(n)` returns `fn(x) -> { x + n }` capturing `n`. The closure
# escapes its defining frame, so the desugar rewrites it to a synthesized
# `struct __closure_N { n :: i64 }` + `impl Callable({i64}, i64)` and the
# return type becomes `Callable({i64}, i64)`. The call `add5(10)` is
# rewritten to `Callable.call(add5, {10})`, dispatched through the box's
# per-instantiation vtable `call` slot.
#
# Expected (Memory.ARC, the default): prints `15`, exit 0.
# Under Memory.Tracking the boxed env is not yet released (Phase 2 —
# parametric-protocol-box drop must be separated from the devirtualized
# Enumerable handling without regressing it).

pub struct AdderMaker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(args :: [String]) -> u8 {
  add5 = AdderMaker.make_adder(5)
  IO.puts(Integer.to_string(add5(10)))
  0
}
