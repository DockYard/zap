# FCC Phase 1 — a zero-argument capturing closure as a boxed `Callable`.
#
# Exercises the empty-tuple `{}` arity encoding for a `fn() -> i64`
# closure: the `Callable` instantiation is `Callable({}, i64)`, the vtable
# `call` slot takes a zero-element tuple, and the call `make()()` packs no
# arguments into `{}` dispatched through the box.
#
# Expected (Memory.ARC, the default): prints `42`, exit 0.

pub struct ConstantMaker {
  pub fn make(value :: i64) -> fn() -> i64 {
    fn() -> i64 { value }
  }
}

fn main(args :: [String]) -> u8 {
  get42 = ConstantMaker.make(42)
  IO.puts(Integer.to_string(get42()))
  0
}
