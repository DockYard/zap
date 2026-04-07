pub module Atom {
  pub fn to_string(atom :: Atom) -> String {
    :zig.Prelude.atom_name(atom)
  }
}
