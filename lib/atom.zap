pub module Atom {
  pub fn to_string(_atom :: Atom) -> String {
    :zig.atom_name(_atom)
  }
}
