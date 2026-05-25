# FCC Phase 2 — Scenario 3: a heterogeneous `[fn(i64) -> i64]` list mixing
# a non-capturing inline closure and a capturing `make_adder(5)`. Both
# elements box as `Callable({i64}, i64)`. The list owns the boxes; when
# the list is released at scope exit, each element's boxed environment
# must be released exactly once.
#
# This is the Phase-1 canonical fixture re-checked under the leak
# subsystem: before Phase 2 each element's env leaks under Tracking.
#
# Expected under -Dmemory=Memory.Tracking: prints `11` then `15`, ZERO
# leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn adders() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { x + 1 }, Maker.make_adder(5)]
  }
}

fn main(_args :: [String]) -> u8 {
  ops = Maker.adders()
  f0 = List.get(ops, 0)
  f1 = List.get(ops, 1)
  IO.puts(Integer.to_string(f0(10)))
  IO.puts(Integer.to_string(f1(10)))
  0
}
