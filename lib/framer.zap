@doc = """
  Framer stages — the byte-denominated framing kernel that turns a stream of
  raw byte chunks into a stream of complete protocol frames.

  A framer is a `Stage(String, Result(String, Framer.Error))`. In Zap a
  `String` is an immutable byte sequence, so a framer consumes arbitrary
  transport chunks (however the bytes happened to arrive) and emits one
  `Result.Ok(frame)` per complete frame, in order. A protocol violation flows
  out as `Result.Error(%Framer.Error{...})` followed immediately by `:halt` —
  errors are ordinary stream elements, never raises.

  Every ecosystem's socket kernel converges on the same framing contract, and
  these framers carry it: a distinct end-of-stream `flush` (a bare fold cannot
  emit the final partial frame), a `max_frame_size` denial-of-service bound,
  and an explicit leftover-at-EOF policy. Because framers are ordinary `Stage`
  values, they compose with `Stream.transform`, `Stream.compose`, and every
  other stage for free.

  ## Examples

      # Reassemble 2-byte-length-prefixed frames arriving in arbitrary chunks.
      Stream.transform(chunk_source, Framer.length_prefixed(2, 65_536))
      |> Enum.to_list()

      # Split a byte stream into newline-delimited lines.
      Stream.transform(chunk_source, Framer.line(8_192))
      |> Enum.to_list()
  """

pub struct Framer {
  @doc = """
    A framer for length-prefixed frames: a big-endian unsigned length prefix of
    `prefix_bytes` bytes (which must be 1, 2, or 4) followed by that many
    payload bytes. Each complete frame's payload is emitted as
    `Result.Ok(payload)`. A declared length greater than `max_frame_size`
    emits `Result.Error(%Framer.Error{reason: :oversize})` and halts; leftover
    bytes at end-of-stream emit `Result.Error(%Framer.Error{reason:
    :truncated})`.

    Panics loudly when `prefix_bytes` is not 1, 2, or 4, or when
    `max_frame_size` is less than 1 — these are programmer errors, caught at
    construction like `Stream.chunk_every/2`'s size check.

    ## Example

        Stream.transform([two_byte_prefixed_bytes], Framer.length_prefixed(2, 1024))
        |> Enum.to_list()
    """

  pub fn length_prefixed(prefix_bytes :: i64, max_frame_size :: i64) -> Framer.LengthPrefixed {
    checked_prefix_bytes = Framer.check_prefix_bytes(prefix_bytes)
    checked_max_frame_size = Framer.check_max_frame_size(max_frame_size)
    %Framer.LengthPrefixed{prefix_bytes: checked_prefix_bytes, max_frame_size: checked_max_frame_size, buffer: ""}
  }

  @doc = """
    A framer for newline-delimited frames: the byte stream is split on `\n`
    (the newline is stripped; a trailing `\r` is retained). Each complete line
    is emitted as `Result.Ok(line)`. An un-delimited run that reaches
    `max_frame_size` bytes emits `Result.Error(%Framer.Error{reason:
    :oversize})` and halts. On end-of-stream a non-empty trailing buffer (a
    final line with no newline) is emitted as `Result.Ok(line)` — a complete
    line, not a truncation.

    Panics loudly when `max_frame_size` is less than 1.

    ## Example

        Stream.transform(["hel", "lo\nwor", "ld\n"], Framer.line(1024))
        |> Enum.to_list()
    """

  pub fn line(max_frame_size :: i64) -> Framer.Line {
    checked_max_frame_size = Framer.check_max_frame_size(max_frame_size)
    %Framer.Line{max_frame_size: checked_max_frame_size, buffer: ""}
  }

  fn check_prefix_bytes(prefix_bytes :: i64) -> i64 {
    if prefix_bytes == 1 or prefix_bytes == 2 or prefix_bytes == 4 {
      prefix_bytes
    } else {
      panic("Framer.length_prefixed/2 requires prefix_bytes of 1, 2, or 4, got " <> Integer.to_string(prefix_bytes))
    }
  }

  fn check_max_frame_size(max_frame_size :: i64) -> i64 {
    if max_frame_size < 1 {
      panic("Framer requires a max_frame_size of at least 1, got " <> Integer.to_string(max_frame_size))
    } else {
      max_frame_size
    }
  }
}
