@doc = """
  The demand-driven pull adapter that turns an `Enumerable(input)` plus a
  `Stage(input, output)` into a lazy `Enumerable(output)`.

  `Stream.Transform(input, output)` is the value returned by `Stream.transform/2` and
  every `Stream` adapter built on it. It is fully lazy: the source is pulled
  only when the transform's own `pending` buffer is empty, one output is
  yielded per `next`, and early consumption (`Enum.take`, `Enum.find`, …)
  disposes the source without draining it.

  ## Lifecycle

  - While `pending` holds buffered outputs, `next` yields them one at a time.
  - When `pending` is empty, `next` pulls the source. Each pulled item is fed
    to the stage:
    - `:cont` with outputs buffers them (or, if empty, immediately pulls
      again — this is how filters and drops request more input);
    - `:halt` disposes the source, flushes the stage, and enters the terminal
      state carrying whatever the halt and flush produced.
  - When the source reports `:done`, the source is disposed, the stage is
    flushed, and the transform enters its terminal state carrying the flushed
    outputs.
  - Once drained, the transform reconstructs itself around an empty-list source
    and an `Stage.Empty`, so its type stays well-formed while it only reports
    `:done`.
  - `dispose` disposes the source and drops the stage and pending buffer
    without flushing — an abandoned pull runs no completion.
  """

pub struct Stream.Transform(input, output) {
  source :: Enumerable(input)
  stage :: Stage(input, output)
  pending :: [output]
}

@doc = """
  The `Enumerable(output)` behaviour of a `Stream.Transform`: demand-driven pulling
  of the source through the stage, with deterministic disposal.
  """

pub impl Enumerable(output) for Stream.Transform(input, output) {
  @doc = """
    Yields the next output: a buffered one if `pending` is non-empty,
    otherwise the result of pulling the source through the stage.
    """

  pub fn next(self :: unique Stream.Transform(input, output)) -> {Atom, output, Stream.Transform(input, output)} {
    case self.pending {
      [head | rest] -> {:cont, head, %Stream.Transform(input, output){source: self.source, stage: self.stage, pending: rest}}
      [] -> Stream.Transform.pull(self.source, self.stage)
    }
  }

  @doc = """
    Disposes an unconsumed transform: releases the source iteration state and
    drops the stage and any buffered outputs without flushing.
    """

  pub fn dispose(self :: unique Stream.Transform(input, output)) -> Nil {
    Stream.Transform.dispose_parts(self.source, self.stage, self.pending)
  }

  fn dispose_parts(source :: unique Enumerable(input), stage :: unique Stage(input, output), pending :: [output]) -> Nil {
    Enumerable.dispose(source)
    Stream.Transform.drop_stage(stage)
    Stream.Transform.drop_pending(pending)
    nil
  }

  fn drop_stage(_stage :: unique Stage(input, output)) -> Nil {
    nil
  }

  fn drop_pending(_pending :: [output]) -> Nil {
    nil
  }

  fn pull(source :: unique Enumerable(input), stage :: unique Stage(input, output)) -> {Atom, output, Stream.Transform(input, output)} {
    case Enumerable.next(source) {
      {:done, _, exhausted} -> Stream.Transform.on_source_done(exhausted, stage)
      {:cont, item, next_source} -> Stream.Transform.on_item(next_source, stage, item)
    }
  }

  fn on_source_done(exhausted :: unique Enumerable(input), stage :: unique Stage(input, output)) -> {Atom, output, Stream.Transform(input, output)} {
    Enumerable.dispose(exhausted)
    Stream.Transform.enter_terminal(Stage.flush(stage))
  }

  fn on_item(next_source :: unique Enumerable(input), stage :: unique Stage(input, output), item :: input) -> {Atom, output, Stream.Transform(input, output)} {
    case Stage.step(stage, item) {
      {:cont, outs, next_stage} -> Stream.Transform.after_cont(next_source, next_stage, outs)
      {:halt, outs, next_stage} -> Stream.Transform.after_halt(next_source, next_stage, outs)
    }
  }

  fn after_cont(next_source :: unique Enumerable(input), next_stage :: unique Stage(input, output), outs :: [output]) -> {Atom, output, Stream.Transform(input, output)} {
    case outs {
      [] -> Stream.Transform.pull(next_source, next_stage)
      [head | rest] -> {:cont, head, %Stream.Transform(input, output){source: next_source, stage: next_stage, pending: rest}}
    }
  }

  fn after_halt(next_source :: unique Enumerable(input), next_stage :: unique Stage(input, output), outs :: [output]) -> {Atom, output, Stream.Transform(input, output)} {
    Enumerable.dispose(next_source)
    Stream.Transform.enter_terminal(List.concat(outs, Stage.flush(next_stage)))
  }

  fn enter_terminal(remaining :: [output]) -> {Atom, output, Stream.Transform(input, output)} {
    case remaining {
      [] -> Stream.Transform.emit_done()
      [head | rest] -> {:cont, head, Stream.Transform.terminal_state(rest)}
    }
  }

  fn terminal_state(pending :: [output]) -> Stream.Transform(input, output) {
    %Stream.Transform(input, output){source: ([] :: [input]), stage: %Stage.Empty(input, output){}, pending: pending}
  }

  fn emit_done() -> {Atom, output, Stream.Transform(input, output)} {
    case Enumerable.next(([] :: [output])) {
      {_atom, manufactured, spent} -> Stream.Transform.finish_done(manufactured, spent)
    }
  }

  fn finish_done(manufactured :: output, spent :: unique Enumerable(output)) -> {Atom, output, Stream.Transform(input, output)} {
    Enumerable.dispose(spent)
    {:done, manufactured, Stream.Transform.terminal_state(([] :: [output]))}
  }
}
