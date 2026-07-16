@doc = """
  `Socket` — a value-threaded handle to an open network socket (Phase S0 of
  the socket layer; `docs/socket-implementation-plan.md`).

  A `Socket` is a **one-word, single-owner, move-only** handle (Decision B):
  the reserved field `zap_socket_handle` is a generation-validated token into
  the runtime's fourth kernel-owned allocation domain, NOT a raw fd. Two
  processes reading one fd is a data race the model forbids, so a socket
  travels between processes only by `Process.send_move` (S1/S3) — never a
  plain copy — and using a closed or stale handle **panics loudly** (the
  generation check makes it memory-safe, never corrupting).

  Sockets work in BOTH concurrent (gate-ON) and plain-script (gate-OFF)
  programs: an HTTP-client script needs no `spawn`. Under the hood a blocking
  call parks off the process's core gate-ON and blocks the single OS thread
  gate-OFF — same semantics, one primitive (Decision D).

  ## Availability

  Every `Socket` declaration requires the `:network` target capability;
  `wasm32-wasi` (no socket API) rejects socket code at COMPILE time with the
  `:network` diagnostic — guard with a comptime `@target` branch or build for
  a `:network` target.

  ## Tier-1 scope (S1)

  The value-threaded Tier-1 op set: `connect`/`connect_to`, `send`/`send_all`/
  `send_some`, the EOF-safe `recv`/`recv_exact`/`recv_blob` returning
  `SocketRecv`, `shutdown` (half-close), `close`, `local_address`/
  `peer_address`/`local_port`, and the streaming Form-1 surface `chunks`/
  `fold` (an `Enumerable` of received chunks). `listen` yields a DISTINCT
  `SocketListener` (which `accept`s data `Socket`s); the type system alone
  forbids `recv` on a listener or `accept` on a data socket. Timeouts are
  poll-quantum-bounded (§6.1), never `SO_RCVTIMEO`, and a timeout never closes
  the socket.

  ## Examples

      case Socket.listen(SocketAddress.loopback(0), 128) {
        Result.Ok(listener) -> {
          port = SocketListener.local_port(listener)
          case Socket.connect(SocketAddress.loopback(port), 5000) {
            Result.Ok(client) -> { _ = Socket.close(client); _ = SocketListener.close(listener) }
            Result.Error(_error) -> _ = SocketListener.close(listener)
          }
        }
        Result.Error(_error) -> nil
      }
  """

@available_on(:network)

pub struct Socket {
  zap_socket_handle :: u64

  @doc = """
    Connects an IPv4 stream socket to `address`, waiting at most `timeout_ms`
    milliseconds (`0` = no deadline). Returns `Result.Ok(socket)` on success
    or `Result.Error(%SocketError{...})` with a matchable reason. The
    connection races nothing in S0 (single explicit address); happy-eyeballs
    over DNS is S1.

    Decision E: `timeout_ms` is a per-call relative timeout, never
    `SO_SNDTIMEO`. Its enforcement is poll-quantum-bounded from S1 (§6.1); in
    S0 it is accepted for the stable API shape (loopback connects instantly).

    ## Examples

        Socket.connect(SocketAddress.loopback(8080), 5000)
    """

  @available_on(:network)

