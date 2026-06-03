# task #361: untyped int literals in list-element position adopt the element
# type the parameter's [u8] collection expects. Prints `3`, exit 0.
pub struct L {
  pub fn count(xs :: [u8]) -> i64 { List.length(xs) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(L.count([5, 9, 200])))
  0
}
