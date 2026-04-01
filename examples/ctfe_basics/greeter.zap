defmodule Greeter do
  @greeting :: String = "Hello"
  def greet(name :: String) :: String do
    @greeting <> ", " <> name <> "!"
  end

  @default_name :: String = "World"
  def greet_default() :: String do
    greet(@default_name)
  end
end
