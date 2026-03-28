defmodule Math do
  defmacro double(value :: i64) :: i64 do
    quote do
      unquote(value) + unquote(value)
    end
  end

  def compute(x :: i64) :: i64 do
    double(x * 3)
  end
end

defmodule DoubleMacro do
  def main() :: String do
    Math.compute(5)
    |> Kernel.inspect()
  end
end
