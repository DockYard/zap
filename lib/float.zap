defmodule Float do
  def to_string(value :: f64) :: String do
    :zig.f64_to_string(value)
  end
end
