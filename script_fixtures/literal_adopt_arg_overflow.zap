# task #361 NEGATIVE: an untyped int literal in argument position that does not
# fit the parameter's declared type is a compile-time overflow error, NOT a
# silent default. 9999 does not fit u8.
pub struct P {
  pub fn takes_u8(x :: u8) -> u8 { x }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.takes_u8(9999)))
  0
}
