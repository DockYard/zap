@doc = """
  An optional value: either `Some(T)` carrying a value of type `T`, or
  `None` representing the absence of a value.

  Use `Option(T)` whenever a value may be absent — return type of a
  partial lookup, an optional argument, a field that may not yet be
  initialised. Pattern-match on the variant to extract or compose with
  the helpers in this struct.

  ## Examples

      opt = Option(i64).Some(42)
      Option.is_some?(opt)   # => true
      Option.is_none?(Option(i64).None)   # => true

  ## Variant payload destructuring

  Payload-extracting helpers (`Option.map/2`, `Option.unwrap_or/2`)
  require tagged-union variant pattern destructuring at the case-arm
  surface (e.g. `case opt { Option.Some(v) -> v; Option.None -> 0 }`),
  which is delivered alongside `Result(T, E)` and the `?` propagation
  operator in Phase 1.3 of the error-system roadmap. The predicate
  helpers below ship now because they only need the existing
  no-payload `Option.None` variant pattern; the payload-extracting
  ones land in Phase 1.3.
  """

pub union Option(t) {
  Some :: t
  None
}
