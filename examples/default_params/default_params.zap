defmodule DefaultParams do
  def main() :: String do
    # All defaults
    IO.puts(Http.request("https://example.com"))

    # Override one default
    IO.puts(Http.request("https://example.com", "POST"))

    # Override all defaults
    IO.puts(Http.request("https://example.com", "PUT", 60 :: i64))

    # Greeting with all defaults
    IO.puts(Greeter.greet("Alice"))

    # Override greeting
    IO.puts(Greeter.greet("Bob", "Hey"))

    # Override everything
    IO.puts(Greeter.greet("Charlie", "Yo", "!!!"))
  end
end
