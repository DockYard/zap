defmodule BinaryPatterns do
  def main() :: String do
    [MarkupParser.parse_node("<div id=top><h1>Hello, Zap!</h1></div>")]
    |> Kernel.inspect()
  end
end
