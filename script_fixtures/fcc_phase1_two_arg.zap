# FCC Phase 1 — a two-argument capturing closure as a boxed `Callable`.
#
# Exercises the arity-as-tuple encoding for a `fn(i64, i64) -> i64`
# closure: the `Callable` instantiation is `Callable({i64, i64}, i64)`,
# the vtable `call` slot takes a two-element tuple `struct { i64, i64 }`,
# and the call `combine(10, 20)` packs the arguments into `{10, 20}`
# dispatched through the box.
#
# Expected (Memory.ARC, the default): prints `130`, exit 0.
# (Memory.Tracking box-drop: Phase 2 — see fcc_phase1_capturing_return.zap.)

pub struct Combiner {
  pub fn make(base :: i64) -> fn(i64, i64) -> i64 {
    fn(x :: i64, y :: i64) -> i64 { x + y + base }
  }
}

fn main(args :: [String]) -> u8 {
  combine = Combiner.make(100)
  IO.puts(Integer.to_string(combine(10, 20)))
  0
}
