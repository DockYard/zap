# task #361: an untyped int literal in map-KEY position adopts the key type the
# parameter's Map(u8, Atom) expects. Prints `1`.
pub struct M {
  pub fn take(m :: Map(u8, Atom)) -> i64 { Map.size(m) }
}

fn main(_args :: [String]) -> u8 {
  IO.puts(Integer.to_string(M.take(%{5 => :x})))
  0
}
