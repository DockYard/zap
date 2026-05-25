# FCC Phase 2 — Scenario 1 (the canonical leaking case): a `[fn(i64) -> i64]`
# list of three boxed closures where ONLY the first is extracted + invoked.
# The list then drops at scope exit with elements 1 and 2 un-extracted.
#
# Today (before the box-in-container deep-release fix) elements 1 and 2 leak
# under Tracking: List release never deep-releases box elements, and only an
# EXTRACTED owner frees its element. After the fix, the list-drop deep-releases
# the two un-extracted boxes; the extracted first element (cloned-on-share under
# no-refcount, refcount-bumped under ARC) frees itself.
#
# Expected under -Dmemory=Memory.Tracking: prints `11`, ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn ops() -> [fn(i64) -> i64] {
    [Maker.make_adder(1), Maker.make_adder(2), Maker.make_adder(3)]
  }
}

fn main(_args :: [String]) -> u8 {
  ops = Maker.ops()
  first = List.get(ops, 0)
  IO.puts(Integer.to_string(first(10)))
  0
}
