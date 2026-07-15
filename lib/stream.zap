@doc = """
  Lazy, composable transformations over `Enumerable`s.

  `Stream` is the Elixir-familiar face of the `Stage` transformation core.
  Each function wraps an `Enumerable` (and, for the closure adapters, a
  callback) into a new lazy value that transforms elements on demand, one at a
  time, in the consuming fiber — no intermediate collection is materialised
  until a consumer (`Enum.to_list`, `Enum.reduce`, `Enum.take`, a `for`
  comprehension, …) drives it. Because the pipeline is demand-driven,
  `source |> Stream.map(f) |> Stream.take(3)` pulls exactly three elements
  from `source`.

  ## Return types are concrete lazy adapters

  Each adapter returns its concrete lazy type — `Transform(input, output)` for
  the stage adapters, `Unfold(accumulator, element)` for `unfold` — rather
  than a type-erased `Enumerable`. Those types implement `Enumerable`, so they
  compose with every `Enum` function and `for` comprehension and box
  automatically wherever an `Enumerable` is expected. This mirrors how
  Rust's iterator adapters return concrete `Map`/`Take` types, and keeps the
  pipeline fused and allocation-light.

  ## Errors are values

  A fallible transformation emits a `Result.Error(...)` element and stops
  (its stage returns `:halt`); errors never raise. See `Stage`.

  ## Examples

      [1, 2, 3, 4, 5]
      |> Stream.map(fn(x :: i64) -> i64 { x * x })
      |> Stream.filter(fn(x :: i64) -> Bool { x > 4 })
      |> Enum.to_list()
      # => [9, 16, 25]

      Stream.unfold(1, fn(n :: i64) -> UnfoldStep(i64, i64) { UnfoldStep.emit(n, n * 2) })
      |> Stream.take(4)
      |> Enum.to_list()
      # => [1, 2, 4, 8]
  """

pub struct Stream {
  @doc = """
    The general adapter: wraps `source` and a `Stage` into a lazy
    `Enumerable` that pulls the source through the stage on demand. Every
    other `Stream` adapter is sugar over this.

    ## Example

        Stream.transform([1, 2, 3], %MapStage(i64, i64){callback: fn(x :: i64) -> i64 { x + 1 }})
        |> Enum.to_list()
        # => [2, 3, 4]
    """

  pub fn transform(source :: unique Enumerable(input), stage :: unique Stage(input, output)) -> Transform(input, output) {
    %Transform(input, output){source: source, stage: stage, pending: ([] :: [output])}
  }

  @doc = """
    Lazily applies `callback` to each element.

    ## Example

        Stream.map([1, 2, 3], fn(x :: i64) -> i64 { x * 10 }) |> Enum.to_list()
        # => [10, 20, 30]
    """

  pub fn map(source :: unique Enumerable(input), callback :: Callable({input}, output)) -> Transform(input, output) {
    Stream.transform(source, %MapStage(input, output){callback: callback})
  }

  @doc = """
    Lazily keeps only the elements for which `predicate` returns `true`.

    ## Example

        Stream.filter([1, 2, 3, 4], fn(x :: i64) -> Bool { x > 2 }) |> Enum.to_list()
        # => [3, 4]
    """

