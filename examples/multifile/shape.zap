@doc = """
  Base shape — `Circle` and `Rectangle` extend it to inherit
  `color` while layering their own geometry fields on top. Stored in
  its own file because every struct in a Zap project owns one file.
  """

pub struct Shape {
  color :: String = "black"
}
