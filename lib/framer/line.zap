@doc = """
  A `Stage` that splits a byte stream into newline-delimited lines.

  `Framer.Line` is the stage behind `Framer.line/1`. It buffers incoming chunks
  in explicit `String` state and emits each complete line — the bytes up to,
  but not including, a `\n` — as `Result.Ok(line)`.

  ## Delimiter choice

  The stream is split on `\n` only. A trailing `\r` (as in `\r\n` line endings)
  is left attached to the line; callers that want CRLF stripped should trim it
  downstream. This keeps the framer a faithful, lossless byte splitter.

  ## Contract

  - `step` appends the chunk and emits every complete line now present,
    carrying the trailing partial line forward. An un-delimited run that
    reaches `max_frame_size` bytes emits
    `Result.Error(%Framer.Error{reason: :oversize})` and halts — the
    denial-of-service bound that prevents unbounded buffering of a line with
    no delimiter.
  - `flush` emits a non-empty trailing buffer (the common "last line without a
    final newline" case) as `Result.Ok(line)` — this is a complete line, not a
    truncation, unlike the length-prefixed framer.

  Because it is a `Stage`, it composes with `Stream.transform`, `Stream.compose`,
  and any other stage for free.
  """

pub struct Framer.Line {
  max_frame_size :: i64
  buffer :: String
}

@doc = """
  The line-framing `Stage` behaviour: buffer bytes, emit complete lines as
  `Result.Ok`, guard the `max_frame_size` bound, and emit the final un-newlined
  line on flush.
  """

pub impl Stage(String, Result(String, Framer.Error)) for Framer.Line {
  @doc = """
    Appends the chunk to the buffer and emits every complete line now present,
    carrying the remainder. Halts with `Result.Error(:oversize)` if an
    un-delimited run reaches `max_frame_size` bytes.
    """

  pub fn step(stage :: unique Framer.Line, chunk :: String) -> {Atom, [Result(String, Framer.Error)], Framer.Line} {
    Framer.Line.consume(stage.max_frame_size, stage.buffer, chunk)
  }

  @doc = """
    Emits a non-empty trailing buffer as a final `Result.Ok(line)` — the last
    line without a newline — and an empty buffer as nothing.
    """

  pub fn flush(stage :: unique Framer.Line) -> [Result(String, Framer.Error)] {
    Framer.Line.drain(stage.buffer)
  }

  fn consume(max_frame_size :: i64, buffer :: String, chunk :: String) -> {Atom, [Result(String, Framer.Error)], Framer.Line} {
    filled = buffer <> chunk
    case Framer.Line.extract(max_frame_size, filled, ([] :: [Result(String, Framer.Error)])) {
      {decision, outputs, remainder} -> {decision, outputs, %Framer.Line{max_frame_size: max_frame_size, buffer: remainder}}
    }
  }

  fn extract(max_frame_size :: i64, buffer :: String, outputs :: [Result(String, Framer.Error)]) -> {Atom, [Result(String, Framer.Error)], String} {
    newline_index = String.index_of(buffer, "\n")
    if newline_index < 0 {
      if String.length(buffer) >= max_frame_size {
        {:halt, List.concat(outputs, [Result(String, Framer.Error).Error(%Framer.Error{reason: :oversize})]), ""}
      } else {
        {:cont, outputs, buffer}
      }
    } else {
      line = String.slice(buffer, 0, newline_index)
      remainder = String.slice(buffer, newline_index + 1, String.length(buffer))
      Framer.Line.extract(max_frame_size, remainder, List.concat(outputs, [Result(String, Framer.Error).Ok(line)]))
    }
  }

  fn drain(buffer :: String) -> [Result(String, Framer.Error)] {
    if String.length(buffer) == 0 {
      ([] :: [Result(String, Framer.Error)])
    } else {
      [Result(String, Framer.Error).Ok(buffer)]
    }
  }
}
