# Default parameter values
#
# Trailing parameters can have defaults. The compiler generates
# wrapper functions for each valid shorter arity.

defmodule Http do
  def request(url :: String, method :: String = "GET", _timeout :: i64 = 30) :: String do
    method <> " " <> url
  end
end

defmodule Greeter do
  def greet(name :: String, greeting :: String = "Hello", punctuation :: String = "!") :: String do
    greeting <> ", " <> name <> punctuation
  end
end

def main() do
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
