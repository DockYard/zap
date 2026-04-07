pub module IO {
  @doc = """
    Prints a message to stdout followed by a newline.
    """
  pub fn puts(message :: String) -> String {
    :zig.Prelude.println(message)
    message
  }

  @doc = """
    Prints a message to stdout without a trailing newline.
    """
  pub fn print_str(message :: String) -> String {
    :zig.Prelude.print_str(message)
    message
  }
}
