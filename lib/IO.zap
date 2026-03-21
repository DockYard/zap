defmodule IO do
  def puts(message :: String) :: String do
    :zig.println(message)
  end
end
