defmodule Runner do
  def hello(word :: String) :: String do
    "Hello" <> " " <> word
  end
end

def main() :: String do
  Runner.hello("World!")
  |> IO.puts()
end
