# FCC Phase 2 — Gap-loop scenario: a NESTED list of boxed closures
# (`[[fn(i64) -> i64]]`). When the outer list is dropped, its box-in-container
# deep-release must recurse through each inner list (a reclaimed-at-teardown
# inline-header cell) and deep-release the inner lists' box elements too.
# Partially consumed: only one element of one inner list is extracted.
#
# Expected under -Dmemory=Memory.Tracking: prints `11`, ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn row(base :: i64) -> [fn(i64) -> i64] {
    [Maker.make_adder(base), Maker.make_adder(base + 1)]
  }

  pub fn grid() -> [[fn(i64) -> i64]] {
    [Maker.row(1), Maker.row(10), Maker.row(100)]
  }
}

fn main(_args :: [String]) -> u8 {
  grid = Maker.grid()
  row0 = List.get(grid, 0)
  f = List.get(row0, 0)
  IO.puts(Integer.to_string(f(10)))
  0
}
