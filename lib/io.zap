pub module IO {
  @moduledoc = """
    Functions for standard input/output operations.

    `IO` provides the basic building blocks for printing to stdout.
    All functions return their input, making them composable in
    pipe chains.

    ## Examples

        IO.puts("Hello, world!")
        "result" |> IO.puts()
    """

  @doc = """
    Prints a value to standard output followed by a newline.

    The value is converted to its string representation and written
    to stdout. Returns the original message, making it suitable for
    use in pipe chains.

    ## Examples

        IO.puts("Hello, world!")
        # => prints "Hello, world!\n" to stdout

        "result" |> IO.puts()
        # => prints "result\n", returns "result"
    """

  pub fn puts(message :: String) -> String {
    :zig.IO.println(message)
    message
  }

  @doc = """
    Prints a value to standard output without a trailing newline.

    Useful for building output incrementally, such as progress
    indicators or prompts.

    ## Examples

        IO.print_str("loading...")
        # => prints "loading..." without newline
    """

  pub fn print_str(message :: String) -> String {
    :zig.IO.print_str(message)
    message
  }
}
