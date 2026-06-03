# task #361: untyped int literals adopt through NESTED list element positions
# ([[u8]]). Prints `2`.
pub struct P {
  pub fn count(xs :: [[u8]]) -> i64 { List.length(xs) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(P.count([[5], [200]])))
  0
}
