@doc = """
  `SocketChunks` — the pull-based stream a `Socket.chunks/2` returns: an
  `Enumerable(Result(String, SocketError))` whose every `next` is a PARKING
  `recv` pull (Phase S1, streaming Form 1, §4.1).

  Backpressure is inherent — nothing is read until demanded, so a slow
  downstream throttles the pull from the socket automatically. The stream is
  BOUNDED by the connection: it ends (`:done`) on clean EOF, on a mid-stream
  failure (one final `Error` element, then `:done`), or on an idle timeout
  (each pull is bounded by `timeout_ms`; an idle connection yields
  `Error(:etimedout)` then `:done`).

  ## Borrow semantics — the stream does NOT own the socket

  `SocketChunks` carries only the socket's one-word HANDLE (never the `Socket`
  value itself), so it merely BORROWS the connection. `dispose` releases only
  the iterator state and NEVER closes the fd, so an early exit through any
  `Enum` consumer (`take`/`find`/`any?`) leaves the socket fully open — a fresh
  `Socket.chunks` resumes reading exactly where the last one left off. The real
  owner keeps its `Socket` value and remains responsible for `close`. (Carrying
  the handle rather than the `Socket` also keeps `SocketChunks → SocketRecv` a
  one-directional dependency instead of a `Socket ↔ SocketChunks` cycle.)

  ## Boundedness — which `Enum` operations are safe on a LIVE stream

  A `Socket.chunks` stream terminates only on EOF / error / idle-timeout /
  caller-bounded consumption. The safe-on-live-streams consumers short-circuit
  or fold without materializing: `Enum.reduce`, `Enum.reduce_while`,
  `Enum.each`, `Enum.take`, `Enum.find`, `Enum.any?`, `Enum.all?`, `Enum.first`
  and `Socket.fold`. The EAGER materializers — `Enum.map`, `Enum.filter`,
  `Enum.to_list`, `Enum.sort`, `Enum.reverse`, `Enum.count` — run to `:done`
  and/or accumulate the whole stream, so on a socket that never closes they are
  an OOM or a never-returns; use them only on a stream you KNOW is bounded
  (a request/response, an HTTP body, "read until EOF"). A long-running open
  socket is not a fold that returns — it is a server loop (active mode, S6).

  ## Examples

      # Fold a bounded stream to EOF (the fiber parks between chunks):
      total = Enum.reduce(Socket.chunks(socket, 5000), 0, fn(sum, chunk) {
        case chunk {
          Result.Ok(bytes)     -> sum + String.length(bytes)
          Result.Error(_error) -> sum
        }
      })
  """

@available_on(:network)

pub struct SocketChunks {
  handle :: u64
  timeout_ms :: i64
  active :: Bool
}

@doc = """
  The `Enumerable(Result(String, SocketError))` behaviour of a `SocketChunks`
  stream: each `next` is a parking, next-available `recv` bounded by the
  stream's `timeout_ms`.
  """

@available_on(:network)

pub impl Enumerable(Result(String, SocketError)) for SocketChunks {
  @doc = """
    Yields the next chunk: `Result.Ok(bytes)` on data, a final
    `Result.Error(error)` then `:done` on a mid-stream failure or idle
    timeout, and `:done` on clean EOF. Once the stream has terminated it keeps
    reporting `:done` without touching the socket.
    """

  pub fn next(self :: unique SocketChunks) -> {Atom, Result(String, SocketError), SocketChunks} {
    case self.active {
      false -> {:done, SocketChunks.manufactured(), self}
      true -> SocketChunks.pull(self.handle, self.timeout_ms)
    }
  }

  @doc = """
    Disposes an unconsumed stream. BORROW SEMANTICS: this releases only the
    iterator state and NEVER closes the socket fd — the owner keeps its
    `Socket`, and a fresh `Socket.chunks` resumes where this left off.
    """

  pub fn dispose(_self :: unique SocketChunks) -> Nil {
    nil
  }

  # Pulls the next chunk from the runtime handle and routes the status through
  # `SocketRecvDecoder.decode` — the SAME shared decode core `Socket.recv`/`fold`
  # use — then maps the returned `SocketRecv` onto this stream's `Result`
  # element (the per-form tail). Routing through the NEUTRAL `SocketRecvDecoder`
  # (which references neither `Socket` nor `SocketChunks`) keeps `SocketChunks`
  # free of any reference to `Socket`, so `Socket → SocketChunks` (via
  # `Socket.chunks`) stays a one-directional dependency, not a mutual struct
  # cycle — while the decode itself is no longer a second, drift-prone copy.
  fn pull(handle :: u64, timeout_ms :: i64) -> {Atom, Result(String, SocketError), SocketChunks} {
    bytes = :zig.SocketRuntime.recv(handle, 0, timeout_ms)
    status = :zig.SocketRuntime.recv_status()
    SocketChunks.emit(handle, timeout_ms, SocketRecvDecoder.decode(status, bytes))
  }

  # Maps a decoded `SocketRecv` onto the stream tuple. `Chunk` → a data element
  # (`:cont`, resume). `Closed` (clean EOF) → `:done`. `TimedOut` → because a
  # `SocketChunks` pull is always next-available (`byte_count 0`), an idle
  # timeout read NOTHING, so `partial` is EMPTY (no data loss): the stream ends
  # the idle connection with a final `Error(:etimedout)` element then `:done` —
  # consistent with `Socket.fold`, which ends the same next-available pull as
  # `Error(:etimedout)`. (`recv`/`recv_exact` keep the resumable
  # `TimedOut(partial)`, which may carry consumed bytes.) `Failed` → a final
  # `Error` element then `:done`.
  fn emit(handle :: u64, timeout_ms :: i64, received :: SocketRecv) -> {Atom, Result(String, SocketError), SocketChunks} {
    case received {
      SocketRecv.Chunk(bytes) -> {:cont, Result(String, SocketError).Ok(bytes), SocketChunks.resume(handle, timeout_ms)}
      SocketRecv.Closed -> {:done, SocketChunks.manufactured(), SocketChunks.terminal(handle, timeout_ms)}
      SocketRecv.TimedOut(_partial) -> {:cont, Result(String, SocketError).Error(%SocketError{reason: :etimedout}), SocketChunks.terminal(handle, timeout_ms)}
      SocketRecv.Failed(error) -> {:cont, Result(String, SocketError).Error(error), SocketChunks.terminal(handle, timeout_ms)}
    }
  }

  fn resume(handle :: u64, timeout_ms :: i64) -> SocketChunks {
    %SocketChunks{handle: handle, timeout_ms: timeout_ms, active: true}
  }

  fn terminal(handle :: u64, timeout_ms :: i64) -> SocketChunks {
    %SocketChunks{handle: handle, timeout_ms: timeout_ms, active: false}
  }

  fn manufactured() -> Result(String, SocketError) {
    Result(String, SocketError).Ok("")
  }
}
