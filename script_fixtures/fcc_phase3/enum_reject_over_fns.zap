# FCC Phase 3 — Item 1: `Enum.reject` over a [fn(i64) -> i64] list that RETURNS
# the boxed elements.
#
# The mirror of `enum_filter_over_fns.zap`: `Enum.reject` keeps the elements for
# which the predicate is FALSE and RETURNS those boxed `Callable` elements into a
# new `[Callable]` via `List.prepend`. Same `List.cons`-consumes-vs-owned-drop
# double-free under `Memory.Tracking` if the cons element argument is not
# classified consumed.
#
# Expected (both managers):
#   reject drops make_adder(2) (adds > 1), keeps make_adder(1); applied to 10 => 11
#   prints 11, exit 0, ZERO leaks, NO double-free.

pub struct AdderMaker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn ops() -> [fn(i64) -> i64] {
    [AdderMaker.make_adder(1), AdderMaker.make_adder(2)]
  }
}

fn main(args :: [String]) -> u8 {
  ops = AdderMaker.ops()
  # Reject the ops that add MORE than 1 (drops make_adder(2)); keeps make_adder(1).
  kept = Enum.reject(ops, fn(f :: fn(i64) -> i64) -> Bool { f(0) > 1 })
  keeper = List.get(kept, 0)
  IO.puts(Integer.to_string(keeper(10)))
  0
}
