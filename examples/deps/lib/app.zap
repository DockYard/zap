defmodule App do
  def main() :: String do
    result = MathLib.add(1, 2)
    Kernel.inspect(result)
  end
end
