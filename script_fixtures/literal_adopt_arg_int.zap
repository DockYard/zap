# task #361: an untyped int literal in function-argument position adopts the
# parameter's declared integer type (u8), range-checked. Prints `5`, exit 0.
pub struct P {
  pub fn takes_u8(x :: u8) -> u8 { x }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.takes_u8(5)))
  0
}
