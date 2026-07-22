@doc = """
  The result an unfold generator returns for each accumulator: either
  `Continue(Stream.UnfoldEmit(element, accumulator))` to emit a value and resume, or
  `Stop` to end the stream.

  `Stream.UnfoldStep(element, accumulator)` is the typed equivalent of Elixir's
  `{element, next_acc} | nil` unfold step: `Continue` is the `{element,
  next_acc}` case and `Stop` is `nil`. It is a named union (rather than
  `Option` over an anonymous tuple) so it flows through generic construction
  and closure return-type inference.

  ## Example

      Stream.unfold(1, fn(n :: i64) -> Stream.UnfoldStep(i64, i64) {
        if n > 5 {
          Stream.UnfoldStep(i64, i64).Stop
        } else {
          Stream.UnfoldStep.emit(n, n + 1)
        }
      })
  """

pub union Stream.UnfoldStep(element, accumulator) {
  Continue :: Stream.UnfoldEmit(element, accumulator)
  Stop
}

@doc = """
  Constructor helpers for `Stream.UnfoldStep` values.
  """

pub struct Stream.UnfoldStep {
  @doc = """
    Builds a `Continue` step: emit `value` and resume from
    `next_accumulator`. The element and accumulator types are inferred from
    the arguments.

    ## Example

        Stream.UnfoldStep.emit("a", 2)
        # => Stream.UnfoldStep(String, i64).Continue(...)
    """

  pub fn emit(value :: element, next_accumulator :: accumulator) -> Stream.UnfoldStep(element, accumulator) {
    Stream.UnfoldStep(element, accumulator).Continue(%Stream.UnfoldEmit(element, accumulator){value: value, next_accumulator: next_accumulator})
  }
}
