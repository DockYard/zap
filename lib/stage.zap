@doc = """
  A `Stage(input, output)` is a first-class stream-transformation value: an
  explicit, linearly-threaded piece of state that consumes `input` items one
  at a time and emits `output` items, with a distinct end-of-stream `flush`.

  It is the purified transducer — Gatherers-with-linearity — and the shared
  transformation vocabulary underneath `Stream`. Because a stage's state is a
  plain value threaded through `step`/`flush` (never hidden in a closure that
  the type system cannot see), stages compose cleanly with Zap's `unique`
  ownership discipline.

  ## The protocol

  A stage provides two operations:

  - `step(stage, item)` consumes the current stage state and one `input`
    item, returning `{decision, outputs, next}`:
    - `decision` is `:cont` to keep feeding items or `:halt` to stop early
      (no further `step` will be called after `:halt`).
    - `outputs` is the list of `output` items produced by this item, in
      order. An empty list is normal — a filter that rejects an item, or a
      buffering stage that has not yet completed a group, emits `[]`.
    - `next` is the stage state to thread into the following call.
  - `flush(stage)` consumes the final stage state and returns any buffered
    `output` items (the final partial group of a chunker, for example). It
    runs exactly once, last, on both the natural-end path and the early-halt
    path, and returns `[]` when nothing is buffered.

  ## Contract

  1. `step` returns `{:cont, outs, next}` while more input is welcome, or
     `{:halt, outs, next}` to terminate the stream after emitting `outs`.
  2. After a `:halt`, `step` is never called again; exactly one `flush`
     follows.
  3. On the natural end of the source, exactly one `flush` follows the last
     `step`.
  4. `flush` is called at most once and is always the last stage operation.

  ## Fallibility is a value, never a raise

  A fallible stage makes its `output` a `Result`: on failure it emits a
  `Result.Error(...)` output element and returns `:halt`. Errors flow as
  ordinary stream elements — they are never raised.

  ## Driving a stage

  Stages are consumed by the three `Stream` drivers. The pull driver is
  `Stream.transform/2`, which wraps an `Enumerable(input)` and a stage into a
  new lazy `Enumerable(output)`.
  """

pub protocol Stage(input, output) {
  fn step(stage :: unique Stage(input, output), item :: input) -> {Atom, [output], Stage(input, output)}

  fn flush(stage :: unique Stage(input, output)) -> [output]
}
