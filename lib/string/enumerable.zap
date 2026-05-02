@doc = "Enumerable implementation for `String`."

pub impl Enumerable(String) for String {
  @doc = """
    Iterate a string byte-by-byte.

    The string slice itself is the iteration state — each call yields
    the first byte (as a single-character `String`) and the remaining
    slice. Returns `{:cont, byte, rest}` for non-empty strings, or
    `{:done, "", string}` when the string is empty.
    """

  pub fn next(s :: String) -> {Atom, String, String} {
    :zig.String.next(s)
  }
}
