# FCC Phase 5 — boxed-closure LOCAL live across an `Enum.*` combinator.
#
# `f = A.mk(5)` binds a BOXED capturing `Callable` to a local, then a
# combinator (`Enum.map` / `Enum.filter`) runs in the SAME scope, and `f` is
# invoked AFTER the combinator. The combinator's callback is itself a nested
# closure built mid-body; that nested build must NOT wipe the enclosing
# function's boxed-existential ownership state, or `f`'s scope-exit
# `.protocol_box_drop` is dropped (a leak under `Memory.Tracking`) and its
# dispatch site borrows instead of retaining.
#
# Two boxed locals (`f`, `g`) live across two distinct combinators to exercise
# the full save/restore. Expected (both managers): prints
#   12   (Enum.map [1,2,3] doubled = [2,4,6], sum = 12)
#   7    (Enum.filter [1,2,3,4] keep >2 = [3,4], sum = 7)
#   15   (boxed f: 10 + 5)
#   101  (boxed g: 1 + 100)
# exit 0, leak-free.

pub struct A {
  pub fn mk(n :: i64) -> fn(i64) -> i64 {
    fn(x :: i64) -> i64 { x + n }
  }
}

fn main(_args :: [String]) -> u8 {
  f = A.mk(5)
  g = A.mk(100)
  doubled = Enum.map([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
  filtered = Enum.filter([1, 2, 3, 4], fn(x :: i64) -> Bool { x > 2 })
  IO.puts(Integer.to_string(Enum.sum(doubled)))
  IO.puts(Integer.to_string(Enum.sum(filtered)))
  IO.puts(Integer.to_string(f(10)))
  IO.puts(Integer.to_string(g(1)))
  0
}
