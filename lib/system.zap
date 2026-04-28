@doc = """
  Functions for interacting with the operating system.

  Provides access to command-line arguments, environment variables,
  and build-time configuration options.
  """

pub struct System {
  @doc = """
    Returns the number of command-line arguments passed to the program.

    Does not count the program name itself.

    ## Examples

        # Running: zap run my_app -- foo bar
        System.arg_count()  # => 2
    """

  pub fn arg_count() -> i64 {
    :zig.System.arg_count()
  }

  @doc = """
    Returns the command-line argument at the given index.

    Index is zero-based, starting from the first user argument
    (the program name is not included). Returns an empty string
    if the index is out of bounds.

    ## Examples

        # Running: zap run my_app -- hello world
        System.arg_at(0)  # => "hello"
        System.arg_at(1)  # => "world"
    """

  pub fn arg_at(index :: i64) -> String {
    :zig.System.arg_at(index)
  }

  @doc = """
    Reads an environment variable by name.

    Returns the value of the environment variable, or an empty
    string if it is not set.

    ## Examples

        System.get_env("HOME")      # => "/Users/alice"
        System.get_env("UNDEFINED") # => ""
    """

  pub fn get_env(name :: String) -> String {
    :zig.System.get_env(name)
  }

  @doc = """
    Reads a build-time option by name.

    Build options are passed via `-Dkey=value` on the command line.
    Returns an empty string if the option is not set.

    ## Examples

        # Building: zap build my_app -Doptimize=release_fast
        System.get_build_opt("optimize")  # => "release_fast"
    """

  pub fn get_build_opt(name :: String) -> String {
    :zig.System.get_build_opt(name)
  }

  @doc = """
    Returns the current working directory.

    ## Examples

        System.cwd()  # => "/Users/dev/project"
    """

  pub fn cwd() -> String {
    :zig.System.cwd()
  }
}
