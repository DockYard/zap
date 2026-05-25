# FCC Phase 2 — Scenario 4: a `[fn(i64) -> i64]` list where SOME elements are
# extracted by `List.get` (and re-extracted: the same index twice, proving
# extraction is non-destructive and each clone is independent) while the REST
# are left for the list-drop. Each box must be freed exactly once: extracted
# clones by their owners, un-extracted originals by the list-drop.
#
# (Iterating a boxed-element list via `for`/`Enum.each` is a separate
# compile-time type-flow limitation tracked for Phase 3; this fixture covers the
# runtime ARC accounting via the supported `List.get` extraction shape.)
#
# Expected under -Dmemory=Memory.Tracking: prints `11`, `12`, `11` again, ZERO
# leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn ops() -> [fn(i64) -> i64] {
    [Maker.make_adder(1), Maker.make_adder(2), Maker.make_adder(3), Maker.make_adder(4)]
  }
}

fn main(_args :: [String]) -> u8 {
  ops = Maker.ops()
  f0 = List.get(ops, 0)
  f1 = List.get(ops, 1)
  # Re-extract index 0: a second independent clone of the same element.
  f0_again = List.get(ops, 0)
  IO.puts(Integer.to_string(f0(10)))
  IO.puts(Integer.to_string(f1(10)))
  IO.puts(Integer.to_string(f0_again(10)))
  # Elements 2 and 3 are never extracted — freed by the list-drop.
  0
}
