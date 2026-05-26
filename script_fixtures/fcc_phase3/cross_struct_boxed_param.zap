# FCC Phase 3 — cross-struct boxed-`Callable`-param method.
#
# `Higher.apply` takes a boxed `Callable` param `f :: fn(i64) -> i64` and a
# value, invoking the boxed closure. The closure is MANUFACTURED in a DIFFERENT
# struct (`Maker.make_adder`), so `apply` is called CROSS-STRUCT with a boxed
# `Callable` argument. This exercises cross-struct emission + dispatch of a
# method whose parameter is a boxed `Callable`.
#
# Expected (both managers): make_adder(5) applied to 10 via Higher.apply => 15.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

pub struct Higher {
  pub fn apply(f :: fn(i64) -> i64, v :: i64) -> i64 {
    f(v)
  }
}

fn main(args :: [String]) -> u8 {
  adder = Maker.make_adder(5)
  result = Higher.apply(adder, 10)
  IO.puts(Integer.to_string(result))
  0
}
