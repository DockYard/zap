# task #361: a `case` of untyped literals in ARGUMENT position adopts the
# parameter type through every arm. Prints `200`.
pub struct P {
  pub fn take(x :: u8) -> u8 { x }
  pub fn run(n :: i64) -> u8 { P.take(case n { 0 -> 5 _ -> 200 }) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.run(1)))
  0
}
