@doc = """
  Functions for working with UTF-8 encoded strings.

  Strings in Zap are immutable byte sequences (`[]const u8` in the
  underlying Zig representation). All operations return new strings
  rather than modifying in place.

  ## Examples

      String.length("hello")              # => 5
      String.contains?("hello world", "o") # => true
      String.slice("hello", 0, 3)         # => "hel"
  """

pub struct String {
  @doc = """
    Returns the byte length of a string.

    This returns the number of bytes, not the number of Unicode
    codepoints. For ASCII strings, bytes and characters are the same.

    ## Examples

        String.length("hello")  # => 5
        String.length("")       # => 0
    """

  pub fn length(s :: String) -> i64 {
    :zig.String.length(s)
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
    :zig.String.byte_at(s, index)
  }

  @doc = """
    Returns `true` if `haystack` contains `needle` as a substring.

    ## Examples

        String.contains?("hello world", "world")  # => true
        String.contains?("hello world", "xyz")    # => false
        String.contains?("hello", "")             # => true
    """

  pub fn contains?(haystack :: String, needle :: String) -> Bool {
    :zig.String.contains(haystack, needle)
  }

  @doc = """
    Returns `true` if the string starts with the given prefix.

    ## Examples

        String.starts_with?("hello", "hel")   # => true
        String.starts_with?("hello", "world") # => false
    """

  pub fn starts_with?(s :: String, prefix :: String) -> Bool {
    :zig.String.startsWith(s, prefix)
  }

  @doc = """
    Returns `true` if the string ends with the given suffix.

    ## Examples

        String.ends_with?("hello", "llo")    # => true
        String.ends_with?("hello", "world")  # => false
    """

  pub fn ends_with?(s :: String, suffix :: String) -> Bool {
    :zig.String.endsWith(s, suffix)
  }

  @doc = """
    Removes leading and trailing whitespace from a string.

    Strips spaces, tabs, newlines, and carriage returns.

    ## Examples

        String.trim("  hello  ")   # => "hello"
    """

  pub fn trim(s :: String) -> String {
    :zig.String.trim(s)
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
    :zig.String.slice(s, start, end)
  }

  @doc = """
    Converts a string to an atom, creating it if it doesn't exist.

    Atoms are interned — each unique string maps to a single atom ID.

    ## Examples

        String.to_atom("ok")    # => :ok
        String.to_atom("error") # => :error
    """

  pub fn to_atom(name :: String) -> Atom {
    :zig.String.to_atom(name)
  }

  @doc = """
    Converts a string to an existing atom.

    Unlike `to_atom/1`, this does not create new atoms. Returns a
    sentinel value if the atom has not been previously interned.

    ## Examples

        String.to_existing_atom("ok")  # => :ok (if :ok exists)
    """

  pub fn to_existing_atom(name :: String) -> Atom {
    :zig.String.to_existing_atom(name)
  }

  @doc = """
    Converts all characters to uppercase.

    Only affects ASCII letters (a-z).

    ## Examples

        String.upcase("hello")      # => "HELLO"
        String.upcase("Hello World") # => "HELLO WORLD"
        String.upcase("123")        # => "123"
    """

  pub fn upcase(s :: String) -> String {
    :zig.String.upcase(s)
  }

  @doc = """
    Converts all characters to lowercase.

    Only affects ASCII letters (A-Z).

    ## Examples

        String.downcase("HELLO")      # => "hello"
        String.downcase("Hello World") # => "hello world"
        String.downcase("123")        # => "123"
    """

  pub fn downcase(s :: String) -> String {
    :zig.String.downcase(s)
  }

  @doc = """
    Reverses the bytes of a string.

    ## Examples

        String.reverse("hello")  # => "olleh"
        String.reverse("abc")    # => "cba"
        String.reverse("")       # => ""
    """

  pub fn reverse(s :: String) -> String {
    :zig.String.reverse_string(s)
  }

  @doc = """
    Replaces all occurrences of `pattern` with `replacement`.

    ## Examples

        String.replace("hello world", "world", "zap")  # => "hello zap"
        String.replace("aaa", "a", "bb")                # => "bbbbbb"
        String.replace("hello", "xyz", "abc")           # => "hello"
    """

  pub fn replace(s :: String, pattern :: String, replacement :: String) -> String {
    :zig.String.replace_string(s, pattern, replacement)
  }

