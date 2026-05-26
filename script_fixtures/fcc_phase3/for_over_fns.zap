# FCC Phase 3 — residual 3: a `for` comprehension over a [fn(i64) -> i64] list.
#
# `ops` is a `[fn(i64) -> i64]` = `[Callable({i64}, i64)]`. The comprehension
# binds each boxed `Callable` element to `f` and invokes it; the comprehension
# RESULT-LIST element type is the BODY type (`i64`), not the input element type
# (`ProtocolBox`). This is the element-type-flow case.
#
# Expected (both managers):
#   make_adder(1)(10) -> 11, make_adder(2)(10) -> 12
#   results => [11, 12]
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
  results = for f <- ops { f(10) }
  IO.puts(Integer.to_string(List.get(results, 0)))
  IO.puts(Integer.to_string(List.get(results, 1)))
  0
}
