# FCC Phase 2 — Scenario 2: a `[fn(i64) -> i64]` list of boxed closures that is
# built and then dropped WITHOUT extracting any element. Every box element must
# be deep-released by the list-drop.
#
# Expected under -Dmemory=Memory.Tracking: prints `3` (the length), ZERO leaks,
# exit 0.

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
  IO.puts(Integer.to_string(List.length(ops)))
  0
}
