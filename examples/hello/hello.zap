defmodule Runner do
  def hello(word :: String) :: String do
    "Hello" <> " " <> word
  end
end

defmodule Hello do
  def main() :: String do
    Runner.hello("World!")
    |> IO.puts()
  end
end
