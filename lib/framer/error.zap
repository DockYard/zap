@doc = """
  The error a `Framer` stage emits — as a value, never a raise — when the byte
  stream violates the framing contract.

  A framer is a `Stage(String, Result(String, Framer.Error))`: a complete frame
  flows out as `Result.Ok(payload)`, and a protocol violation flows out as
  `Result.Error(%Framer.Error{reason: ...})` immediately followed by `:halt`.
  Errors are ordinary stream elements — they are never raised.

  ## Reasons

  - `:truncated` — leftover bytes remained in the framer's buffer at
    end-of-stream that do not form a complete frame (an incomplete final
    frame). Emitted by `Framer.length_prefixed/2` on `flush`.
  - `:oversize` — a frame's declared or accumulated length exceeded the
    framer's `max_frame_size`. This is the denial-of-service bound: it stops
    an adversarial peer from forcing unbounded buffering. Emitted mid-stream
    with `:halt`.
  - `:unknown` — the default placeholder reason; a well-formed framer always
    sets a specific reason.
  """

@code Z1005
pub error Framer.Error {
  reason :: Atom = :unknown
}
