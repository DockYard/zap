# task #361: untyped FLOAT literals adopt the declared non-default float return
# type, in plain, if-result, and case-result positions. Prints `2.5\n1.5\n3.5`.
pub struct R {
  pub fn plain() -> f32 { 2.5 }
  pub fn from_if(c :: Bool) -> f32 { if c { 1.5 } else { 9.5 } }
  pub fn from_case(n :: i64) -> f32 {
    case n {
      0 -> 3.5
      _ -> 9.5
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Float.to_string(R.plain()))
  IO.puts(Float.to_string(R.from_if(true)))
  IO.puts(Float.to_string(R.from_case(0)))
  0
}
