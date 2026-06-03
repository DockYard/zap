# task #361 NEGATIVE: only LITERALS adopt. A typed i64 binding flowing into a
# narrower u8 parameter must still be a type error.
pub struct P {
  pub fn takes_u8(x :: u8) -> u8 { x }
}

fn main(_args :: [String]) -> u8 {
  n = 5
  IO.puts(Integer.to_string(P.takes_u8(n)))
  0
}
