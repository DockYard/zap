# FCC Phase 1 — a boxed capturing closure invoked with its own result
# (`add3(add3(10))`), exercising repeated dispatch through one box value
# and multiple captures across distinct closure structs.
#
# Expected (Memory.ARC, the default): prints `16`, exit 0.

pub struct MultiCap {
  pub fn make(a :: i64, b :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + a + b }
  }
}

fn main(args :: [String]) -> u8 {
  add3 = MultiCap.make(1, 2)
  IO.puts(Integer.to_string(add3(add3(10))))
  0
}
