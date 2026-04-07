pub module IO {
  @native = "Prelude.println"
  pub fn puts(_message :: String) -> String

  @native = "Prelude.print_str"
  pub fn print_str(_message :: String) -> String
}
