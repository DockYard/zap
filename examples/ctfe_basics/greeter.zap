pub module Greeter {
  @greeting :: String = "Hello"
  pub fn greet(name :: String) :: String {
    @greeting <> ", " <> name <> "!"
  }

  @default_name :: String = "World"
  pub fn greet_default() :: String {
    greet(@default_name)
  }
}
