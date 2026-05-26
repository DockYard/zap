# FCC Phase 3 — residual 3: Enum.map over a [fn(i64) -> i64] list.
#
# `ops` is a `[fn(i64) -> i64]` = `[Callable({i64}, i64)]`. Each element is a
# boxed `Callable` existential. The callback `fn(f) { f(10) }` takes a boxed
# `Callable` element and INVOKES it (dispatching through the box `call` slot),
# producing an `i64`. `Enum.map` therefore produces a `[i64]` whose element
# type is the callback BODY type, not the input element type.
#
# Expected (both managers):
#   make_adder(1) -> +1, make_adder(2) -> +2, applied to 10
#   => [11, 12]
#   prints 11, 12, exit 0.

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
  results = Enum.map(ops, fn(f :: fn(i64) -> i64) -> i64 { f(10) })
  IO.puts(Integer.to_string(List.get(results, 0)))
  IO.puts(Integer.to_string(List.get(results, 1)))
  0
}
