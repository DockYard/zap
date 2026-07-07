## P3-J2 E4 — manager-monomorphization code-size probe.
##
## A spawn-reachable-shaped allocating subgraph: `driver` calls two helpers,
## each builds and folds heap-allocated `List(i64)` cells in a loop. Under a
## REFCOUNTED (ARC) manifest every cell operation emits retain/release; under a
## BULK_OR_NEVER (Arena) manifest those ops are elided. Compiling this same
## source under `-Dmemory=Memory.ARC` vs `-Dmemory=Memory.Arena` and diffing the
## `__TEXT,__text` section measures the per-reclamation-model header-emission
## delta that a model specialization pays — the E4 datum.
pub struct E4 {
  pub fn build_list(count :: i64) -> List(i64) {
    E4.build_list_from(count, [])
  }

  pub fn build_list_from(count :: i64, acc :: List(i64)) -> List(i64) {
    case count {
      0 -> acc
      _ -> E4.build_list_from(count - 1, [count | acc])
    }
  }

  pub fn sum_list(nil_or_list :: List(i64)) -> i64 {
    E4.sum_from(nil_or_list, 0)
  }

  pub fn sum_from(list :: List(i64), acc :: i64) -> i64 {
    case list {
      [] -> acc
      [head | tail] -> E4.sum_from(tail, acc + head)
    }
  }

  pub fn driver(rounds :: i64) -> i64 {
    E4.driver_from(rounds, 0)
  }

  pub fn driver_from(rounds :: i64, total :: i64) -> i64 {
    case rounds {
      0 -> total
      _ -> E4.driver_from(rounds - 1, total + E4.sum_list(E4.build_list(64)))
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(E4.driver(32)))
  0
}
