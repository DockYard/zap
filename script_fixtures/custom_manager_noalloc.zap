## Non-allocating program for the memory-manager verification matrix.
## Stack-resident integer arithmetic + IO.puts only; no heap-resident user
## value, so NoOp/Leak run cleanly and ARC/Arena/Tracking elide/bulk-free.
pub struct NoAlloc {
  pub fn add(a :: i64, b :: i64) -> i64 {
    a + b
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(NoAlloc.add(40, 2)))
  0
}
