pub module File {
  @moduledoc = """
    Functions for reading and writing files.

    All paths are relative to the current working directory.
    File operations return empty strings or false on failure.

    ## Examples

        content = File.read("config.txt")
        File.write("output.txt", "Hello, world!")
        File.exists?("config.txt")  # => true
    """

  @doc = """
    Reads the entire contents of a file as a string.
    Returns an empty string if the file cannot be read.

    ## Examples

        File.read("hello.txt")  # => "Hello, world!"
        File.read("missing.txt")  # => ""
    """

  pub fn read(path :: String) -> String {
    :zig.File.file_read(path)
  }

  @doc = """
    Writes a string to a file, creating it if it doesn't exist
    and overwriting if it does. Returns true on success.

    ## Examples

        File.write("output.txt", "Hello!")  # => true
    """

  pub fn write(path :: String, content :: String) -> Bool {
    :zig.File.file_write(path, content)
  }

  @doc = """
    Returns true if the file exists at the given path.

    ## Examples

        File.exists?("build.zap")   # => true
        File.exists?("missing.txt")  # => false
    """

  pub fn exists?(path :: String) -> Bool {
    :zig.File.file_exists(path)
  }

  @doc = """
    Reads the entire contents of a file. Raises if the file cannot be read.

    ## Examples

        File.read!("hello.txt")  # => "Hello, world!"
        File.read!("missing.txt")  # raises RuntimeError
    """

  pub fn read!(path :: String) -> String {
    result = File.read(path)
    case result {
      "" -> raise("File.read! failed: could not read " <> path)
      contents -> contents
    }
  }

  @doc = """
    Deletes a file. Returns true on success.

    ## Examples

        File.rm("temp.txt")  # => true
    """

  pub fn rm(path :: String) -> Bool {
    :zig.File.file_rm(path)
  }

  @doc = """
    Creates a directory. Returns true on success.

    ## Examples

        File.mkdir("output")  # => true
    """

  pub fn mkdir(path :: String) -> Bool {
    :zig.File.file_mkdir(path)
  }

  @doc = """
    Removes an empty directory. Returns true on success.

    ## Examples

        File.rmdir("output")  # => true
    """

  pub fn rmdir(path :: String) -> Bool {
    :zig.File.file_rmdir(path)
  }

  @doc = """
    Renames or moves a file. Returns true on success.

    ## Examples

        File.rename("old.txt", "new.txt")  # => true
    """

  pub fn rename(old_path :: String, new_path :: String) -> Bool {
    :zig.File.file_rename(old_path, new_path)
  }

  @doc = """
    Copies a file. Returns true on success.

    ## Examples

        File.cp("source.txt", "dest.txt")  # => true
    """

  pub fn cp(source :: String, destination :: String) -> Bool {
    :zig.File.file_cp(source, destination)
  }

  @doc = """
    Returns true if the path is a directory.

    ## Examples

        File.dir?("src")     # => true
        File.dir?("main.zap") # => false
    """

  pub fn dir?(path :: String) -> Bool {
    :zig.File.file_is_dir(path)
  }

  @doc = """
    Returns true if the path is a regular file.

    ## Examples

        File.regular?("main.zap") # => true
        File.regular?("src")      # => false
    """

  pub fn regular?(path :: String) -> Bool {
    :zig.File.file_is_regular(path)
  }
}
