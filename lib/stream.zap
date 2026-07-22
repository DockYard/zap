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

  Each adapter returns its concrete lazy type — `Stream.Transform(input, output)` for
  the stage adapters, `Stream.Unfold(accumulator, element)` for `unfold` — rather
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

      Stream.unfold(1, fn(n :: i64) -> Stream.UnfoldStep(i64, i64) { Stream.UnfoldStep.emit(n, n * 2) })
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

        Stream.transform([1, 2, 3], %Stage.Map(i64, i64){callback: fn(x :: i64) -> i64 { x + 1 }})
        |> Enum.to_list()
        # => [2, 3, 4]
    """

  pub fn transform(source :: unique Enumerable(input), stage :: unique Stage(input, output)) -> Stream.Transform(input, output) {
    %Stream.Transform(input, output){source: source, stage: stage, pending: ([] :: [output])}
  }

  @doc = """
    Lazily applies `callback` to each element.

    ## Example

        Stream.map([1, 2, 3], fn(x :: i64) -> i64 { x * 10 }) |> Enum.to_list()
        # => [10, 20, 30]
    """

  pub fn map(source :: unique Enumerable(input), callback :: Callable({input}, output)) -> Stream.Transform(input, output) {
    Stream.transform(source, %Stage.Map(input, output){callback: callback})
  }

  @doc = """
    Lazily keeps only the elements for which `predicate` returns `true`.

    ## Example

        Stream.filter([1, 2, 3, 4], fn(x :: i64) -> Bool { x > 2 }) |> Enum.to_list()
        # => [3, 4]
    """

  pub fn filter(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Stream.Transform(element, element) {
    Stream.transform(source, %Stage.Filter(element){predicate: predicate})
  }

  @doc = """
    Lazily drops the elements for which `predicate` returns `true` — the
    complement of `filter/2`.

    ## Example

        Stream.reject([1, 2, 3, 4], fn(x :: i64) -> Bool { x > 2 }) |> Enum.to_list()
        # => [1, 2]
    """

  pub fn reject(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Stream.Transform(element, element) {
    Stream.transform(source, %Stage.Reject(element){predicate: predicate})
  }

  @doc = """
    Lazily yields at most the first `count` elements, then stops — pulling no
    more from the source than needed. A `count` of zero or less yields the
    empty stream and pulls nothing at all from the source: the source is
    released without a single element being demanded.

    ## Example

        Stream.take([1, 2, 3, 4, 5], 3) |> Enum.to_list()
        # => [1, 2, 3]
    """

  pub fn take(source :: unique Enumerable(element), count :: i64) -> Stream.Transform(element, element) {
    if count <= 0 {
      Stream.empty_take(source)
    } else {
      Stream.transform(source, %Stage.Take(element){count: count})
    }
  }

  @doc = """
    Lazily yields elements while `predicate` returns `true`, stopping at (and
    excluding) the first element that fails it.

    ## Example

        Stream.take_while([1, 2, 3, 1], fn(x :: i64) -> Bool { x < 3 }) |> Enum.to_list()
        # => [1, 2]
    """

  pub fn take_while(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Stream.Transform(element, element) {
    Stream.transform(source, %Stage.TakeWhile(element){predicate: predicate})
  }

  @doc = """
    Lazily discards the first `count` elements and yields the rest.

    ## Example

        Stream.drop([1, 2, 3, 4, 5], 2) |> Enum.to_list()
        # => [3, 4, 5]
    """

  pub fn drop(source :: unique Enumerable(element), count :: i64) -> Stream.Transform(element, element) {
    Stream.transform(source, %Stage.Drop(element){count: count})
  }

  @doc = """
    Lazily discards the leading run of elements for which `predicate` returns
    `true`, then yields every element thereafter (including the first that
    fails the predicate).

    ## Example

        Stream.drop_while([1, 2, 3, 1], fn(x :: i64) -> Bool { x < 3 }) |> Enum.to_list()
        # => [3, 1]
    """

  pub fn drop_while(source :: unique Enumerable(element), predicate :: Callable({element}, Bool)) -> Stream.Transform(element, element) {
    Stream.transform(source, %Stage.DropWhile(element){predicate: predicate, dropping: true})
  }

  @doc = """
    Lazily threads an accumulator through the stream, yielding the running
    accumulator after each element. `reducer` receives `(accumulator,
    element)` and returns the next accumulator.

    ## Example

        Stream.scan([1, 2, 3, 4], 0, fn(acc :: i64, x :: i64) -> i64 { acc + x }) |> Enum.to_list()
        # => [1, 3, 6, 10]
    """

  pub fn scan(source :: unique Enumerable(input), initial :: accumulator, reducer :: Callable({accumulator, input}, accumulator)) -> Stream.Transform(input, accumulator) {
    Stream.transform(source, %Stage.Scan(input, accumulator){state: initial, reducer: reducer})
  }

  @doc = """
    Lazily batches elements into consecutive groups of `count`, yielding each
    full group as a list. A final partial group is yielded when the source
    ends. Panics loudly when `count` is less than one.

    ## Example

        Stream.chunk_every([1, 2, 3, 4, 5], 2) |> Enum.to_list()
        # => [[1, 2], [3, 4], [5]]
    """

  pub fn chunk_every(source :: unique Enumerable(element), count :: i64) -> Stream.Transform(element, [element]) {
    checked_count = Stream.check_chunk_size(count)
    %Stream.Transform(element, [element]){source: source, stage: %Stage.ChunkEvery(element){count: checked_count, buffer: ([] :: [element])}, pending: ([] :: [[element]])}
  }

  @doc = """
    Lazily pairs every element with its zero-based index, yielding `{element,
    index}` tuples.

    ## Example

        Stream.with_index(["a", "b", "c"]) |> Enum.to_list()
        # => [{"a", 0}, {"b", 1}, {"c", 2}]
    """

  pub fn with_index(source :: unique Enumerable(element)) -> Stream.Transform(element, {element, i64}) {
    %Stream.Transform(element, {element, i64}){source: source, stage: %Stage.WithIndex(element){index: 0}, pending: ([] :: [{element, i64}])}
  }

  @doc = """
    Lazily collapses runs of consecutive equal elements, yielding an element
    only when it differs from the one immediately before it.

    ## Example

        Stream.dedupe([1, 1, 2, 2, 2, 3, 1]) |> Enum.to_list()
        # => [1, 2, 3, 1]
    """

  pub fn dedupe(source :: unique Enumerable(element)) -> Stream.Transform(element, element) {
    Stream.transform(source, %Stage.Dedupe(element){last: Option(element).None})
  }

  @doc = """
    Builds a lazy stream by repeatedly applying `generator` to an accumulator,
    starting from `initial`. `generator` returns an `Stream.UnfoldStep`:
    `Stream.UnfoldStep.emit(value, next_accumulator)` to yield `value` and continue,
    or `Stream.UnfoldStep(element, accumulator).Stop` to end the stream. Nothing is
    generated until demanded, so `unfold` describes infinite sequences safely
    when paired with a bounded consumer.

    ## Example

        Stream.unfold(1, fn(n :: i64) -> Stream.UnfoldStep(i64, i64) {
          if n > 100 { Stream.UnfoldStep(i64, i64).Stop } else { Stream.UnfoldStep.emit(n, n * 2) }
        })
        |> Enum.to_list()
        # => [1, 2, 4, 8, 16, 32, 64]
    """

  pub fn unfold(initial :: accumulator, generator :: Callable({accumulator}, Stream.UnfoldStep(element, accumulator))) -> Stream.Unfold(accumulator, element) {
    %Stream.Unfold(accumulator, element){seed: initial, generator: generator}
  }

  @doc = """
    Lazily pairs `left` and `right` element-wise, yielding `{a, b}` tuples. The
    zip ends as soon as EITHER source is exhausted; the still-live source is
    then disposed exactly once (the early-termination discipline), so no
    iteration state is stranded.

    ## Example

        Stream.zip([1, 2, 3], ["a", "b", "c"]) |> Enum.to_list()
        # => [{1, "a"}, {2, "b"}, {3, "c"}]
    """

  pub fn zip(left :: unique Enumerable(a), right :: unique Enumerable(b)) -> Stream.Zip(a, b) {
    %Stream.Zip(a, b){left: left, right: right}
  }

  @doc = """
    Fuses two stages into one: `compose(first, second)` is the `Stage(a, c)`
    that feeds every output of `first` through `second`. It threads `first`'s
    intermediate `b` outputs through `second.step` in order, propagates an early
    halt from either inner stage, and on `flush` drains a buffering `first`
    (such as `chunk_every`) into `second` before `second` completes.

    Composition lives in `Stream` — the struct namespace built on the `Stage`
    protocol, mirroring how `Enum` hosts the free functions over `Enumerable` —
    because a protocol name cannot itself host a namespace function (`Stage.x`
    resolves through protocol dispatch on `x`'s receiver, never to a static
    function).

    ## Example

        doubler = %Stage.Map(i64, i64){callback: fn(value :: i64) -> i64 { value * value }}
        big = %Stage.Filter(i64){predicate: fn(value :: i64) -> Bool { value > 4 }}
        Stream.transform([1, 2, 3, 4], Stream.compose(doubler, big)) |> Enum.to_list()
        # => [9, 16]
    """

  pub fn compose(first :: unique Stage(a, b), second :: unique Stage(b, c)) -> Stage.Compose(a, b, c) {
    %Stage.Compose(a, b, c){first: first, second: second, second_halted: false}
  }

  fn check_chunk_size(count :: i64) -> i64 {
    if count < 1 {
      panic("Stream.chunk_every/2 requires a chunk size of at least 1, got " <> Integer.to_string(count))
    } else {
      count
    }
  }

  fn empty_take(source :: unique Enumerable(element)) -> Stream.Transform(element, element) {
    Enumerable.dispose(source)
    %Stream.Transform(element, element){source: ([] :: [element]), stage: %Stage.Empty(element, element){}, pending: ([] :: [element])}
  }
}
