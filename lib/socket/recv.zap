@doc = """
  `SocketRecv` — the EOF-safe result of a `Socket.recv` (Phase S1).

  The C `recv()` footgun is that a `0` return means end-of-stream, trivially
  confused with "no data yet" or an error — a bug that silently truncates
  streams. Zap kills it with the type system: `recv` returns a THREE-variant
  union an exhaustive `case` MUST cover, with EOF as its own distinct
  constructor that cannot be ignored:

  * `Chunk(bytes)` — data arrived; `bytes` always carries **at least one
    byte** (never an empty chunk) and is BINARY-SAFE (arbitrary bytes,
    embedded NULs, invalid UTF-8 all survive intact).
  * `Closed` — clean EOF: the peer closed its write side and no more bytes
    will ever arrive. A distinct, payload-FREE constructor an exhaustive `case`
    must match, impossible to confuse with a chunk.
  * `Failed(error)` — the operation failed (connection reset, an idle
    `:etimedout`, …). A timeout does NOT close the socket (Erlang semantics —
    the socket stays usable for a later `recv`).

  ## Examples

      case Socket.recv(socket, 5000) {
        SocketRecv.Chunk(bytes)  -> handle(bytes)
        SocketRecv.Closed        -> :eof
        SocketRecv.Failed(error) -> log(error)
      }
  """

@available_on(:network)

pub union SocketRecv {
  Chunk :: String
  Closed
  Failed :: SocketError
}


@doc = """
  `SocketRecvBlob` — the `Blob`-carrying analogue of `SocketRecv` for the
  zero-copy large-body path (`Socket.recv_blob`).

  Identical EOF-safe shape, but a `Chunk` carries a `Blob` (the shared,
  atomic-refcounted tier) rather than a `String`, so a large received body can
  be `Process.send_move`d down a pipeline of handler processes with no
  re-copy. Because a `Blob` only exists under the concurrency runtime,
  `Socket.recv_blob` is a gate-ON operation (a gate-OFF script uses the
  `String`-carrying `Socket.recv`).

  ## Examples

      case Socket.recv_blob(socket, 65536, 5000) {
        SocketRecvBlob.Chunk(body) -> forward(body)
        SocketRecvBlob.Closed      -> :eof
        SocketRecvBlob.Failed(error) -> log(error)
      }
  """

@available_on(:network)

pub union SocketRecvBlob {
  Chunk :: Blob
  Closed
  Failed :: SocketError
}
