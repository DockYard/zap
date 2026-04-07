pub module String {
  pub fn length(s :: String) -> i64 {
    :zig.ZapString.length(s)
  }

  pub fn byte_at(s :: String, index :: i64) -> String {
    :zig.ZapString.byte_at(s, index)
  }

  pub fn contains(haystack :: String, needle :: String) -> Bool {
    :zig.ZapString.contains(haystack, needle)
  }

  pub fn starts_with(s :: String, prefix :: String) -> Bool {
    :zig.ZapString.startsWith(s, prefix)
  }

  pub fn ends_with(s :: String, suffix :: String) -> Bool {
    :zig.ZapString.endsWith(s, suffix)
  }

  pub fn trim(s :: String) -> String {
    :zig.ZapString.trim(s)
  }

  pub fn slice(s :: String, start :: i64, end :: i64) -> String {
    :zig.ZapString.slice(s, start, end)
  }

  pub fn to_atom(name :: String) -> Atom {
    :zig.ZapString.to_atom(name)
  }

  pub fn to_existing_atom(name :: String) -> Atom {
    :zig.ZapString.to_existing_atom(name)
  }
}
