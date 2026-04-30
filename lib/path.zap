pub struct Path {
  @structdoc = """
    Functions for manipulating file system paths.

    Most functions are pure string manipulation. `Path.glob/1` reads
    the file system and returns matching paths in deterministic sorted
    order.

    ## Examples

        Path.join("src", "main.zap")  # => "src/main.zap"
        Path.basename("/usr/bin/zap")  # => "zap"
        Path.dirname("/usr/bin/zap")   # => "/usr/bin"
        Path.extname("main.zap")       # => ".zap"
        Path.glob("lib/**/*.zap")      # => ["lib/path.zap", ...]
    """

  @fndoc = """
    Joins two path segments with a separator.

    ## Examples

        Path.join("src", "main.zap")  # => "src/main.zap"
        Path.join("src/", "main.zap") # => "src/main.zap"
    """

  pub fn join(left :: String, right :: String) -> String {
    :zig.Path.join(left, right)
  }

  @fndoc = """
    Returns the last component of a path.

    ## Examples

        Path.basename("/usr/bin/zap")  # => "zap"
        Path.basename("main.zap")      # => "main.zap"
    """

  pub fn basename(path :: String) -> String {
    :zig.Path.basename(path)
  }

  @fndoc = """
    Returns the directory component of a path.

    ## Examples

        Path.dirname("/usr/bin/zap")  # => "/usr/bin"
        Path.dirname("main.zap")      # => "."
    """

  pub fn dirname(path :: String) -> String {
    :zig.Path.dirname(path)
  }

  @fndoc = """
    Returns the file extension including the dot.

    ## Examples

        Path.extname("main.zap")   # => ".zap"
        Path.extname("Makefile")   # => ""
    """

  pub fn extname(path :: String) -> String {
    :zig.Path.extname(path)
  }

  @fndoc = """
    Returns paths matching a glob pattern as a sorted list of strings.

    Supports `*`, `?`, and recursive `**` wildcards. Relative patterns
    return relative paths. If no paths match, returns an empty list.

    ## Examples

        Path.glob("lib/*.zap")    # => ["lib/atom.zap", ...]
        Path.glob("lib/**/*.zap") # => ["lib/list/enumerable.zap", ...]
        Path.glob("missing/*")    # => []
    """

  pub fn glob(pattern :: String) -> [String] {
    :zig.Prim.glob(pattern)
  }
}
