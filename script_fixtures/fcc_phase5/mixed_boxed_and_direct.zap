# FCC Phase 5 — Item 5. Mixed BOXED and DIRECT closure representations in ONE
# program, exercising both ends of the FCC representation duality together:
#   - DIRECT (devirtualized #201/Gap E): a non-capturing closure passed as a
#     combinator callback to `Enum.map` (a `fn`-typed param — bare fn-ptr, no
#     box, no `__closure_` synthesis).
#   - BOXED (Callable existential): a CAPTURING closure returned from a factory
#     and a CAPTURING closure stored in a `fn`-typed struct field.
# All three coexist and run in the same `main`.
#
# Expected (both managers): prints
#   12   (Enum.map [1,2,3] doubled = [2,4,6], Enum.sum = 12)
#   110  (boxed factory-returned capturing closure: 10 + 100)
#   25   (boxed field-stored capturing closure: 20 + 5)
# exit 0, leak-free.

pub struct Maker {
  pub fn adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

pub struct Box {
  op :: fn(i64) -> i64
}

fn main(_args :: [String]) -> u8 {
  # DIRECT: non-capturing combinator callback (devirtualized, no box).
  doubled = Enum.map([1, 2, 3], fn(v :: i64) -> i64 { v * 2 })
  IO.puts(Integer.to_string(Enum.sum(doubled)))

  # BOXED: factory-returned capturing closure.
  add100 = Maker.adder(100)
  IO.puts(Integer.to_string(add100(10)))

  # BOXED: capturing closure stored in a struct field.
  b = %Box{op: Maker.adder(5)}
  IO.puts(Integer.to_string(b.op(20)))
  0
}
