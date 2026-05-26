# FCC Phase 3 — residual 3: Enum.each over a [fn(i64) -> i64] list.
#
# `ops` is a `[fn(i64) -> i64]` = `[Callable({i64}, i64)]`. `Enum.each` invokes
# the callback for side effects; the callback invokes each boxed `Callable`
# element through the box `call` slot and prints the result.
#
# Expected (both managers):
#   make_adder(1)(10) -> 11, make_adder(2)(10) -> 12
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
  Enum.each(ops, fn(f :: fn(i64) -> i64) -> Nil {
    IO.puts(Integer.to_string(f(10)))
    nil
  })
  0
}
