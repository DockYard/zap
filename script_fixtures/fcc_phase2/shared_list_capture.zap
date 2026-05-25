# FCC Phase 2 — Shared boxed closure capturing a LIST. `summer` captures a
# `[i64]` and reads two elements; it is aliased into `also` and BOTH are
# invoked. Each binding is an independent owner of the boxed environment
# (which holds the captured list cell). Under a no-refcount manager the share
# clones the env but KEEPS the same captured list-cell pointer and registers
# a new persistent owner via the cell's refcount: an inline-header List cell
# is never eagerly freed under a no-refcount manager (reclaimed at teardown),
# so two envs aliasing it cannot double-free it. Under a refcount manager the
# extra owner is a real refcount bump.
#
# Exercises a closure capturing an ARC-managed COLLECTION (List) shared across
# owners — the captured inline-header-cell child path of the env clone.
#
# Expected under BOTH managers: prints `31` twice, ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_summer(xs :: [i64]) -> fn(i64) -> i64 {
    fn(base :: i64) -> i64 { base + List.get(xs, 0) + List.get(xs, 1) }
  }
}

fn main(_args :: [String]) -> u8 {
  summer = Maker.make_summer([10, 20])
  also = summer
  IO.puts(Integer.to_string(summer(1)))
  IO.puts(Integer.to_string(also(1)))
  0
}
