@doc = """
  A `Stage` that reassembles length-prefixed frames from a byte stream.

  `LengthPrefixedFramer` is the stage behind `Framer.length_prefixed/2`. A frame
  on the wire is a big-endian unsigned length prefix of `prefix_bytes` bytes
  (1, 2, or 4) followed by exactly that many payload bytes. The framer buffers
  incoming chunks in explicit `String` state, emits every complete frame's
  payload as `Result.Ok(payload)`, and carries the unconsumed remainder
  forward.

  ## Contract

  - `step` appends the chunk to the buffer, then emits every complete frame
    now present (stripping each length prefix), keeping the trailing partial
    frame buffered. If a declared length exceeds `max_frame_size` the framer
    emits `Result.Error(%FramingError{reason: :oversize})` and halts — the
    denial-of-service bound.
  - `flush` reports a non-empty leftover buffer (an incomplete final frame) as
    `Result.Error(%FramingError{reason: :truncated})`; a clean frame boundary
    at end-of-stream flushes nothing.

  Because it is a `Stage`, it composes with `Stream.transform`, `Stream.compose`,
  and any other stage for free.
  """

pub struct LengthPrefixedFramer {
  prefix_bytes :: i64
  max_frame_size :: i64
  buffer :: String
}

@doc = """
  The length-prefixed framing `Stage` behaviour: buffer bytes, emit complete
  frame payloads as `Result.Ok`, guard the `max_frame_size` bound, and report a
  truncated tail on flush.
  """

pub impl Stage(String, Result(String, FramingError)) for LengthPrefixedFramer {
  @doc = """
    Appends the chunk to the buffer and emits every complete frame now present,
    carrying the remainder. Halts with `Result.Error(:oversize)` if a declared
    length exceeds `max_frame_size`.
    """

  pub fn step(stage :: unique LengthPrefixedFramer, chunk :: String) -> {Atom, [Result(String, FramingError)], LengthPrefixedFramer} {
    LengthPrefixedFramer.consume(stage.prefix_bytes, stage.max_frame_size, stage.buffer, chunk)
  }

  @doc = """
    Reports a non-empty leftover buffer as `Result.Error(:truncated)` — an
    incomplete final frame — and an empty buffer as nothing.
    """

  pub fn flush(stage :: unique LengthPrefixedFramer) -> [Result(String, FramingError)] {
    LengthPrefixedFramer.drain(stage.buffer)
  }

  fn consume(prefix_bytes :: i64, max_frame_size :: i64, buffer :: String, chunk :: String) -> {Atom, [Result(String, FramingError)], LengthPrefixedFramer} {
    filled = buffer <> chunk
    case LengthPrefixedFramer.extract(prefix_bytes, max_frame_size, filled, ([] :: [Result(String, FramingError)])) {
      {decision, outputs, remainder} -> {decision, outputs, %LengthPrefixedFramer{prefix_bytes: prefix_bytes, max_frame_size: max_frame_size, buffer: remainder}}
    }
  }

  fn extract(prefix_bytes :: i64, max_frame_size :: i64, buffer :: String, outputs :: [Result(String, FramingError)]) -> {Atom, [Result(String, FramingError)], String} {
    if String.length(buffer) < prefix_bytes {
      {:cont, outputs, buffer}
    } else {
      declared_length = LengthPrefixedFramer.decode_big_endian(String.slice(buffer, 0, prefix_bytes), prefix_bytes)
      if declared_length > max_frame_size {
        {:halt, List.concat(outputs, [Result(String, FramingError).Error(%FramingError{reason: :oversize})]), ""}
      } else {
        LengthPrefixedFramer.extract_bounded(prefix_bytes, max_frame_size, buffer, declared_length, outputs)
      }
    }
  }

  fn extract_bounded(prefix_bytes :: i64, max_frame_size :: i64, buffer :: String, declared_length :: i64, outputs :: [Result(String, FramingError)]) -> {Atom, [Result(String, FramingError)], String} {
    frame_end = prefix_bytes + declared_length
    if String.length(buffer) < frame_end {
      {:cont, outputs, buffer}
    } else {
      payload = String.slice(buffer, prefix_bytes, frame_end)
      remainder = String.slice(buffer, frame_end, String.length(buffer))
      LengthPrefixedFramer.extract(prefix_bytes, max_frame_size, remainder, List.concat(outputs, [Result(String, FramingError).Ok(payload)]))
    }
  }

  fn drain(buffer :: String) -> [Result(String, FramingError)] {
    if String.length(buffer) == 0 {
      ([] :: [Result(String, FramingError)])
    } else {
      [Result(String, FramingError).Error(%FramingError{reason: :truncated})]
    }
  }

  fn decode_big_endian(prefix :: String, count :: i64) -> i64 {
    LengthPrefixedFramer.decode_big_endian_walk(prefix, 0, count, 0)
  }

  fn decode_big_endian_walk(prefix :: String, index :: i64, count :: i64, accumulator :: i64) -> i64 {
    if index >= count {
      accumulator
    } else {
      byte = LengthPrefixedFramer.byte_value(String.byte_at(prefix, index))
      LengthPrefixedFramer.decode_big_endian_walk(prefix, index + 1, count, accumulator * 256 + byte)
    }
  }

  fn byte_value(single_byte :: String) -> i64 {
    LengthPrefixedFramer.byte_value_search(single_byte, 0, 255)
  }

  fn byte_value_search(single_byte :: String, low :: i64, high :: i64) -> i64 {
    if low >= high {
      low
    } else {
      midpoint = (low + high) / 2
      comparison = String.compare(single_byte, String.from_byte(midpoint))
      if comparison == 0 {
        midpoint
      } else {
        if comparison < 0 {
          LengthPrefixedFramer.byte_value_search(single_byte, low, midpoint - 1)
        } else {
          LengthPrefixedFramer.byte_value_search(single_byte, midpoint + 1, high)
        }
      }
    }
  }
}