  pub fn connect(address :: SocketAddress, timeout_ms :: i64) -> Result(Socket, SocketError) {
    case :zig.SocketRuntime.connect(address.a, address.b, address.c, address.d, address.port, timeout_ms) {
      0 -> Result(Socket, SocketError).Error(SocketError.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, SocketError).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Binds and listens an IPv4 stream socket on `address` with the given
    `backlog` (port 0 → an ephemeral port, discoverable via
    `SocketListener.local_port`), returning a DISTINCT `SocketListener` handle
    (Phase S1). `accept` it into per-connection `Socket`s; you cannot `send`/
    `recv` a listener (no such operation exists on the type). The backlog is
    capped by the OS `somaxconn`.

    ## Examples

        case Socket.listen(SocketAddress.loopback(0), 128) {
          Result.Ok(listener) -> SocketListener.local_port(listener)
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn listen(address :: SocketAddress, backlog :: i64) -> Result(SocketListener, SocketError) {
    case :zig.SocketRuntime.listen(address.a, address.b, address.c, address.d, address.port, backlog) {
      0 -> Result(SocketListener, SocketError).Error(SocketError.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(SocketListener, SocketError).Ok(%SocketListener{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Accepts the next inbound connection on `listener`, parking the fiber until
    one arrives (offloaded off the process's core gate-ON, inline gate-OFF).
    Returns `Result.Ok(socket)` — a data `Socket` that INHERITS the listener's
    options — or `Result.Error(%SocketError{...})`. Safe to call from many
    green processes on one listener (kernel-FIFO fairness). You cannot `accept`
    a data `Socket` (the parameter is a `SocketListener`) nor `send`/`recv` a
    listener — the distinct types make both a compile error. Panics on a closed
    or stale listener handle.

    ## Examples

        case Socket.accept(listener) {
          Result.Ok(connection) -> serve(connection)
          Result.Error(_error)  -> :accept_failed
        }
    """

  @available_on(:network)

  pub fn accept(listener :: SocketListener) -> Result(Socket, SocketError) {
    case :zig.SocketRuntime.accept(listener.zap_socket_handle) {
      0 -> Result(Socket, SocketError).Error(SocketError.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, SocketError).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Returns the local (bound) port of a socket — the ephemeral port a
    `listen(_, 0)` was assigned. Panics on a closed or stale handle.

    ## Examples

        case Socket.listen(SocketAddress.loopback(0), 128) {
          Result.Ok(listener) -> Socket.local_port(listener)   # => e.g. 54233
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn local_port(socket :: Socket) -> i64 {
    :zig.SocketRuntime.local_port(socket.zap_socket_handle)
  }

  @doc = """
    Closes the socket: recycles its domain slot (so every outstanding copy of
    the handle goes stale) and closes the fd. Optional for short-lived
    programs — the runtime closes a process's still-owned fds at exit AND on
    crash (the drop-list). Panics on a closed or stale handle
    (use-after-close), never corrupting memory.

    ## Examples

        case Socket.connect(SocketAddress.loopback(8080), 5000) {
          Result.Ok(client) -> Socket.close(client)
          Result.Error(_error) -> false
        }
    """

  @available_on(:network)

  pub fn close(socket :: Socket) -> Bool {
    :zig.SocketRuntime.close(socket.zap_socket_handle)
  }

  @doc = """
    Returns `true` while the socket is still open and owned by this program,
    `false` once it has been closed (its handle gone stale). Never panics —
    the safe probe companion to the panicking operations.

    ## Examples

        case Socket.connect(SocketAddress.loopback(8080), 5000) {
          Result.Ok(client) -> {
            was_open = Socket.open?(client)   # => true
            _ = Socket.close(client)
            was_open and !Socket.open?(client)
          }
          Result.Error(_error) -> false
        }
    """

  @available_on(:network)

  pub fn open?(socket :: Socket) -> Bool {
    :zig.SocketRuntime.is_live(socket.zap_socket_handle)
  }

  @doc = """
    Returns the number of sockets currently open across the whole runtime —
    the leak-exactness observability surface: after every socket is closed
    (or its owner exits) this returns to its baseline. For tests/diagnostics.

    ## Examples

        base = Socket.live_count()
        case Socket.listen(SocketAddress.loopback(0), 1) {
          Result.Ok(listener) -> {
            grew = Socket.live_count() > base
            _ = Socket.close(listener)
            grew
          }
          Result.Error(_error) -> false
        }
    """

  @available_on(:network)

  pub fn live_count() -> i64 {
    :zig.SocketRuntime.live_count()
  }

  @doc = """
    The explicit resolved-address connect (`connect_to/2`): connects to an
    already-resolved `SocketAddress`, identical to `connect/2` in S1 (DNS
    resolution inside `connect` and happy-eyeballs racing over multiple
    resolved addresses arrive with the hostname `connect` in a later phase;
    S1's `SocketAddress` is an explicit IPv4 endpoint, so there is nothing to
    race). Kept as the named escape hatch the `resolve` + `connect_to` pattern
    documents.

    ## Examples

        Socket.connect_to(SocketAddress.ip4(127, 0, 0, 1, 8080), 5000)
    """

  @available_on(:network)

  pub fn connect_to(address :: SocketAddress, timeout_ms :: i64) -> Result(Socket, SocketError) {
    Socket.connect(address, timeout_ms)
  }

  @doc = """
    Receives the NEXT available bytes (blocking until at least one byte arrives
    or the stream ends), returning the EOF-safe `SocketRecv` union: a
    `Chunk(bytes)` (always ≥ 1 byte, binary-safe), `Closed` on clean EOF, or
    `Failed(error)`. Parks the fiber off its core gate-ON, blocks the single OS
    thread gate-OFF. Panics on a closed or stale handle.

    ## Examples

        case Socket.recv(socket) {
          SocketRecv.Chunk(bytes) -> handle(bytes)
          SocketRecv.Closed       -> :eof
          SocketRecv.Failed(_e)   -> :error
        }
    """

  @available_on(:network)

  pub fn recv(socket :: Socket) -> SocketRecv {
    Socket.recv(socket, 0, 0)
  }

  @doc = """
    Receives EXACTLY `byte_count` bytes (blocking until that many arrive),
    returning `Chunk(bytes)` with all of them, `Closed` if the stream ends
    before `byte_count` bytes arrive (the partial prefix is dropped — the
    caller asked for a whole frame and the peer is done), or `Failed(error)`.
    When `byte_count` is `0` this is next-available. Panics on a stale handle.

    ## Examples

        Socket.recv(socket, 4)   # read a 4-byte length prefix
    """

  @available_on(:network)

  pub fn recv(socket :: Socket, byte_count :: i64) -> SocketRecv {
    Socket.recv(socket, byte_count, 0)
  }

  @doc = """
    Receives with an idle TIMEOUT: exactly `byte_count` bytes (or next-
    available when `byte_count` is `0`), waiting at most `timeout_ms`
    milliseconds (`0` = no deadline). On timeout returns `Failed(%SocketError{
    reason: :etimedout})` and — the Erlang guarantee — leaves the socket OPEN
    and usable (a later `recv` resumes). The timeout is enforced by a
    `poll(2)`-quantum loop in the runtime, NEVER `SO_RCVTIMEO` (§6.1).

    ## Examples

        Socket.recv(socket, 0, 5000)   # next chunk, 5s idle timeout
    """

  @available_on(:network)

  pub fn recv(socket :: Socket, byte_count :: i64, timeout_ms :: i64) -> SocketRecv {
    Socket.recv_from_handle(socket.zap_socket_handle, byte_count, timeout_ms)
  }

  @doc = """
    Receives from a raw socket handle and decodes the runtime's status into the
    EOF-safe `SocketRecv` union — the single decode point shared by `recv`,
    `fold`, and the `SocketChunks` stream pull. `byte_count == 0` is next-
    available; `> 0` is `recv_exact`; `timeout_ms` bounds each pull. The status
    read must IMMEDIATELY follow the receive (a non-yielding per-process slot),
    so the two `:zig` calls are paired with nothing between. A timeout decodes
    to `Failed(:etimedout)` and never closes the socket.
    """

  @available_on(:network)

  pub fn recv_from_handle(handle_bits :: u64, byte_count :: i64, timeout_ms :: i64) -> SocketRecv {
    bytes = :zig.SocketRuntime.recv(handle_bits, byte_count, timeout_ms)
    status = :zig.SocketRuntime.recv_status()
    Socket.decode_recv(status, bytes)
  }

  @doc = """
    Decodes a `recv` status code + bytes into the EOF-safe `SocketRecv` union:
    `0` = a data `Chunk`, a negative status = clean `Closed` (EOF), a positive
    status = a `Failed` reason (`2` = idle timeout). Split out so the decode is
    a plain Bool cascade (no integer-literal case arm).
    """

  @available_on(:network)

  fn decode_recv(status :: i64, bytes :: String) -> SocketRecv {
    case status == 0 {
      true -> SocketRecv.Chunk(bytes)
      false ->
        case status < 0 {
          true -> SocketRecv.Closed
          false -> SocketRecv.Failed(SocketError.from_code(status))
        }
    }
  }

  @doc = """
    Receives EXACTLY `byte_count` bytes with a `timeout_ms` idle deadline — the
    named `recv_exact` helper (identical to `recv/3` with a positive
    `byte_count`), for reading fixed-size frames/headers.

    ## Examples

        Socket.recv_exact(socket, 16, 5000)
    """

  @available_on(:network)

  pub fn recv_exact(socket :: Socket, byte_count :: i64, timeout_ms :: i64) -> SocketRecv {
    Socket.recv(socket, byte_count, timeout_ms)
  }

  @doc = """
    The `Blob`-carrying `recv` (`recv_blob`) for the zero-copy large-body path:
    receives up to/exactly `byte_count` bytes (or next-available when `0`) with
    a `timeout_ms` deadline and wraps the payload in a `Blob` — the shared tier
    a large body can be `Process.send_move`d through a handler pipeline with no
    re-copy. Returns the EOF-safe `SocketRecvBlob`. Requires the concurrency
    runtime (a `Blob` only exists gate-ON).

    ## Examples

        case Socket.recv_blob(socket, 65536, 5000) {
          SocketRecvBlob.Chunk(body) -> forward(body)
          SocketRecvBlob.Closed      -> :eof
          SocketRecvBlob.Failed(_e)  -> :error
        }
    """

  @available_on(:network)

  pub fn recv_blob(socket :: Socket, byte_count :: i64, timeout_ms :: i64) -> SocketRecvBlob {
    received = Socket.recv(socket, byte_count, timeout_ms)
    case received {
      SocketRecv.Chunk(bytes) -> SocketRecvBlob.Chunk(Blob.create(bytes))
      SocketRecv.Closed -> SocketRecvBlob.Closed
      SocketRecv.Failed(error) -> SocketRecvBlob.Failed(error)
    }
  }

  @doc = """
    Sends ALL of `bytes` or fails (`send/2`, all-or-error). Blocking writes
    park the fiber until the OS accepts the bytes, so backpressure is
    automatic. Returns `Result.Ok(byte_count)` on full delivery, or
    `Result.Error(%SocketError{..., bytes_sent: n})` reporting how much of the
    payload committed before the failure (the Erlang `RestData` lesson — no
    silent partial-send loss). Binary-safe. Panics on a stale handle.

    ## Examples

        Socket.send(socket, "hello")
    """

  @available_on(:network)

  pub fn send(socket :: Socket, bytes :: String) -> Result(i64, SocketError) {
    total = String.length(bytes)
    sent = :zig.SocketRuntime.send(socket.zap_socket_handle, bytes)
    case sent == total {
      true -> Result(i64, SocketError).Ok(sent)
      false -> Result(i64, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(:zig.SocketRuntime.last_error()), bytes_sent: sent})
    }
  }

  @doc = """
    The all-or-error send under its `send_all` name (identical to `send/2`) —
    the Tier-0 helper for callers that prefer the explicit spelling.

    ## Examples

        Socket.send_all(socket, payload)
    """

  @available_on(:network)

  pub fn send_all(socket :: Socket, bytes :: String) -> Result(i64, SocketError) {
    Socket.send(socket, bytes)
  }

  @doc = """
    Sends whatever the kernel accepts in ONE write (`send_some/2`, explicit
    partial). Returns `Result.Ok(bytes_written)` — which MAY be fewer than
    `String.length(bytes)`, and the caller decides how to handle the short
    write — or `Result.Error(error)`. Panics on a stale handle.

    ## Examples

        Socket.send_some(socket, payload)   # => Result.Ok(1400) perhaps
    """

  @available_on(:network)

  pub fn send_some(socket :: Socket, bytes :: String) -> Result(i64, SocketError) {
    written = :zig.SocketRuntime.send_some(socket.zap_socket_handle, bytes)
    case written > 0 {
      true -> Result(i64, SocketError).Ok(written)
      false ->
        case String.length(bytes) == 0 {
          true -> Result(i64, SocketError).Ok(0)
          false -> Result(i64, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(:zig.SocketRuntime.last_error()), bytes_sent: 0})
        }
    }
  }

  @doc = """
    Half-closes the socket in `direction` (`:read`, `:write`, or `:both`) — the
    graceful-close primitive. `shutdown(:write)` sends EOF to the peer while
    KEEPING THE HANDLE VALID so you can go on reading the peer's remaining
    bytes to its EOF (the graceful handshake); `close` is the full teardown.
    Returns `Result.Ok(true)` or `Result.Error(error)`. Panics on a stale
    handle.

    ## Examples

        Socket.shutdown(socket, :write)   # send EOF, keep reading
    """

  @available_on(:network)

  pub fn shutdown(socket :: Socket, direction :: Atom) -> Result(Bool, SocketError) {
    how = case direction {
      :read -> 0
      :write -> 1
      :both -> 2
      _ -> 2
    }
    case :zig.SocketRuntime.shutdown(socket.zap_socket_handle, how) {
      0 -> Result(Bool, SocketError).Ok(true)
      reason -> Result(Bool, SocketError).Error(SocketError.from_code(reason))
    }
  }

  @doc = """
    Returns the LOCAL (bound) `SocketAddress` of a connected socket via
    `getsockname` — the local endpoint the OS assigned (e.g. the ephemeral
    source port of an outbound connection). Panics on a stale handle.

    ## Examples

        Socket.local_address(socket)
    """

  @available_on(:network)

  pub fn local_address(socket :: Socket) -> SocketAddress {
    SocketAddress.from_packed(:zig.SocketRuntime.endpoint(socket.zap_socket_handle, 0))
  }

  @doc = """
    Returns the REMOTE (peer) `SocketAddress` of a connected socket via
    `getpeername`. Panics on a stale handle.

    ## Examples

        Socket.peer_address(socket)
    """

  @available_on(:network)

  pub fn peer_address(socket :: Socket) -> SocketAddress {
    SocketAddress.from_packed(:zig.SocketRuntime.endpoint(socket.zap_socket_handle, 1))
  }

  @doc = """
    Streams the socket as a `SocketChunks` — a concrete
    `Enumerable(Result(String, SocketError))` (the same convention `Stream.map`/
    `unfold` follow, returning the concrete adapter that auto-boxes as
    `Enumerable` at every consumer). The functional pull surface (Form 1,
    §4.1): a `for` comprehension and short-circuiting `Enum` consumers
    (`take`/`find`/`any?`) work over it — each `next` is a parking, next-
    available `recv` bounded by `timeout_ms` (backpressure is inherent —
    nothing is read until demanded). The stream ends on EOF / mid-stream error
    (final `Error` element) / idle timeout. For a direct fold with typed early-
    halt use `Socket.fold`.

    BORROW SEMANTICS: the stream borrows the socket; `dispose` (via an early
    `Enum.take`/`find`) releases only the iterator state and NEVER closes the
    fd — a fresh `chunks` resumes. See `SocketChunks` for the full boundedness
    table (which consumers are safe on a never-closing stream).

    ## Examples

        # Fold the byte total of a bounded stream to EOF:
        sizes = for chunk <- Socket.chunks(socket, 5000) {
          case chunk {
            Result.Ok(bytes)     -> String.length(bytes)
            Result.Error(_error) -> 0
          }
        }
        total = Enum.sum(sizes)
    """

  @available_on(:network)

  pub fn chunks(socket :: Socket, timeout_ms :: i64) -> SocketChunks {
    %SocketChunks{handle: socket.zap_socket_handle, timeout_ms: timeout_ms, active: true}
  }

  @doc = """
    The ergonomic direct fold over a live stream (`fold/4`) — thin sugar over
    `Socket.chunks` + `Enum.reduce_while`. Folds `callback` over each received
    chunk's bytes with typed early-halt: the callback returns `{:cont, acc}` to
    keep folding or `{:halt, acc}` to stop on its own protocol condition (a
    byte count, a terminator seen). Returns `Result.Ok(acc)` when the stream
    ends cleanly (EOF) or the callback halts, or `Result.Error(error)` on a
    mid-stream failure or idle timeout — the socket stays open on a timeout.

    Like any live-stream fold this is BOUNDED by EOF / error / idle-timeout /
    your `:halt` — an unbounded connection that keeps sending never returns
    (use `:halt`, or Form 2 active mode, for a persistent connection).

    ## Examples

        # Read until a NUL terminator or 1 KiB, whichever first:
        Socket.fold(socket, "", 5000, fn(acc, bytes) {
          combined = acc <> bytes
          if String.contains?(combined, "\\0") or String.length(combined) >= 1024 {
            {:halt, combined}
          } else {
            {:cont, combined}
          }
        })
    """

  @available_on(:network)

  pub fn fold(socket :: Socket, initial :: acc, timeout_ms :: i64, callback :: fn(acc, String) -> {Atom, acc}) -> Result(acc, SocketError) {
    Socket.fold_loop(socket.zap_socket_handle, timeout_ms, initial, callback)
  }

  @doc = """
    The pull-and-fold loop behind `Socket.fold`: pulls the next chunk (the same
    parking `recv` a `Socket.chunks` `next` performs) and applies `callback`
    with typed early-halt. `Chunk` → apply the callback (`{:cont, acc}` recurses
    for the next chunk; `{:halt, acc}` returns `Ok`); clean EOF → `Ok(acc)`; a
    mid-stream failure or idle timeout → `Error`. Recurses directly (calling
    `callback` at the leaf) rather than threading a `callback`-capturing closure
    through `Enum.reduce_while` — semantically the same bounded fold, but a plain
    tail-recursive pull so it composes with the same boundedness contract
    `chunks`/`Enum.reduce_while` document.
    """

  @available_on(:network)

  fn fold_loop(handle_bits :: u64, timeout_ms :: i64, acc :: acc, callback :: fn(acc, String) -> {Atom, acc}) -> Result(acc, SocketError) {
    received = Socket.recv_from_handle(handle_bits, 0, timeout_ms)
    case received {
      SocketRecv.Chunk(bytes) ->
        case callback(acc, bytes) {
          {:cont, continued} -> Socket.fold_loop(handle_bits, timeout_ms, continued, callback)
          {:halt, halted} -> Result(acc, SocketError).Ok(halted)
          {_other, fallthrough} -> Result(acc, SocketError).Ok(fallthrough)
        }
      SocketRecv.Closed -> Result(acc, SocketError).Ok(acc)
      SocketRecv.Failed(error) -> Result(acc, SocketError).Error(error)
    }
  }



}
