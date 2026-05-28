## Bounded-RSS proof for the conservative tracing GC (`Memory.GC`, TRACED).
##
## `allocate_and_drop/2` is a tail-recursive loop (O(1) stack under TCO) that,
## on every iteration, builds a fresh heap-resident `LinkedNode` chain, sums it
## (so the chain is genuinely live across the `chain_sum` call), then recurses
## carrying ONLY the integer counter + accumulator. The chain from the previous
## iteration is therefore unreachable garbage the moment the next iteration
## begins — nothing holds a reference to it.
##
## Under `Memory.GC` the collector reclaims that garbage as live-heap bytes
## cross the growth threshold, so resident memory stays BOUNDED across all
## iterations regardless of how large the iteration count is. Under `Memory.Leak`
## (and `Memory.NoOp`, which OOMs) the same allocations are never reclaimed, so
## resident memory grows without bound. The verification harness samples peak
## RSS for each manager and asserts the GC build stays bounded while Leak grows.
##
## Expected stdout (the accumulated per-iteration chain sums, mod-free i64):
##
##     <iterations> * 10
pub struct LinkedNode {
  value :: i64
  next :: LinkedNode | nil
}

pub struct GcLoop {
  pub fn chain_sum(nil) -> i64 {
    0 :: i64
  }

  pub fn chain_sum(node :: LinkedNode) -> i64 {
    node.value + GcLoop.chain_sum(node.next)
  }

  ## Build a fresh 4-node chain (values 1..4, sum 10) — a heap allocation that
  ## becomes garbage as soon as this function returns.
  pub fn build_and_sum() -> i64 {
    a = %LinkedNode{value: 4, next: nil}
    b = %LinkedNode{value: 3, next: a}
    c = %LinkedNode{value: 2, next: b}
    list = %LinkedNode{value: 1, next: c}
    GcLoop.chain_sum(list)
  }

  pub fn allocate_and_drop(iterations :: i64, acc :: i64) -> i64 {
    case iterations > 0 {
      true -> GcLoop.allocate_and_drop(iterations - 1, acc + GcLoop.build_and_sum())
      false -> acc
    }
  }
}

fn main(_args :: [String]) -> u8 {
  ## 2_000_000 iterations × a 4-node chain each = 8_000_000 transient heap
  ## objects. Carried live, that is hundreds of MB; reclaimed, it is bounded.
  total = GcLoop.allocate_and_drop(2000000, 0)
  IO.puts(Integer.to_string(total))
  0
}
