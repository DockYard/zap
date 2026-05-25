# Phase 0: a `type` alias whose body is a generic-container application
# `type Ints = [i64]` (List(i64)) resolves to the list type. Used as a
# parameter type and indexed/measured through the List stdlib.
#
# Expected output:
#   3
#   1

type Ints = [i64]

pub struct Summer {
  pub fn count(xs :: Ints) -> i64 {
    List.length(xs)
  }

  pub fn first(xs :: Ints) -> i64 {
    List.head(xs)
  }
}

fn main(_args :: [String]) -> u8 {
  values = [1, 2, 3]
  IO.puts(Integer.to_string(Summer.count(values)))
  IO.puts(Integer.to_string(Summer.first(values)))
  0
}
