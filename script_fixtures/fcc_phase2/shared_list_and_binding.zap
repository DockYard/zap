# FCC Phase 2 — A boxed closure shared into a heterogeneous list AND kept as
# a binding. `add5` is bound, invoked directly, then stored as an element of
# a `[fn(i64) -> i64]` list; the list element is later extracted via
# `List.get` and invoked. The list element is freed by its extracted owner
# (`List.get` returns an alias whose scope-exit drop frees the element once);
# the binding `add5` is the surviving owner of the value moved into the list.
# A second binding `also = add5` adds an independent clone-on-share owner.
#
# Combines the binding-alias clone path with the list-storage/extraction path
# (gap-loop "shared in a heterogeneous list + also bound").
#
# Expected under BOTH managers: prints `15` (add5), `15` (also), `15` (from
# the list), ZERO leaks, exit 0.

pub struct Maker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Maker.make_adder(5)
  also = add5
  IO.puts(Integer.to_string(add5(10)))
  IO.puts(Integer.to_string(also(10)))

  # Store the kept closure plus a fresh one into a two-element list (a
  # second owning container) and extract BOTH back: each moved-in element is
  # freed by its own extracted owner, while `also` is the independent
  # clone owner of the binding alias. All owning paths drop exactly once.
  held = [add5, Maker.make_adder(1)]
  picked0 = List.get(held, 0)
  picked1 = List.get(held, 1)
  IO.puts(Integer.to_string(picked0(10)))
  IO.puts(Integer.to_string(picked1(10)))
  0
}
