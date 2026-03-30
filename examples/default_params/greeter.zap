defmodule Greeter do
  def greet(name :: String, greeting :: String = "Hello", punctuation :: String = "!") :: String do
    greeting <> ", " <> name <> punctuation
  end
end
