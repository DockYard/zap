# FCC Phase 3 — Residual 5. A struct with a `fn`-typed (boxed `Callable`)
# field, stored in a list. The list-drop deep-releases the struct elements,
# which deep-release their boxed `Callable` fields (Phase-2 box-in-struct +
# box-in-container compose). Each struct's `op` field is an independent owner
# of its boxed closure; the list owns the structs; dropping the list frees
# every box exactly once.
#
# Expected (both managers): prints `13` then `27`, ZERO leaks / no
# invalid-free, exit 0.

pub struct Op {
  f :: fn(i64) -> i64
}

pub struct Maker {
  pub fn adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  ops = [%Op{f: Maker.adder(3)}, %Op{f: Maker.adder(17)}]
  first = List.get(ops, 0)
  second = List.get(ops, 1)
  fa = first.f
  fb = second.f
  IO.puts(Integer.to_string(fa(10)))
  IO.puts(Integer.to_string(fb(10)))
  0
}
