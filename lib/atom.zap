pub module Atom {
  @moduledoc = """
    Functions for working with atoms.

    Atoms are constants whose name is their value. They are
    interned — each unique name maps to a single atom ID,
    making equality comparison constant-time.

    Atoms are written with a leading colon: `:ok`, `:error`,
    `:my_atom`.

    ## Examples

        :ok == :ok        # => true
        :ok == :error     # => false
        Atom.to_string(:hello)  # => "hello"
    """

  @doc = """
    Converts an atom to its string representation (the name
    without the leading colon).

    ## Examples

        Atom.to_string(:hello)  # => "hello"
        Atom.to_string(:ok)     # => "ok"
    """

  pub fn to_string(atom :: Atom) -> String {
    :zig.Prelude.atom_name(atom)
  }

  @doc = """
    Creates an atom from a string.

    Delegates to `String.to_atom/1`. If the atom doesn't
    already exist, it is created and interned.

    ## Examples

        Atom.from_string("hello")  # => :hello
        Atom.from_string("ok")     # => :ok
    """

  pub fn from_string(name :: String) -> Atom {
    String.to_atom(name)
  }
}
