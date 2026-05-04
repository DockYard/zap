@doc = """
  Tag union enumerating the supported colours. Lives in its own file
  because Zap unions follow the same one-declaration-per-file rule
  structs do, and `Geometry.describe_color/1` resolves the variants
  by importing this file.
  """

pub union Color {
  Red,
  Green,
  Blue
}
