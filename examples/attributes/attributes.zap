# Module attributes and @name references
#
# Demonstrates typed attributes, marker attributes, and compile-time
# substitution of @name references in function bodies.
# Each @attr must be placed immediately before the function that uses it.
#
# Run with:
#   zap run attributes

defmodule Attributes do
  @moduledoc :: String = "Attribute examples"

  @doc :: String = "Entry point"
  def main(_args :: [String]) :: String do
    IO.puts("App: " <> Config.app_name())
    IO.puts("Timeout: " <> Integer.to_string(Config.timeout()))
    IO.puts("Max retries: " <> Integer.to_string(Config.max_retries()))
  end
end
