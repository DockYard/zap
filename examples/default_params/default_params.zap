# Function calls and string operations
#
# Run with:
#   zap run default_params

defmodule DefaultParams do
  def main(_args :: [String]) :: String do
    IO.puts(Http.get("https://example.com"))
    IO.puts(Http.post("https://example.com"))
    IO.puts(Greeter.greet("Alice"))
  end
end
