defmodule Atom do
  def to_string(atom :: Atom) :: String do
    :zig.atom_name(atom)
  end
end
