# task #361 NEGATIVE: a negative untyped int literal cannot adopt an unsigned
# parameter type. -5 does not fit u8.
pub struct P {
  pub fn takes_u8(x :: u8) -> u8 { x }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.takes_u8(-5)))
  0
}
