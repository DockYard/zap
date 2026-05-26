# FCC Phase 3 — Item 1: `Enum.filter` over a [fn(i64) -> i64] list that RETURNS
# the boxed elements.
#
# `ops` is a `[fn(i64) -> i64]` = `[Callable({i64}, i64)]`. Each element is a
# boxed `Callable` existential. Unlike `Enum.map` (which stores the callback
# RESULT, an i64), `Enum.filter` RETURNS the boxed elements themselves into a
# new `[Callable]` result list via `List.prepend(accumulator, value)`.
#
# `List.prepend` -> `:zig.List.cons` CONSUMES its head directly (no `ownElement`
# clone). The per-iteration `{:cont, value, next_state}` destructure made the
# boxed head an OWNED fresh clone (residual-3 deep-release machinery), so without
# treating the cons element argument as consumed it is both consumed-by-cons AND
# scope-exit-dropped -> `invalid free` under `Memory.Tracking`.
#
# The predicate keeps the SECOND op (make_adder(2)) — it adds more than 1 — so
# the result list holds one boxed `Callable`, which we then invoke.
#
# Expected (both managers):
#   filter keeps make_adder(2); applied to 10 => 12
#   prints 12, exit 0, ZERO leaks, NO double-free.

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
  # Keep the ops that add MORE than 1 (i.e. make_adder(2): 0 -> 2 > 1).
  kept = Enum.filter(ops, fn(f :: fn(i64) -> i64) -> Bool { f(0) > 1 })
  keeper = List.get(kept, 0)
  IO.puts(Integer.to_string(keeper(10)))
  0
}
