# FCC Phase 3 — THE CRUX. A boxed (capturing) closure passed where a
# `fn(i64) -> i64` parameter is expected.
#
# `make_adder(5)` returns a CAPTURING closure (it closes over `n`), which
# the desugar boxes as a `Callable({i64}, i64)` existential. `apply(f, v)`
# declares its first parameter as `fn(i64) -> i64`. Today the type checker
# rejects this: "argument 1 expects callable `(i64 -> i64)`, got `Callable`"
# — because a boxed `Callable` protocol_constraint and a `fn(i64) -> i64`
# FunctionType are treated as different types. Phase 3 unifies them: a
# `fn(A) -> R` value's canonical type IS `Callable({A}, R)`, so the boxed
# closure flows into the `fn`-typed parameter and is invoked through the
# box's `call` slot.
#
# Expected (both managers): prints `15`, ZERO leaks, exit 0.

pub struct Adder {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn apply(f :: fn(i64) -> i64, v :: i64) -> i64 {
    f(v)
  }
}

fn main(_args :: [String]) -> u8 {
  add5 = Adder.make_adder(5)
  IO.puts(Integer.to_string(Adder.apply(add5, 10)))
  0
}
