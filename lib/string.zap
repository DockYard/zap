pub module String {
  pub fn to_atom(name :: String) :: Atom {
    :zig.to_atom(name)
  }

  pub fn to_existing_atom(name :: String) :: Atom {
    :zig.to_existing_atom(name)
  }
}
