pub module String {
  pub fn to_atom(_name :: String) -> Atom {
    :zig.to_atom(_name)
  }

  pub fn to_existing_atom(_name :: String) -> Atom {
    :zig.to_existing_atom(_name)
  }
}
