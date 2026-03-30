defmodule DoubleMacro do
  def main() :: String do
    Math.compute(5)
    |> Kernel.inspect()
  end
end
