# task #361: untyped int literals adopt the declared non-i64 return type, in
# plain, if-result and case-result positions. Prints `5\n5\n5`, exit 0.
pub struct R {
  pub fn plain() -> u8 { 5 }
  pub fn from_if(c :: Bool) -> u8 { if c { 5 } else { 9 } }
  pub fn from_case(n :: i64) -> u8 {
    case n {
      0 -> 5
      _ -> 9
    }
  }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(R.plain()))
  IO.puts(Integer.to_string(R.from_if(true)))
  IO.puts(Integer.to_string(R.from_case(0)))
  0
}
