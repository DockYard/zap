pub module Atom {
  pub fn to_string(atom :: Atom) -> String {
    :zig.atom_name(atom)
  }
}
