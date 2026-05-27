# FCC Phase 5 — Item 2. A `type`-alias-named function type used in a RETURN
# position. `type Adder = fn(i64) -> i64`; a NON-CAPTURING closure returned
# through the alias stays on the bare-fn-ptr (Gap E direct) path.
#
# Expected (both managers): prints `11` (10 + 1), exit 0, leak-free.

type Adder = fn(i64) -> i64

pub struct AliasReturn {
  pub fn make() -> Adder {
    fn(x :: i64) -> i64 { x + 1 }
  }
}

fn main(_args :: [String]) -> u8 {
  f = AliasReturn.make()
  IO.puts(Integer.to_string(f(10)))
  0
}
