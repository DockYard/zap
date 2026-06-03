# task #361: an untyped int literal in map-value position adopts the value type
# the parameter's Map(Atom, u8) expects. Prints `1`, exit 0.
pub struct M {
  pub fn take(m :: Map(Atom, u8)) -> i64 { Map.size(m) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(M.take(%{k: 5})))
  0
}
