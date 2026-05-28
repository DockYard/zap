## GC correctness stress: a LIVE deep object graph must survive collections
## triggered by concurrent garbage allocation.
##
## `build_chain/2` constructs a chain of `depth` heap `LinkedNode`s (the live
## graph). `churn/2` then allocates-and-drops a fresh transient chain on every
## iteration (the garbage) while the original live chain stays referenced
## through the recursion's accumulator — so each collection must trace the live
## chain (worklist + interior pointers through `next`) and reclaim ONLY the
## garbage. `chain_sum` over the live chain after the churn proves no live node
## was prematurely freed: the sum must equal `depth * (depth + 1) / 2`.
##
## depth = 500  -> live chain sum = 500*501/2 = 125250
## With 200_000 churn iterations each dropping a 500-node chain, the collector
## runs many times; a single mis-traced live node would corrupt the final sum
## or segfault. Correct output (exit 0):
##
##     125250
pub struct LinkedNode {
  value :: i64
  next :: LinkedNode | nil
}

pub struct GcStress {
  pub fn chain_sum(nil) -> i64 {
    0 :: i64
  }

  pub fn chain_sum(node :: LinkedNode) -> i64 {
    node.value + GcStress.chain_sum(node.next)
  }

  ## Build a `remaining`-deep chain with values counting down, prepended onto
  ## `acc`. The returned chain has `depth` nodes whose values sum to
  ## depth*(depth+1)/2.
  pub fn build_chain(remaining :: i64, acc :: LinkedNode | nil) -> LinkedNode | nil {
    case remaining > 0 {
      true -> GcStress.build_chain(remaining - 1, %LinkedNode{value: remaining, next: acc})
      false -> acc
    }
  }

  ## Allocate-and-drop a fresh 500-node garbage chain each iteration while the
  ## caller's `live` chain remains reachable through this call's argument.
  pub fn churn(iterations :: i64, live :: LinkedNode | nil) -> i64 {
    case iterations > 0 {
      true -> {
        garbage = GcStress.build_chain(500, nil)
        _drop = GcStress.chain_sum(garbage)
        GcStress.churn(iterations - 1, live)
      }
      false -> GcStress.chain_sum(live)
    }
  }
}

fn main(_args :: [String]) -> u8 {
  live = GcStress.build_chain(500, nil)
  result = GcStress.churn(200000, live)
  IO.puts(Integer.to_string(result))
  0
}
