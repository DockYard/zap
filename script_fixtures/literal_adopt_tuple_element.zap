# task #361: untyped int literals in tuple-element position adopt the element
# types the parameter's {u8, u8} tuple expects (position-wise). Prints `ok`.
pub struct P {
  pub fn take(t :: {u8, u8}) -> i64 { 0 }
}

fn main(_args :: [String]) -> u8 {
  _z = P.take({5, 200})
  IO.puts("ok")
  0
}
