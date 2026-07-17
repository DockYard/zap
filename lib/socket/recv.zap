@doc = """
  `SocketRecv` — the EOF-safe result of a `Socket.recv` (Phase S1).

  The C `recv()` footgun is that a `0` return means end-of-stream, trivially
  confused with "no data yet" or an error — a bug that silently truncates
  streams. Zap kills it with the type system: `recv` returns a FOUR-variant
  union an exhaustive `case` MUST cover, with EOF as its own distinct
  constructor that cannot be ignored:

  * `Chunk(bytes)` — data arrived; `bytes` always carries **at least one
    byte** (never an empty chunk) and is BINARY-SAFE (arbitrary bytes,
    embedded NULs, invalid UTF-8 all survive intact).
  * `TimedOut(partial)` — the idle `timeout_ms` deadline fired. `partial`
    carries the bytes ALREADY consumed off the socket (a `recv_exact` that
    timed out mid-frame; empty for a next-available timeout that read
    nothing). Surfacing them — the Erlang `\#{error, {timeout, PartialData}}`
    lesson — means a framed reader never DESYNCs: the caller keeps `partial`
    and resumes reading the remainder. A timeout does NOT close the socket
    (Erlang semantics — it stays usable for a later `recv`).
  * `Closed` — clean EOF: the peer closed its write side and no more bytes
    will ever arrive. A distinct, payload-FREE constructor an exhaustive `case`
    must match, impossible to confuse with a chunk.
  * `Failed(error)` — the operation failed (connection reset, …).

  ## Examples

      case Socket.recv(socket, 5000) {
        SocketRecv.Chunk(bytes)     -> handle(bytes)
        SocketRecv.TimedOut(partial) -> resume_with(partial)
        SocketRecv.Closed           -> :eof
        SocketRecv.Failed(error)    -> log(error)
      }
  """

@available_on(:network)

pub union SocketRecv {
  Chunk :: String
  TimedOut :: String
  Closed
  Failed :: SocketError
}

@doc = """
  `SocketRecvDecoder` — the ONE shared decode core that turns a runtime `recv`
  status code + bytes into the EOF-safe `SocketRecv` union.

  It is a stateless namespace (no fields), the single point EVERY receive form
  routes its status → variant mapping through: `Socket.recv`/`recv_exact` (via
  `Socket.recv_from_handle`), `Socket.fold` (via its pull loop), and the
  `SocketChunks` stream pull. Each form then maps the returned `SocketRecv` onto
  its own tail, so the mapping lives in ONE place and cannot drift between forms
  (the divergence that once made a `chunks` idle timeout a bare stream error
  while `recv` surfaced a resumable partial).

  It lives on its OWN struct — depending on neither `Socket` nor `SocketChunks`
  — precisely so BOTH can call it WITHOUT a `Socket ↔ SocketChunks` mutual
  struct cycle (the dependency the codegen cannot yet resolve). This is the same
  neutral-home pattern `SocketError.reason_from_code` uses to keep `Socket` and
  `SocketListener` decoupled.

  ## Examples

      SocketRecvDecoder.decode(0, "hi")   # => SocketRecv.Chunk("hi")
  """

@available_on(:network)

pub struct SocketRecvDecoder {
  @doc = """
    Decodes a `recv` status code + `bytes` into the EOF-safe `SocketRecv` union.
    `0` = a data `Chunk` (always ≥ 1 byte); a NEGATIVE status = clean `Closed`
    (EOF); status `2` = an idle `TimedOut(partial)` — `bytes` is the already-
    consumed prefix, EMPTY for a next-available pull that read nothing, surfaced
    so a framed reader never desyncs (MED-1); any OTHER positive status = a
    `Failed` reason. A plain Bool cascade (no integer-literal `case` arm). A
    timeout NEVER closes the socket.

    ## Examples

        SocketRecvDecoder.decode(2, "")   # => SocketRecv.TimedOut("")
    """

  @available_on(:network)

  pub fn decode(status :: i64, bytes :: String) -> SocketRecv {
    case status == 0 {
      true -> SocketRecv.Chunk(bytes)
      false ->
        case status < 0 {
          true -> SocketRecv.Closed
          false ->
            case status == 2 {
              true -> SocketRecv.TimedOut(bytes)
              false -> SocketRecv.Failed(SocketError.from_code(status))
            }
        }
    }
  }
}


@doc = """
  `SocketRecvBlob` — the `Blob`-carrying analogue of `SocketRecv` for the
  zero-copy large-body path (`Socket.recv_blob`).

  Identical EOF-safe shape, but a `Chunk` carries a `Blob` (the shared,
  atomic-refcounted tier) rather than a `String`, so a large received body can
  be `Process.send_move`d down a pipeline of handler processes with no
  re-copy. `TimedOut(partial)` likewise carries the already-consumed bytes as
  a `Blob` (the no-desync partial surface, MED-1). Because a `Blob` only
  exists under the concurrency runtime, `Socket.recv_blob` is a gate-ON
  operation (a gate-OFF script uses the `String`-carrying `Socket.recv`).

  ## Examples

      case Socket.recv_blob(socket, 65536, 5000) {
        SocketRecvBlob.Chunk(body)     -> forward(body)
        SocketRecvBlob.TimedOut(partial) -> resume_with(partial)
        SocketRecvBlob.Closed          -> :eof
        SocketRecvBlob.Failed(error)   -> log(error)
      }
  """

@available_on(:network)

pub union SocketRecvBlob {
  Chunk :: Blob
  TimedOut :: Blob
  Closed
  Failed :: SocketError
}
