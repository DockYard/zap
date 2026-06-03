# task #361: a NEGATED untyped integer literal adopts a SIGNED parameter type
# when the negated value fits (`-5` and the i8 minimum `-128` into i8). Prints
# `3` (list length).
pub struct P {
  pub fn count(xs :: [i8]) -> i64 { List.length(xs) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.count([-5, 100, -128])))
  0
}
