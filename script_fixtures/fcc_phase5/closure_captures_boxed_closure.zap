# FCC Phase 5 — Item 5. A closure capturing ANOTHER (boxed) closure across a
# box boundary, where the captured boxed closure is a factory-built LOCAL (not
# a parameter). `make_adder(base)` returns a boxed capturing `Callable`; the
# enclosing `make_twice_local` binds it to a local `g` and returns a NEW
# capturing closure `fn(x){ g(g(x)) }` whose env holds the boxed `g`. The outer
# box's drop deep-releases the captured inner box exactly once.
#
# Expected (both managers): prints `15` (add5(add5(5)) = add5(10) = 15),
# exit 0, leak-free.

pub struct Nest {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn make_twice_local(base :: i64) -> fn(i64) -> i64 {
    g = Nest.make_adder(base)
    fn(x :: i64) -> i64 { g(g(x)) }
  }
}

fn main(_args :: [String]) -> u8 {
  twice = Nest.make_twice_local(5)
  IO.puts(Integer.to_string(twice(5)))
  0
}
