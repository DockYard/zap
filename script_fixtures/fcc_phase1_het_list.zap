# FCC Phase 1 — the canonical heterogeneous-list scenario.
#
# A list typed `[fn(i64) -> i64]` mixes a NON-CAPTURING inline closure
# (`fn(x) -> { x + 1 }`) with a CAPTURING one returned by `make_adder(5)`.
# Every element resolves to a boxed `Callable({i64}, i64)` existential, so
# the list is homogeneous in `ProtocolBox`. Reading an element out of the
# list and invoking it must dispatch through the box's `call` slot — both
# as an inline-indexed call `List.get(ops, i)(v)` AND as a bound call
# `f = List.get(ops, i); f(v)`.
#
# (Zap locals are untyped — type inference only — so the `[fn ...]` element
# type is supplied by `ops/0`'s declared return type, which drives the
# list literal's elements to box as `Callable`. This is the realizable
# spelling of the plan's `ops :: [fn(i64) -> i64] = [...]` example.)
#
# Expected (Memory.ARC, the default):
#   List.get(ops, 0)(10) -> 11   (inline closure, non-capturing)
#   List.get(ops, 1)(10) -> 15   (make_adder(5), capturing)
#   bound f0(10) -> 11
#   bound f1(10) -> 15
# prints 11, 15, 11, 15, exit 0.

pub struct AdderMaker {
  pub fn make_adder(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }

  pub fn ops() -> [fn(i64) -> i64] {
    [fn(x :: i64) -> i64 { x + 1 }, AdderMaker.make_adder(5)]
  }
}

fn main(args :: [String]) -> u8 {
  ops = AdderMaker.ops()

  # Inline-indexed calls: List.get(ops, i)(v)
  IO.puts(Integer.to_string(List.get(ops, 0)(10)))
  IO.puts(Integer.to_string(List.get(ops, 1)(10)))

  # Bound calls: f = List.get(ops, i); f(v)
  f0 = List.get(ops, 0)
  f1 = List.get(ops, 1)
  IO.puts(Integer.to_string(f0(10)))
  IO.puts(Integer.to_string(f1(10)))
  0
}
