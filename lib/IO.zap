defmodule IO do
  def puts(message :: String) do
    :zig.println(message)
  end
end