  @doc = """
    Returns the index of the first occurrence of `needle` in the
    string, or -1 if not found.

    ## Examples

        String.index_of("hello world", "world")  # => 6
        String.index_of("hello", "xyz")           # => -1
        String.index_of("hello", "")              # => 0
    """

  pub fn index_of(haystack :: String, needle :: String) -> i64 {
    :zig.String.index_of(haystack, needle)
  }

  @doc = """
    Pads the string on the left to reach the target length using
    the given padding character.

    ## Examples

        String.pad_leading("42", 5, "0")   # => "00042"
        String.pad_leading("hello", 3, " ") # => "hello"
    """

  pub fn pad_leading(s :: String, total_length :: i64, pad_char :: String) -> String {
    :zig.String.pad_leading(s, total_length, pad_char)
  }

  @doc = """
    Pads the string on the right to reach the target length using
    the given padding character.

    ## Examples

        String.pad_trailing("hi", 5, ".")   # => "hi..."
        String.pad_trailing("hello", 3, " ") # => "hello"
    """

  pub fn pad_trailing(s :: String, total_length :: i64, pad_char :: String) -> String {
    :zig.String.pad_trailing(s, total_length, pad_char)
  }

  @doc = """
    Repeats a string the given number of times.

    ## Examples

        String.repeat("ab", 3)  # => "ababab"
        String.repeat("x", 5)   # => "xxxxx"
        String.repeat("hi", 0)  # => ""
    """

  pub fn repeat(s :: String, count :: i64) -> String {
    :zig.String.repeat_string(s, count)
  }

  @doc = """
    Parses a string into an integer. Returns 0 if the string
    is not a valid integer.

    Delegates to `Integer.parse/1`.

    ## Examples

        String.to_integer("42")    # => 42
        String.to_integer("hello") # => 0
    """

  pub fn to_integer(s :: String) -> i64 {
    Integer.parse(s)
  }

  @doc = """
    Parses a string into a float. Returns 0.0 if the string
    is not a valid float.

    Delegates to `Float.parse/1`.

    ## Examples

        String.to_float("3.14")    # => 3.14
        String.to_float("hello")   # => 0.0
    """

  pub fn to_float(s :: String) -> f64 {
    Float.parse(s)
  }

  @doc = """
    Capitalizes the first character and lowercases the rest.

    Only affects ASCII letters.

    ## Examples

        String.capitalize("hello")   # => "Hello"
        String.capitalize("HELLO")   # => "Hello"
        String.capitalize("")        # => ""
    """

  pub fn capitalize(s :: String) -> String {
    :zig.String.capitalize(s)
  }

  @doc = """
    Removes leading whitespace from a string.

    Strips spaces, tabs, newlines, and carriage returns from
    the beginning only.

    ## Examples

        String.trim_leading("  hello  ")  # => "hello  "
        String.trim_leading("hello")       # => "hello"
    """

  pub fn trim_leading(s :: String) -> String {
    :zig.String.trim_leading(s)
  }

  @doc = """
    Removes trailing whitespace from a string.

    Strips spaces, tabs, newlines, and carriage returns from
    the end only.

    ## Examples

        String.trim_trailing("  hello  ")  # => "  hello"
        String.trim_trailing("hello")       # => "hello"
    """

  pub fn trim_trailing(s :: String) -> String {
    :zig.String.trim_trailing(s)
  }

  @doc = """
    Counts non-overlapping occurrences of a substring.

    ## Examples

        String.count("hello world hello", "hello")  # => 2
        String.count("aaa", "aa")                     # => 1
        String.count("hello", "xyz")                  # => 0
    """

  pub fn count(haystack :: String, needle :: String) -> i64 {
    :zig.String.string_count(haystack, needle)
  }

  @doc = """
    Splits a string by a delimiter, returning a list of strings.

    ## Examples

        String.split("a,b,c", ",")     # => ["a", "b", "c"]
        String.split("hello", "")       # => ["hello"]
        String.split("no match", ",")   # => ["no match"]
    """

  pub fn split(s :: String, delimiter :: String) -> [String] {
    :zig.String.split_to_list(s, delimiter)
  }

  @doc = """
    Joins a list of strings with a separator.

    ## Examples

        String.join(["a", "b", "c"], ", ")  # => "a, b, c"
        String.join(["hello"], "-")          # => "hello"
        String.join([], ", ")                # => ""
    """

  pub fn join(parts :: [String], separator :: String) -> String {
    :zig.String.string_join(parts, separator)
  }
}
