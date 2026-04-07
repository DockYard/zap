pub module IO {
  @doc = """
    Prints a message to stdout followed by a newline.
    """
  @native = "Prelude.println"
  pub fn puts(_message :: String) -> String

  @doc = """
    Prints a message to stdout without a trailing newline.
    """
  @native = "Prelude.print_str"
  pub fn print_str(_message :: String) -> String
}
