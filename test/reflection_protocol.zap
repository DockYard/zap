@doc = """
  Test fixture exposing a protocol so the reflection tests can verify
  `SourceGraph.protocols/1` enumeration end to end.
  """

pub protocol ReflectionProtocol(element) {
  fn next(state) -> {Atom, element, any}
}
