@doc = """
  Functions for manipulating file system paths.

  All operations are pure string manipulation — they do not
  access the file system.

  ## Examples

      Path.join("src", "main.zap")  # => "src/main.zap"
      Path.basename("/usr/bin/zap")  # => "zap"
      Path.dirname("/usr/bin/zap")   # => "/usr/bin"
      Path.extname("main.zap")       # => ".zap"
  """

pub struct Path {
  @doc = """
    Joins two path segments with a separator.

    ## Examples

        Path.join("src", "main.zap")  # => "src/main.zap"
        Path.join("src/", "main.zap") # => "src/main.zap"
    """

  pub fn join(left :: String, right :: String) -> String {
    :zig.Path.path_join(left, right)
  }

  @doc = """
    Returns the last component of a path.

    ## Examples

        Path.basename("/usr/bin/zap")  # => "zap"
        Path.basename("main.zap")      # => "main.zap"
    """

  pub fn basename(path :: String) -> String {
    :zig.Path.path_basename(path)
  }

  @doc = """
    Returns the directory component of a path.

    ## Examples

        Path.dirname("/usr/bin/zap")  # => "/usr/bin"
        Path.dirname("main.zap")      # => "."
    """

  pub fn dirname(path :: String) -> String {
    :zig.Path.path_dirname(path)
  }

  @doc = """
    Returns the file extension including the dot.

    ## Examples

        Path.extname("main.zap")   # => ".zap"
        Path.extname("Makefile")   # => ""
    """

  pub fn extname(path :: String) -> String {
    :zig.Path.path_extname(path)
  }
}
