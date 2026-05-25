# FCC Phase 2 — A boxed closure that is BOUND and then both aliased and
# stored into a list the program keeps. `base` is bound, `kept = base`
# aliases it (independent clone-on-share owner), and a one-element list
# `keep = [base]` stores it as a third owner; the list element is later
# extracted and invoked. Every owning path drops exactly once: the
# clone owner (`kept`), the list element (freed by its extracted owner),
# and the surviving binding/value moved into the list.
#
# Exercises a value that is simultaneously kept as a binding alias AND held
# in a container (gap-loop "returned and kept").
#
# Expected under BOTH managers: prints `7`, `7`, `7`, ZERO leaks, exit 0.

pub struct Maker {
  pub fn adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  base = Maker.adder(2)
  kept = base
  keep = [base]
  IO.puts(Integer.to_string(kept(5)))
  picked = List.get(keep, 0)
  IO.puts(Integer.to_string(picked(5)))
  IO.puts(Integer.to_string(kept(5)))
  0
}
