# task #361: untyped int literal adopts the param type through nested calls.
# P.takes_u8(P.id_u8(5)) prints `5`, exit 0.
pub struct P {
  pub fn takes_u8(x :: u8) -> u8 { x }
  pub fn id_u8(x :: u8) -> u8 { x }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.takes_u8(P.id_u8(5))))
  0
}
