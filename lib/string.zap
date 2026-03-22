defmodule String do
  def to_atom(name :: String) :: Atom do
    :zig.to_atom(name)
  end

  def to_existing_atom(name :: String) :: Atom do
    :zig.to_existing_atom(name)
  end
end
