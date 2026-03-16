defmodule IO do
  def puts(message) do
    :zig.println(message)
  end
end
