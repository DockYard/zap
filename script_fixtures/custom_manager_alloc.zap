## Heap-allocating program for the memory-manager verification matrix.
## Builds a recursive LinkedNode chain (heap-promoted) and sums it across
## recursion frames. Under NoOp this triggers a documented OOM (no manager
## storage); under ARC/Arena/Tracking it runs to completion (sum == 10).
pub struct LinkedNode {
  value :: i64
  next :: LinkedNode | nil
}

pub struct Alloc {
  pub fn chain_sum(nil) -> i64 {
    0 :: i64
  }

  pub fn chain_sum(node :: LinkedNode) -> i64 {
    node.value + Alloc.chain_sum(node.next)
  }
}

fn main(_args :: [String]) -> u8 {
  a = %LinkedNode{value: 4, next: nil}
  b = %LinkedNode{value: 3, next: a}
  c = %LinkedNode{value: 2, next: b}
  list = %LinkedNode{value: 1, next: c}
  IO.puts(Integer.to_string(Alloc.chain_sum(list)))
  0
}
