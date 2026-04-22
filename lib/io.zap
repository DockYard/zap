pub module IO {
  pub union Mode {
    Raw
    Normal
  }

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

  @doc = """
    Reads a line from standard input.

    Returns the line without the trailing newline.
    Returns an empty string on EOF.

    ## Examples

        name = IO.gets()
        IO.puts("Hello, " <> name)
    """

  pub fn gets() -> String {
    :zig.IO.gets()
  }

  @doc = """
    Prints a message to standard error followed by a newline.

    Useful for logging and error messages that should not
    mix with normal output.

    ## Examples

        IO.warn("something went wrong")
    """

  pub fn warn(message :: String) -> String {
    :zig.IO.warn(message)
    message
  }

  @doc = """
    Switches the terminal input mode.

    ## Examples

        IO.mode(Mode.Raw)      # keypress-at-a-time, no echo
        key = IO.get_char()
        IO.mode(Mode.Normal)   # restore line-buffered mode
    """

  pub fn mode(mode_value :: Mode) -> Mode {
    :zig.IO.set_terminal_mode(mode_value)
    mode_value
  }

  @doc = """
    Switches terminal mode, runs the callback, then restores
    normal mode automatically.

    ## Examples

        IO.mode(Mode.Raw, fn() -> i64 {
          key = IO.get_char()
          IO.puts("You pressed: " <> key)
          0
        })
    """

  pub fn mode(mode_value :: Mode, callback :: ( -> result)) -> result {
    :zig.IO.set_terminal_mode(mode_value)
    result = callback()
    :zig.IO.set_terminal_mode(Mode.Normal)
    result
  }

  @doc = """
    Reads a single character from standard input.

    In raw mode, returns immediately after one keypress.
    In normal mode, blocks until Enter then returns the first character.

    Returns a single-character string, or empty string on EOF.

    ## Examples

        IO.mode(1)
        key = IO.get_char()
        IO.mode(0)
    """

  pub fn get_char() -> String {
    :zig.IO.get_char()
  }

  @doc = """
    Non-blocking read of a single character from standard input.

    Returns a single-character string if a key is available, or
    an empty string if no input is waiting. Must be in raw mode
    for meaningful use.

    ## Examples

        IO.mode(Mode.Raw)
        key = IO.try_get_char()
        if key == "" {
          IO.puts("no key pressed")
        }
    """

  pub fn try_get_char() -> String {
    :zig.IO.try_get_char()
  }
}
