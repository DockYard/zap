@doc = """
  The lazy source produced by `Stream.unfold/2`: an `Enumerable(element)` that
  generates items on demand by repeatedly applying a generator to an
  accumulator.

  `Unfold(accumulator, element)` holds the current accumulator (`seed`) and
  the `generator`, a `Callable` from an accumulator to an `UnfoldStep`. Each
  `next` applies the generator: a `Continue` yields its value and threads the
  next accumulator forward; a `Stop` ends the stream. Nothing is produced
  until demanded, so `Stream.unfold` composes with bounded consumers
  (`Enum.take`, `Stream.take`) to describe finite prefixes of infinite
  sequences.
  """

pub struct Unfold(accumulator, element) {
  seed :: accumulator
  generator :: Callable({accumulator}, UnfoldStep(element, accumulator))
}

@doc = """
  The `Enumerable(element)` behaviour of an `Unfold`: pull the generator once
  per `next`, emitting until it reports `Stop`.
  """

pub impl Enumerable(element) for Unfold(accumulator, element) {
  @doc = """
    Applies the generator to the current accumulator: `Continue` yields the
    value and advances the accumulator; `Stop` ends the stream.
    """

  pub fn next(self :: unique Unfold(accumulator, element)) -> {Atom, element, Unfold(accumulator, element)} {
    Unfold.produce(self.seed, self.generator)
  }

  @doc = """
    Disposes an unconsumed unfold: the generator holds no external resources,
    so this simply drops it.
    """

  pub fn dispose(self :: unique Unfold(accumulator, element)) -> Nil {
    Unfold.drop_generator(self.generator)
  }

  fn drop_generator(_generator :: Callable({accumulator}, UnfoldStep(element, accumulator))) -> Nil {
    nil
  }

  fn produce(seed :: accumulator, generator :: Callable({accumulator}, UnfoldStep(element, accumulator))) -> {Atom, element, Unfold(accumulator, element)} {
    case Callable.call(generator, {seed}) {
      UnfoldStep.Stop -> Unfold.finish(seed, generator)
      UnfoldStep.Continue(emit) -> {:cont, emit.value, %Unfold(accumulator, element){seed: emit.next_accumulator, generator: generator}}
    }
  }

  fn finish(seed :: accumulator, generator :: Callable({accumulator}, UnfoldStep(element, accumulator))) -> {Atom, element, Unfold(accumulator, element)} {
    case Enumerable.next(([] :: [element])) {
      {_atom, manufactured, spent} -> Unfold.terminate(manufactured, spent, seed, generator)
    }
  }

  fn terminate(manufactured :: element, spent :: unique Enumerable(element), seed :: accumulator, generator :: Callable({accumulator}, UnfoldStep(element, accumulator))) -> {Atom, element, Unfold(accumulator, element)} {
    Enumerable.dispose(spent)
    {:done, manufactured, %Unfold(accumulator, element){seed: seed, generator: generator}}
  }
}
