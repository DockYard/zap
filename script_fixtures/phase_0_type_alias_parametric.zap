# Phase 0: a parameterized `type` alias `type Pair(t) = {t, t}` must
# substitute its formal `t` with the supplied argument when applied, so
# `Pair(i64)` resolves to the tuple type `{i64, i64}`. Used as a return
# type and destructured.
#
# Expected output:
#   3
#   4

type Pair(t) = {t, t}

pub struct Pairs {
  pub fn make(a :: i64, b :: i64) -> Pair(i64) {
    {a, b}
  }
}

fn main(_args :: [String]) -> u8 {
  p = Pairs.make(3, 4)
  {first, second} = p
  IO.puts(Integer.to_string(first))
  IO.puts(Integer.to_string(second))
  0
}
