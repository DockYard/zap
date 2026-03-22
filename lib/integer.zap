defmodule Integer do
  def to_string(value :: i64) :: String do
    :zig.i64_to_string(value)
  end
end
