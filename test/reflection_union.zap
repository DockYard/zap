@doc = """
  Test fixture exposing a union so the reflection tests can verify
  `SourceGraph.unions/1` enumeration end to end.

  The `Tag` variant carries a payload type so the variant reflection
  path covers both bare and typed shapes.
  """

pub union ReflectionUnion {
  Up,
  Down,
  Tag :: i64
}
