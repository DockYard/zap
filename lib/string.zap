pub module String {
  @native = "ZapString.length"
  pub fn length(_s :: String) -> i64

  @native = "ZapString.byte_at"
  pub fn byte_at(_s :: String, _index :: i64) -> String

  @native = "ZapString.contains"
  pub fn contains(_haystack :: String, _needle :: String) -> Bool

  @native = "ZapString.startsWith"
  pub fn starts_with(_s :: String, _prefix :: String) -> Bool

  @native = "ZapString.endsWith"
  pub fn ends_with(_s :: String, _suffix :: String) -> Bool

  @native = "ZapString.trim"
  pub fn trim(_s :: String) -> String

  @native = "ZapString.slice"
  pub fn slice(_s :: String, _start :: i64, _end :: i64) -> String

  @native = "ZapString.to_atom"
  pub fn to_atom(_name :: String) -> Atom

  @native = "ZapString.to_existing_atom"
  pub fn to_existing_atom(_name :: String) -> Atom
}
