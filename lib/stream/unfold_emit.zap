@doc = """
  The payload an unfold generator produces to continue a stream: the `value`
  to emit next paired with the `next_accumulator` to resume from.

  `UnfoldEmit(element, accumulator)` is the `Continue` payload of
  `UnfoldStep`. It is a named struct rather than an anonymous `{element,
  accumulator}` tuple so it can flow through the generic union and closure
  machinery that back `Stream.unfold/2`.
  """

pub struct UnfoldEmit(element, accumulator) {
  value :: element
  next_accumulator :: accumulator
}
