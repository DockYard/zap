# task #361: an untyped float literal in function-argument position adopts the
# parameter's declared float type (f32). Prints a float, exit 0.
pub struct P {
  pub fn takes_f32(x :: f32) -> f32 { x }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Float.to_string(P.takes_f32(3.5)))
  0
}
