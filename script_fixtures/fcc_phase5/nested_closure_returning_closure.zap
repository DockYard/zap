# FCC Phase 5 — Item 5. Nested closures: a closure that returns/stores a
# closure. `make_multiplier` returns a boxed capturing closure; that closure is
# stored in a struct field AND in a list element, then both are invoked. Mixes
# the return, field, and list-element boxed-Callable positions in one program.
#
# Expected (both managers): prints
#   30   (field-stored closure: 10 * 3)
#   50   (list-element closure: 10 * 5)
# exit 0, leak-free.

pub struct Box {
  scale :: fn(i64) -> i64
}

pub struct Nest {
  pub fn make_multiplier(factor :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x * factor }
  }
}

fn main(_args :: [String]) -> u8 {
  triple_box = %Box{scale: Nest.make_multiplier(3)}
  IO.puts(Integer.to_string(triple_box.scale(10)))

  multipliers = [Nest.make_multiplier(5)]
  quint = List.get(multipliers, 0)
  IO.puts(Integer.to_string(quint(10)))
  0
}
