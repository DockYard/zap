pub module Atom {
  @doc = """
    Converts an atom to its string name.

    Atoms are interned identifiers. This returns the original string
    that was used to create the atom.

    ## Examples

        Atom.to_string(:ok)     # => "ok"
        Atom.to_string(:error)  # => "error"
    """
  pub fn to_string(atom :: Atom) -> String {
    :zig.Prelude.atom_name(atom)
  }
}
