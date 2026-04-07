pub module String {
  @moduledoc = """
    Functions for working with UTF-8 encoded strings.

    Strings in Zap are immutable byte sequences (`[]const u8` in the
    underlying Zig representation). All operations return new strings
    rather than modifying in place.

    ## Examples

        String.length("hello")              # => 5
        String.contains("hello world", "o") # => true
        String.slice("hello", 0, 3)         # => "hel"
    """

  @doc = """
    Returns the byte length of a string.

    This returns the number of bytes, not the number of Unicode
    codepoints. For ASCII strings, bytes and characters are the same.

    ## Examples

        String.length("hello")  # => 5
        String.length("")       # => 0
    """
  pub fn length(s :: String) -> i64 {
    :zig.ZapString.length(s)
  }

  @doc = """
    Returns the byte at the given index as a single-character string.

    Index is zero-based. Returns an empty string if the index is
    out of bounds.

    ## Examples

        String.byte_at("hello", 0)  # => "h"
        String.byte_at("hello", 4)  # => "o"
        String.byte_at("hello", 99) # => ""
    """
  pub fn byte_at(s :: String, index :: i64) -> String {
    :zig.ZapString.byte_at(s, index)
  }

  @doc = """
    Returns `true` if `haystack` contains `needle` as a substring.

    ## Examples

        String.contains("hello world", "world")  # => true
        String.contains("hello world", "xyz")    # => false
        String.contains("hello", "")             # => true
    """
  pub fn contains(haystack :: String, needle :: String) -> Bool {
    :zig.ZapString.contains(haystack, needle)
  }

  @doc = """
    Returns `true` if the string starts with the given prefix.

    ## Examples

        String.starts_with("hello", "hel")  # => true
        String.starts_with("hello", "world") # => false
    """
  pub fn starts_with(s :: String, prefix :: String) -> Bool {
    :zig.ZapString.startsWith(s, prefix)
  }

  @doc = """
    Returns `true` if the string ends with the given suffix.

    ## Examples

        String.ends_with("hello", "llo")    # => true
        String.ends_with("hello", "world")  # => false
    """
  pub fn ends_with(s :: String, suffix :: String) -> Bool {
    :zig.ZapString.endsWith(s, suffix)
  }

  @doc = """
    Removes leading and trailing whitespace from a string.

    Strips spaces, tabs, newlines, and carriage returns.

    ## Examples

        String.trim("  hello  ")   # => "hello"
    """
  pub fn trim(s :: String) -> String {
    :zig.ZapString.trim(s)
  }

  @doc = """
    Returns a substring from `start` (inclusive) to `end` (exclusive).

    Indices are byte-based and zero-indexed. Out-of-bounds indices
    are clamped to the string length.

    ## Examples

        String.slice("hello world", 0, 5)   # => "hello"
        String.slice("hello world", 6, 11)  # => "world"
    """
  pub fn slice(s :: String, start :: i64, end :: i64) -> String {
    :zig.ZapString.slice(s, start, end)
  }

  @doc = """
    Converts a string to an atom, creating it if it doesn't exist.

    Atoms are interned — each unique string maps to a single atom ID.

    ## Examples

        String.to_atom("ok")    # => :ok
        String.to_atom("error") # => :error
    """
  pub fn to_atom(name :: String) -> Atom {
    :zig.ZapString.to_atom(name)
  }

  @doc = """
    Converts a string to an existing atom.

    Unlike `to_atom/1`, this does not create new atoms. Returns a
    sentinel value if the atom has not been previously interned.

    ## Examples

        String.to_existing_atom("ok")  # => :ok (if :ok exists)
    """
  pub fn to_existing_atom(name :: String) -> Atom {
    :zig.ZapString.to_existing_atom(name)
  }
}
