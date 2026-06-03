# task #361: an `if`/`else` of untyped literals in ARGUMENT position adopts the
# parameter type through both arms (the value-context analog of the
# return-position rule). Prints `5`.
pub struct P {
  pub fn take(x :: u8) -> u8 { x }
  pub fn run(c :: Bool) -> u8 { P.take(if c { 5 } else { 9 }) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.run(true)))
  0
}