  pub fn filter(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Transform(element, element) {
    Stream.transform(source, %FilterStage(element){predicate: predicate})
  }

  @doc = """
    Lazily drops the elements for which `predicate` returns `true` — the
    complement of `filter/2`.

    ## Example

        Stream.reject([1, 2, 3, 4], fn(x :: i64) -> Bool { x > 2 }) |> Enum.to_list()
        # => [1, 2]
    """

  pub fn reject(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Transform(element, element) {
    Stream.transform(source, %RejectStage(element){predicate: predicate})
  }

  @doc = """
    Lazily yields at most the first `count` elements, then stops — pulling no
    more from the source than needed.

    ## Example

        Stream.take([1, 2, 3, 4, 5], 3) |> Enum.to_list()
        # => [1, 2, 3]
    """

  pub fn take(source :: unique Enumerable(element), count :: i64) -> Transform(element, element) {
    Stream.transform(source, %TakeStage(element){count: count})
  }

  @doc = """
    Lazily yields elements while `predicate` returns `true`, stopping at (and
    excluding) the first element that fails it.

    ## Example

        Stream.take_while([1, 2, 3, 1], fn(x :: i64) -> Bool { x < 3 }) |> Enum.to_list()
        # => [1, 2]
    """

  pub fn take_while(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Transform(element, element) {
    Stream.transform(source, %TakeWhileStage(element){predicate: predicate})
  }

  @doc = """
    Lazily discards the first `count` elements and yields the rest.

    ## Example

        Stream.drop([1, 2, 3, 4, 5], 2) |> Enum.to_list()
        # => [3, 4, 5]
    """

  pub fn drop(source :: unique Enumerable(element), count :: i64) -> Transform(element, element) {
    Stream.transform(source, %DropStage(element){count: count})
  }

  @doc = """
    Lazily discards the leading run of elements for which `predicate` returns
    `true`, then yields every element thereafter (including the first that
    fails the predicate).

    ## Example

        Stream.drop_while([1, 2, 3, 1], fn(x :: i64) -> Bool { x < 3 }) |> Enum.to_list()
        # => [3, 1]
    """

  pub fn drop_while(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Transform(element, element) {
    Stream.transform(source, %DropWhileStage(element){predicate: predicate, dropping: true})
  }

  @doc = """
    Lazily threads an accumulator through the stream, yielding the running
    accumulator after each element. `reducer` receives `(accumulator,
    element)` and returns the next accumulator.

    ## Example

        Stream.scan([1, 2, 3, 4], 0, fn(acc :: i64, x :: i64) -> i64 { acc + x }) |> Enum.to_list()
        # => [1, 3, 6, 10]
    """

  pub fn scan(source :: unique Enumerable(input), initial :: accumulator, reducer :: Callable({accumulator, input}, accumulator)) -> Transform(input, accumulator) {
    Stream.transform(source, %ScanStage(input, accumulator){state: initial, reducer: reducer})
  }

  @doc = """
    Lazily batches elements into consecutive groups of `count`, yielding each
    full group as a list. A final partial group is yielded when the source
    ends. Panics loudly when `count` is less than one.

    ## Example

        Stream.chunk_every([1, 2, 3, 4, 5], 2) |> Enum.to_list()
        # => [[1, 2], [3, 4], [5]]
    """

  pub fn chunk_every(source :: unique Enumerable(element), count :: i64) -> Transform(element, [element]) {
    checked_count = Stream.check_chunk_size(count)
    %Transform(element, [element]){source: source, stage: %ChunkEveryStage(element){count: checked_count, buffer: ([] :: [element])}, pending: ([] :: [[element]])}
  }

  @doc = """
    Lazily pairs every element with its zero-based index, yielding `{element,
    index}` tuples.

    ## Example

        Stream.with_index(["a", "b", "c"]) |> Enum.to_list()
        # => [{"a", 0}, {"b", 1}, {"c", 2}]
    """

  pub fn with_index(source :: unique Enumerable(element)) -> Transform(element, {element, i64}) {
    %Transform(element, {element, i64}){source: source, stage: %WithIndexStage(element){index: 0}, pending: ([] :: [{element, i64}])}
  }

  @doc = """
    Lazily collapses runs of consecutive equal elements, yielding an element
    only when it differs from the one immediately before it.

    ## Example

        Stream.dedupe([1, 1, 2, 2, 2, 3, 1]) |> Enum.to_list()
        # => [1, 2, 3, 1]
    """

  pub fn dedupe(source :: unique Enumerable(element)) -> Transform(element, element) {
    Stream.transform(source, %DedupeStage(element){last: Option(element).None})
  }

  @doc = """
    Builds a lazy stream by repeatedly applying `generator` to an accumulator,
    starting from `initial`. `generator` returns an `UnfoldStep`:
    `UnfoldStep.emit(value, next_accumulator)` to yield `value` and continue,
    or `UnfoldStep(element, accumulator).Stop` to end the stream. Nothing is
    generated until demanded, so `unfold` describes infinite sequences safely
    when paired with a bounded consumer.

    ## Example

        Stream.unfold(1, fn(n :: i64) -> UnfoldStep(i64, i64) {
          if n > 100 { UnfoldStep(i64, i64).Stop } else { UnfoldStep.emit(n, n * 2) }
        })
        |> Enum.to_list()
        # => [1, 2, 4, 8, 16, 32, 64]
    """

  pub fn unfold(initial :: accumulator, generator :: Callable({accumulator}, UnfoldStep(element, accumulator))) -> Unfold(accumulator, element) {
    %Unfold(accumulator, element){seed: initial, generator: generator}
  }

  fn check_chunk_size(count :: i64) -> i64 {
    if count < 1 {
      panic("Stream.chunk_every/2 requires a chunk size of at least 1, got " <> Integer.to_string(count))
    } else {
      count
    }
  }
}
