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

  ## S0 scope

  S0 lands the foundation: `connect` (IPv4), a minimal `listen` (so a
  self-contained program can drive a loopback exchange), `local_port`,
  `close`, `open?`, and `live_count`. The full Tier-1 op set —
  `send`/`recv`/`shutdown`, the EOF-safe `Socket.Recv` union, streaming, and
  the distinct `Socket.Listener` type — lands in S1.

  ## Examples

      case Socket.listen(SocketAddress.loopback(0), 128) {
        Result.Ok(listener) -> {
          port = Socket.local_port(listener)
          case Socket.connect(SocketAddress.loopback(port), 5000) {
            Result.Ok(client) -> { _ = Socket.close(client); _ = Socket.close(listener) }
            Result.Error(_error) -> _ = Socket.close(listener)
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
    case :zig.Socket.connect(address.a, address.b, address.c, address.d, address.port, timeout_ms) {
      0 -> Result(Socket, SocketError).Error(Socket.error_from_code(:zig.Socket.last_error()))
      handle_bits -> Result(Socket, SocketError).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Binds and listens an IPv4 stream socket on `address` with the given
    `backlog` (port 0 → an ephemeral port, discoverable via `local_port`).

    The S0 minimal listener: enough for a self-contained loopback exchange (a
    connect to a listening socket completes in the kernel's accept queue
    without an `accept` call). The distinct `Socket.Listener` type, `accept`,
    and the acceptor-pool pattern land in S1/S3.

    ## Examples

        case Socket.listen(SocketAddress.loopback(0), 128) {
          Result.Ok(listener) -> Socket.local_port(listener)
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn listen(address :: SocketAddress, backlog :: i64) -> Result(Socket, SocketError) {
    case :zig.Socket.listen(address.a, address.b, address.c, address.d, address.port, backlog) {
      0 -> Result(Socket, SocketError).Error(Socket.error_from_code(:zig.Socket.last_error()))
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
    :zig.Socket.local_port(socket.zap_socket_handle)
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
    :zig.Socket.close(socket.zap_socket_handle)
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
    :zig.Socket.is_live(socket.zap_socket_handle)
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
    :zig.Socket.live_count()
  }

  @doc = """
    Maps a runtime failure reason code to a typed `SocketError`. Kept in Zap
    (not the compiler) so the code → atom mapping is testable and the
    matchable reason set lives with the language, not hardcoded in Zig.
    """

  @available_on(:network)

  fn error_from_code(code :: i64) -> SocketError {
    case code {
      1 -> %SocketError{reason: :econnrefused}
      2 -> %SocketError{reason: :etimedout}
      3 -> %SocketError{reason: :ehostunreach}
      4 -> %SocketError{reason: :enetunreach}
      5 -> %SocketError{reason: :econnreset}
      6 -> %SocketError{reason: :eaddrinuse}
      7 -> %SocketError{reason: :eaddrnotavail}
      8 -> %SocketError{reason: :emfile}
      9 -> %SocketError{reason: :eacces}
      10 -> %SocketError{reason: :enetdown}
      11 -> %SocketError{reason: :enomem}
      _ -> %SocketError{reason: :unknown}
    }
  }
}
