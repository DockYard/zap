@doc = """
  `Socket` — a value-threaded handle to an open network socket (the
  value-threaded socket layer; `docs/socket-implementation-plan.md`).

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

  The value-threaded Tier-1 op set: `connect`/`connect_to` (resolved address)
  and `connect_host` (connect by NAME with RFC 8305 Happy Eyeballs over DNS),
  `send`/`send_all`/`send_some`, the EOF-safe `recv`/`recv_exact` returning
  `Socket.Recv` (and `recv_blob` returning the `Blob`-carrying `Socket.RecvBlob`),
  `shutdown` (half-close), `close`, `local_address`/`peer_address`/
  `local_port`/`peer_port`, and the streaming Form-1 surface `chunks`/`fold`
  (an `Enumerable` of received chunks). `listen` yields a DISTINCT
  `Socket.Listener` (which `accept`s data `Socket`s); the type system alone
  forbids `recv` on a listener or `accept` on a data socket. Timeouts are
  poll-quantum-bounded (§6.1), never `SO_RCVTIMEO`, and a timeout never closes
  the socket.

  ## Cross-process handoff — `controlling_process` (S3)

  Because a `Socket` is single-owner and move-only, changing which process serves
  a connection is a `Process.send_move` of the handle — the `controlling_process`
  operation, executed BY the current owner:

      handler = Process.spawn_link(&MyServer.handler_entry/0)
      _moved = Process.send_move((Pid.of(handler) :: Pid(Socket)), connection)

  The receiver ADOPTS it through a top-level `receive Socket { s -> s }` and then
  owns it outright (the sender's handle is consumed — a use after the move is a
  compile error). This is exactly how the acceptor/handler server pattern hands
  each accepted connection to a per-connection handler.

  DEAD-LETTER RULE: if the target pid is already dead, `send_move` returns
  `false` and the runtime CLOSES the socket — a handed-off connection never
  leaks its fd, whether it is adopted, dropped at the receiver's teardown, or
  dead-lettered. The caller performs NO cleanup on a `false` return (the fd is
  already closed).

  ## Examples

      case Socket.listen(Socket.Address.loopback(0), 128) {
        Result.Ok(listener) -> {
          port = Socket.Listener.local_port(listener)
          case Socket.connect(Socket.Address.loopback(port), 5000) {
            Result.Ok(client) -> { _ = Socket.close(client); _ = Socket.Listener.close(listener) }
            Result.Error(_error) -> _ = Socket.Listener.close(listener)
          }
        }
        Result.Error(_error) -> nil
      }
  """

@available_on(:network)

pub struct Socket {
  zap_socket_handle :: u64

  @doc = """
    Connects a stream socket to `address`, waiting at most `timeout_ms`
    milliseconds (`0` = no deadline). An `:ip4` address connects an IPv4 TCP
    socket; a `:unix` address (Phase S2) connects a Unix-domain STREAM socket to
    the address's path. Returns `Result.Ok(socket)` on success or
    `Result.Error(%Socket.Error{...})` with a matchable reason. The connection
    races nothing — `address` is a single explicit, already-resolved endpoint;
    connect by NAME with RFC 8305 Happy Eyeballs over DNS is
    `Socket.connect_host/3`.

    Decision E: `timeout_ms` is a per-call relative timeout, never
    `SO_SNDTIMEO`. Its enforcement is poll-quantum-bounded (§6.1): a
    non-blocking connect polled against an ABSOLUTE monotonic deadline, so a
    black-holed address is bounded by the deadline rather than the OS default.

    ## Examples

        Socket.connect(Socket.Address.loopback(8080), 5000)
    """

  @available_on(:network)

  pub fn connect(address :: Socket.Address, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    raw = case address.family {
      :unix -> :zig.SocketRuntime.connect_unix(address.path, timeout_ms)
      _ -> :zig.SocketRuntime.connect(address.a, address.b, address.c, address.d, address.port, timeout_ms)
    }
    case raw {
      0 -> Result(Socket, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Binds and listens a stream socket on `address` with the given `backlog`
    (an `:ip4` address binds an IPv4 TCP listener — port 0 → an ephemeral port,
    discoverable via `Socket.Listener.local_port`; a `:unix` address, Phase S2,
    binds a Unix-domain STREAM listener at the address's path), returning a
    DISTINCT `Socket.Listener` handle (Phase S1). `accept` it into per-connection
    `Socket`s (Unix-domain accepts flow through the SAME `accept`); you cannot
    `send`/`recv` a listener (no such operation exists on the type). The backlog
    is capped by the OS `somaxconn`. For a Unix filesystem path, unlink any stale
    socket file before binding (Decision 4 — caller-managed cleanup).

    ## Examples

        case Socket.listen(Socket.Address.loopback(0), 128) {
          Result.Ok(listener) -> Socket.Listener.local_port(listener)
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn listen(address :: Socket.Address, backlog :: i64) -> Result(Socket.Listener, Socket.Error) {
    raw = case address.family {
      :unix -> :zig.SocketRuntime.listen_unix(address.path, backlog)
      _ -> :zig.SocketRuntime.listen(address.a, address.b, address.c, address.d, address.port, backlog)
    }
    case raw {
      0 -> Result(Socket.Listener, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket.Listener, Socket.Error).Ok(%Socket.Listener{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Binds and listens like `listen/2`, but honoring the PRE-BIND options in
    `options` — `reuse_address` (`SO_REUSEADDR`) and `reuse_port`
    (`SO_REUSEPORT`), which the OS only respects when set BEFORE `bind`, so the
    runtime applies them to the fresh socket in the listen path pre-bind. The
    listener's `backlog` comes from the explicit argument (not `options`).
    Accepted connections INHERIT the listener's kernel-level options.

    Use this (not `set_options` after `listen`) when you need `reuse_port` /
    `reuse_address`: applying them post-bind is too late to matter. The other
    `Socket.Options` fields (nodelay, keepalive, buffers, linger) are per-
    connection concerns — set them on the accepted `Socket` with `set_options`.

    ## Examples

        Socket.listen(Socket.Address.loopback(0), 128, %Socket.Options{reuse_port: true})
    """

  @available_on(:network)

  pub fn listen(address :: Socket.Address, backlog :: i64, options :: Socket.Options) -> Result(Socket.Listener, Socket.Error) {
    case :zig.SocketRuntime.listen_with_options(address.a, address.b, address.c, address.d, address.port, backlog, options.reuse_address, options.reuse_port) {
      0 -> Result(Socket.Listener, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket.Listener, Socket.Error).Ok(%Socket.Listener{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Accepts the next inbound connection on `listener`, parking the fiber until
    one arrives (offloaded off the process's core gate-ON, inline gate-OFF).
    Returns `Result.Ok(socket)` — a data `Socket` that INHERITS the listener's
    options — or `Result.Error(%Socket.Error{...})`. You cannot `accept` a data
    `Socket` (the parameter is a `Socket.Listener`) nor `send`/`recv` a listener —
    the distinct types make both a compile error. Panics on a closed or stale
    listener handle.

    A `Socket.Listener` is single-owner like every socket handle (Decision B): it
    is `accept`ed by the ONE process that owns it, not shared. The
    acceptor/handler server pattern is therefore ONE process looping `accept` and
    handing each accepted `Socket` to a fresh handler by `Process.send_move`
    (`controlling_process` — owner-executed handoff); `lib/socket/server.zap`
    (`Socket.Server`) is the policy scaffold, and `Socket.Listener.close` (or the
    owner's death) is what stops it.

    ## Examples

        case Socket.accept(listener) {
          Result.Ok(connection) -> serve(connection)
          Result.Error(_error)  -> :accept_failed
        }
    """

  @available_on(:network)

  pub fn accept(listener :: Socket.Listener) -> Result(Socket, Socket.Error) {
    case :zig.SocketRuntime.accept(listener.zap_socket_handle) {
      0 -> Result(Socket, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Accepts the next inbound connection on `listener`, BOUNDED by `timeout_ms`
    (Phase S3, Job 2): if no connection arrives within `timeout_ms` milliseconds
    the call returns `Result.Error(%Socket.Error{reason: :etimedout})` instead of
    parking forever. `timeout_ms <= 0` is the infinite `accept/1` behavior.

    The deadline is poll-quantum-bounded against an ABSOLUTE monotonic instant
    (§6.1), never `SO_RCVTIMEO`, and a timeout never closes the listener — the
    next `accept` resumes normally. This is the primitive a TRAPPING acceptor
    (the server pattern's connection mini-supervisor) needs: parked in an
    infinite `accept` it would never observe a cooperative `:shutdown` signal
    (a trapped signal sets no pending-kill), so it loops on the short deadline,
    checking for shutdown/reaping handler exits each time it wakes.

    A timed-out `accept` produced no connection, so it leaks NO fd; a kill during
    a bounded `accept` reclaims any just-accepted fd exactly as `accept/1` does
    (the same teardown-visible pending-fd slot).

    ## Examples

        case Socket.accept(listener, 50) {
          Result.Ok(connection)                       -> dispatch(connection)
          Result.Error(%Socket.Error{reason: :etimedout}) -> keep_serving()
          Result.Error(_error)                        -> :accept_failed
        }
    """

  @available_on(:network)

  pub fn accept(listener :: Socket.Listener, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case :zig.SocketRuntime.accept_timeout(listener.zap_socket_handle, timeout_ms) {
      0 -> Result(Socket, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Returns the LOCAL port of a connected data `Socket` via `getsockname` — the
    ephemeral source port the OS assigned to an outbound `connect` (a thin read
    of `local_address(socket).port`, the symmetric companion to `peer_port`).
    For a LISTENER's bound port use `Socket.Listener.local_port`. Panics on a
    closed or stale handle.

    ## Examples

        case Socket.connect(Socket.Address.loopback(port), 5000) {
          Result.Ok(client) -> Socket.local_port(client)   # => e.g. 54233
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn local_port(socket :: Socket) -> i64 {
    local = Socket.local_address(socket)
    local.port
  }

  @doc = """
    Closes the socket: recycles its domain slot (so every outstanding copy of
    the handle goes stale) and closes the fd. Optional for short-lived
    programs — the runtime closes a process's still-owned fds at exit AND on
    crash (the drop-list). Panics on a closed or stale handle
    (use-after-close), never corrupting memory.

    ## Examples

        case Socket.connect(Socket.Address.loopback(8080), 5000) {
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

        case Socket.connect(Socket.Address.loopback(8080), 5000) {
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
        case Socket.listen(Socket.Address.loopback(0), 1) {
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
    already-resolved `Socket.Address`, identical to `connect/2` in S1 (DNS
    resolution inside `connect` and happy-eyeballs racing over multiple
    resolved addresses arrive with the hostname `connect` in a later phase;
    S1's `Socket.Address` is an explicit IPv4 endpoint, so there is nothing to
    race). Kept as the named escape hatch the `resolve` + `connect_to` pattern
    documents.

    ## Examples

        Socket.connect_to(Socket.Address.ip4(127, 0, 0, 1, 8080), 5000)
    """

  @available_on(:network)

  pub fn connect_to(address :: Socket.Address, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    Socket.connect(address, timeout_ms)
  }

  @doc = """
    Connects to `host:port` by NAME, with RFC 8305 Happy Eyeballs (`connect_host/3`):
    the runtime resolves the host name, interleaves the resolved IPv6 and IPv4
    addresses (v6, v4, v6, v4, …), and RACES the connection attempts —
    staggered by the ~250 ms Connection Attempt Delay and bounded to a small
    cap — returning the FIRST address that connects. Every losing attempt's fd
    is closed on the spot, so a slow or black-holed address never wastes an fd
    and never gates a reachable one. Real IPv6 racing, competitive with modern
    languages, over the value-threaded `Socket` handle.

    `timeout_ms` (`0` = no deadline) is ONE absolute deadline across BOTH the
    resolve and the race (Decision E — a per-call relative timeout, never
    `SO_*TIMEO`). Returns `Result.Ok(socket)` on the winning connection, or
    `Result.Error(%Socket.Error{...})`: `:nxdomain` when the name resolves to no
    address, `:einval` when the name is not a valid host name (RFC 1123),
    `:etimedout` when the whole resolve+race exceeds the deadline, or a POSIX
    reason (e.g. `:econnrefused`) from the last failed attempt.

    Works in both concurrent (gate-ON) and plain-script (gate-OFF) programs;
    the resolve step blocks the calling thread (the platform resolver is
    uninterruptible), bounded by the address cap and the deadline. Use
    `connect`/`connect_to` when you already hold a resolved `Socket.Address`.

    ## Examples

        case Socket.connect_host("example.com", 443, 5000) {
          Result.Ok(socket)    -> socket
          Result.Error(_error) -> :unreachable
        }
    """

  @available_on(:network)

  pub fn connect_host(host :: String, port :: i64, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case :zig.SocketRuntime.connect_host(host, port, timeout_ms) {
      0 -> Result(Socket, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Receives the NEXT available bytes (blocking until at least one byte arrives
    or the stream ends), returning the EOF-safe `Socket.Recv` union: a
    `Chunk(bytes)` (always ≥ 1 byte, binary-safe), `Closed` on clean EOF, or
    `Failed(error)`. Parks the fiber off its core gate-ON, blocks the single OS
    thread gate-OFF. Panics on a closed or stale handle.

    ## Examples

        case Socket.recv(socket) {
          Socket.Recv.Chunk(bytes) -> handle(bytes)
          Socket.Recv.Closed       -> :eof
          Socket.Recv.Failed(_e)   -> :error
        }
    """

  @available_on(:network)

  pub fn recv(socket :: Socket) -> Socket.Recv {
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

  pub fn recv(socket :: Socket, byte_count :: i64) -> Socket.Recv {
    Socket.recv(socket, byte_count, 0)
  }

  @doc = """
    Receives with an idle TIMEOUT: exactly `byte_count` bytes (or next-
    available when `byte_count` is `0`), waiting at most `timeout_ms`
    milliseconds (`0` = no deadline). On timeout returns `TimedOut(partial)` —
    carrying any bytes ALREADY consumed off the socket (a `recv_exact` that
    timed out mid-frame; empty for a next-available timeout) so a framed reader
    never desyncs (MED-1) — and, the Erlang guarantee, leaves the socket OPEN
    and usable (a later `recv` resumes with `partial` prepended). The timeout
    is enforced by an ABSOLUTE-monotonic-deadline `poll(2)`-quantum loop in the
    runtime, NEVER `SO_RCVTIMEO` (§6.1), so a byte-dribbling peer cannot defeat
    it.

    ## Examples

        Socket.recv(socket, 0, 5000)   # next chunk, 5s idle timeout
    """

  @available_on(:network)

  pub fn recv(socket :: Socket, byte_count :: i64, timeout_ms :: i64) -> Socket.Recv {
    Socket.recv_from_handle(socket.zap_socket_handle, byte_count, timeout_ms)
  }

  @doc = """
    Receives from a raw socket handle and decodes the runtime's status into the
    EOF-safe `Socket.Recv` union via `Socket.RecvDecoder.decode` — the ONE shared
    decode core `recv`/`recv_exact`, `Socket.fold`, and the `Socket.Chunks`
    stream pull all route through (each then maps the union onto its own tail),
    so the status → variant mapping cannot drift between forms. `byte_count == 0` is
    next-available; `> 0` is `recv_exact`; `timeout_ms` bounds each pull. The
    status read must IMMEDIATELY follow the receive (a non-yielding per-process
    slot), so the two `:zig` calls are paired with nothing between. A timeout
    decodes to `TimedOut(partial)` — carrying any bytes already consumed off the
    socket — and never closes the socket.
    """

  @available_on(:network)

  pub fn recv_from_handle(handle_bits :: u64, byte_count :: i64, timeout_ms :: i64) -> Socket.Recv {
    bytes = :zig.SocketRuntime.recv(handle_bits, byte_count, timeout_ms)
    status = :zig.SocketRuntime.recv_status()
    Socket.RecvDecoder.decode(status, bytes)
  }

  @doc = """
    Receives EXACTLY `byte_count` bytes with a `timeout_ms` idle deadline — the
    named `recv_exact` helper (identical to `recv/3` with a positive
    `byte_count`), for reading fixed-size frames/headers.

    ## Examples

        Socket.recv_exact(socket, 16, 5000)
    """

  @available_on(:network)

  pub fn recv_exact(socket :: Socket, byte_count :: i64, timeout_ms :: i64) -> Socket.Recv {
    Socket.recv(socket, byte_count, timeout_ms)
  }

  @doc = """
    The `Blob`-carrying `recv` (`recv_blob`) for the zero-copy large-body path:
    receives up to/exactly `byte_count` bytes (or next-available when `0`) with
    a `timeout_ms` deadline and wraps the payload in a `Blob` — the shared tier
    a large body can be `Process.send_move`d through a handler pipeline with no
    re-copy. Returns the EOF-safe `Socket.RecvBlob`. Requires the concurrency
    runtime (a `Blob` only exists gate-ON).

    ## Examples

        case Socket.recv_blob(socket, 65536, 5000) {
          Socket.RecvBlob.Chunk(body) -> forward(body)
          Socket.RecvBlob.Closed      -> :eof
          Socket.RecvBlob.Failed(_e)  -> :error
        }
    """

  @available_on(:network)

  pub fn recv_blob(socket :: Socket, byte_count :: i64, timeout_ms :: i64) -> Socket.RecvBlob {
    received = Socket.recv(socket, byte_count, timeout_ms)
    case received {
      Socket.Recv.Chunk(bytes) -> Socket.RecvBlob.Chunk(Blob.create(bytes))
      Socket.Recv.TimedOut(partial) -> Socket.RecvBlob.TimedOut(Blob.create(partial))
      Socket.Recv.Closed -> Socket.RecvBlob.Closed
      Socket.Recv.Failed(error) -> Socket.RecvBlob.Failed(error)
    }
  }

  @doc = """
    Sends ALL of `bytes` or fails (`send/2`, all-or-error), with NO send
    deadline (`timeout_ms = 0`). Identical to `send/3` with a `0` timeout.

    ## Examples

        Socket.send(socket, "hello")
    """

  @available_on(:network)

  pub fn send(socket :: Socket, bytes :: String) -> Result(i64, Socket.Error) {
    Socket.send(socket, bytes, 0)
  }

  @doc = """
    Sends ALL of `bytes` or fails (`send/3`, all-or-error), waiting at most
    `timeout_ms` milliseconds (`0` = no deadline). The write is bounded by a
    `poll(2)`-quantum loop, NEVER `SO_SNDTIMEO` (Decision E): a peer that
    accepts and never reads (slowloris-on-send) can no longer block the send
    forever — it times out and the socket stays OPEN (a timeout never closes
    it), and under the concurrency runtime the send stays kill-responsive so it
    can never pin a blocking-pool thread. Returns `Result.Ok(byte_count)` on
    full delivery, or `Result.Error(%Socket.Error{..., bytes_sent: n})`
    reporting how much of the payload committed before the failure or timeout
    (the Erlang `RestData` lesson — no silent partial-send loss). Binary-safe.
    Panics on a stale handle.

    ## Examples

        Socket.send(socket, big_payload, 5000)   # send, 5s deadline
    """

  @available_on(:network)

  pub fn send(socket :: Socket, bytes :: String, timeout_ms :: i64) -> Result(i64, Socket.Error) {
    total = String.length(bytes)
    sent = :zig.SocketRuntime.send(socket.zap_socket_handle, bytes, timeout_ms)
    case sent == total {
      true -> Result(i64, Socket.Error).Ok(sent)
      false -> Result(i64, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(:zig.SocketRuntime.last_error()), bytes_sent: sent})
    }
  }

  @doc = """
    The all-or-error send under its `send_all` name (identical to `send/2`) —
    the Tier-0 helper for callers that prefer the explicit spelling.

    ## Examples

        Socket.send_all(socket, payload)
    """

  @available_on(:network)

  pub fn send_all(socket :: Socket, bytes :: String) -> Result(i64, Socket.Error) {
    Socket.send(socket, bytes, 0)
  }

  @doc = """
    The all-or-error send under its `send_all` name with a `timeout_ms`
    deadline (identical to `send/3`).

    ## Examples

        Socket.send_all(socket, payload, 5000)
    """

  @available_on(:network)

  pub fn send_all(socket :: Socket, bytes :: String, timeout_ms :: i64) -> Result(i64, Socket.Error) {
    Socket.send(socket, bytes, timeout_ms)
  }

  @doc = """
    Sends whatever the kernel accepts in ONE write (`send_some/2`, explicit
    partial), with NO deadline. Identical to `send_some/3` with a `0` timeout.

    ## Examples

        Socket.send_some(socket, payload)   # => Result.Ok(1400) perhaps
    """

  @available_on(:network)

  pub fn send_some(socket :: Socket, bytes :: String) -> Result(i64, Socket.Error) {
    Socket.send_some(socket, bytes, 0)
  }

  @doc = """
    Sends whatever the kernel accepts in ONE write (`send_some/3`, explicit
    partial), waiting at most `timeout_ms` milliseconds (`0` = no deadline) for
    the socket to become writable — the same poll-quantum, kill-responsive
    bounding `send/3` uses (a single stalled write cannot pin a pool thread).
    Returns `Result.Ok(bytes_written)` — which MAY be fewer than
    `String.length(bytes)`, and the caller decides how to handle the short
    write — or `Result.Error(error)`. Panics on a stale handle.

    ## Examples

        Socket.send_some(socket, payload, 5000)
    """

  @available_on(:network)

  pub fn send_some(socket :: Socket, bytes :: String, timeout_ms :: i64) -> Result(i64, Socket.Error) {
    written = :zig.SocketRuntime.send_some(socket.zap_socket_handle, bytes, timeout_ms)
    case written > 0 {
      true -> Result(i64, Socket.Error).Ok(written)
      false ->
        case String.length(bytes) == 0 {
          true -> Result(i64, Socket.Error).Ok(0)
          false -> Result(i64, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(:zig.SocketRuntime.last_error()), bytes_sent: 0})
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

  pub fn shutdown(socket :: Socket, direction :: Atom) -> Result(Bool, Socket.Error) {
    how = case direction {
      :read -> 0
      :write -> 1
      :both -> 2
      _ -> 2
    }
    case :zig.SocketRuntime.shutdown(socket.zap_socket_handle, how) {
      0 -> Result(Bool, Socket.Error).Ok(true)
      reason -> Result(Bool, Socket.Error).Error(Socket.Error.from_code(reason))
    }
  }

  @doc = """
    Returns the LOCAL (bound) `Socket.Address` of a connected socket via
    `getsockname` — the local endpoint the OS assigned (e.g. the ephemeral
    source port of an outbound connection). An IPv4 connection yields an `:ip4`
    address; a connection that won over IPv6 (a `connect_host` Happy-Eyeballs
    race) yields a real `:ip6` address; a Unix-domain (`:unix`) connection yields
    the bound socket `path`; `:unavailable` only when the socket is genuinely
    unbound/unnamed. Panics on a stale handle.

    ## Examples

        Socket.local_address(socket)
    """

  @available_on(:network)

  pub fn local_address(socket :: Socket) -> Socket.Address {
    Socket.address_of(socket.zap_socket_handle, 0)
  }

  @doc = """
    Returns the REMOTE (peer) `Socket.Address` of a connected socket via
    `getpeername` — an `:ip4` address for an IPv4 connection, a real `:ip6`
    address for one that won over IPv6 (a `connect_host` Happy-Eyeballs race),
    a Unix-domain (`:unix`) peer's socket `path` (e.g. the listener's bound path
    a client connected to), or `:unavailable` only when genuinely unconnected/
    unnamed. Panics on a stale handle.

    ## Examples

        Socket.peer_address(socket)
    """

  @available_on(:network)

  pub fn peer_address(socket :: Socket) -> Socket.Address {
    Socket.address_of(socket.zap_socket_handle, 1)
  }

  @doc = """
    Resolves the endpoint (`which` `0` = local/`getsockname`, `1` = peer/
    `getpeername`) of a socket handle into a `Socket.Address` — a thin delegate to
    the shared `Socket.Address.of_handle` decoder (the single decode point stream
    `Socket` and `Socket.Datagram` both route through). The v4 fast path is
    BYTE-IDENTICAL to the packed decode; a v6 endpoint reconstructs from the four
    32-bit address words; a `:unix` endpoint surfaces its `sun_path`
    (`endpoint_unix_path` → a String → `unix_from_path`), so a Unix-domain stream
    connection's `local_address`/`peer_address` now carry the bound path.
    """

  @available_on(:network)

  fn address_of(handle_bits :: u64, which :: i64) -> Socket.Address {
    Socket.Address.of_handle(handle_bits, which)
  }

  @doc = """
    Returns the REMOTE (peer) port of a connected data `Socket` — the port on
    the far end of the connection (the symmetric companion to `local_port`, a
    thin read of `peer_address(socket).port`). Panics on a closed or stale
    handle.

    ## Examples

        case Socket.connect(Socket.Address.loopback(port), 5000) {
          Result.Ok(client) -> Socket.peer_port(client)   # => the listener's port
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn peer_port(socket :: Socket) -> i64 {
    peer = Socket.peer_address(socket)
    peer.port
  }

  @doc = """
    Streams the socket as a `Socket.Chunks` — a concrete
    `Enumerable(Result(String, Socket.Error))` (the same convention `Stream.map`/
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
    fd — a fresh `chunks` resumes. See `Socket.Chunks` for the full boundedness
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

  pub fn chunks(socket :: Socket, timeout_ms :: i64) -> Socket.Chunks {
    %Socket.Chunks{handle: socket.zap_socket_handle, timeout_ms: timeout_ms, active: true}
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

  pub fn fold(socket :: Socket, initial :: acc, timeout_ms :: i64, callback :: fn(acc, String) -> {Atom, acc}) -> Result(acc, Socket.Error) {
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

  fn fold_loop(handle_bits :: u64, timeout_ms :: i64, acc :: acc, callback :: fn(acc, String) -> {Atom, acc}) -> Result(acc, Socket.Error) {
    received = Socket.recv_from_handle(handle_bits, 0, timeout_ms)
    case received {
      Socket.Recv.Chunk(bytes) ->
        case callback(acc, bytes) {
          {:cont, continued} -> Socket.fold_loop(handle_bits, timeout_ms, continued, callback)
          {:halt, halted} -> Result(acc, Socket.Error).Ok(halted)
          {_other, fallthrough} -> Result(acc, Socket.Error).Ok(fallthrough)
        }
      # A next-available fold pull carries no partial (byte_count 0 reads
      # nothing on timeout), so an idle timeout ends the fold as an Error —
      # its documented mid-stream boundedness.
      Socket.Recv.TimedOut(_partial) -> Result(acc, Socket.Error).Error(%Socket.Error{reason: :etimedout})
      Socket.Recv.Closed -> Result(acc, Socket.Error).Ok(acc)
      Socket.Recv.Failed(error) -> Result(acc, Socket.Error).Error(error)
    }
  }

  @doc = """
    Applies `options` to `socket` via `setsockopt`, returning
    `Result.Ok(socket)` (the same value-threaded handle, for rebinding) once
    every option applied, or `Result.Error(%Socket.Error{...})` on failure. This
    is the OPT-IN that makes `Socket.Options`' defaults take effect: a bare
    `connect` keeps OS-default behavior (Nagle ON), and calling
    `set_options(socket, Socket.Options.default())` turns on the latency-first
    `TCP_NODELAY` (and the rest of the curated set) — a deliberate, applied-on-
    request posture, never an automatic flip of every socket.

    Each field is pushed through the runtime bridge, short-circuiting on the
    first `setsockopt` failure; fields at their "unset" sentinel are skipped (a
    buffer size of `0` = leave the OS default; `linger_ms` of `-1` = no
    override; `ip6_only` applied only when `true`). A stale or foreign handle
    yields `Result.Error(%Socket.Error{reason: :closed})` — the ownership gate,
    surfaced as a recoverable error rather than a panic (unlike `send`/`recv`,
    a config op on a closed socket is not a program bug). `reuse_address` /
    `reuse_port` are pre-bind options; set those with `Socket.listen/3`, not
    here (post-bind they are inert).

    ## Examples

        case Socket.connect(Socket.Address.loopback(8080), 5000) {
          Result.Ok(client) ->
            case Socket.set_options(client, Socket.Options.default()) {
              Result.Ok(configured) -> Socket.send(configured, "GET / HTTP/1.0\\r\\n\\r\\n")
              Result.Error(error)   -> Result(i64, Socket.Error).Error(error)
            }
          Result.Error(error) -> Result(i64, Socket.Error).Error(error)
        }
    """

  @available_on(:network)

  pub fn set_options(socket :: Socket, options :: Socket.Options) -> Result(Socket, Socket.Error) {
    status = Socket.Options.apply_to_handle(options, socket.zap_socket_handle)
    case status == 0 {
      true -> Result(Socket, Socket.Error).Ok(socket)
      false ->
        case status < 0 {
          true -> Result(Socket, Socket.Error).Error(%Socket.Error{reason: :closed})
          false -> Result(Socket, Socket.Error).Error(Socket.Error.from_code(status))
        }
    }
  }

  @doc = """
    Reads back a curated socket option from `socket` via `getsockopt` — the
    introspection/verification companion to `set_options`. `option_code` is the
    stable option tag (`0` nodelay, `1` keepalive, `2` recv_buffer, `3`
    send_buffer, `4` reuse_address, `5` reuse_port, `6` ip6_only, `7` linger),
    the ABI contract with the runtime's `socket_io.SocketOption`. Returns the
    OS-applied value (a `0`/`1` bool, a byte count, or `linger` milliseconds),
    or `-1` when the socket is not a live handle this program owns or the
    option could not be read. Lets a program CONFIRM that, say,
    `set_options(_, %Socket.Options{nodelay: true})` actually took effect
    (`get_option(socket, 0) == 1`), not merely that the call was accepted.

    ## Examples

        _ = Socket.set_options(socket, %Socket.Options{nodelay: true})
        Socket.get_option(socket, 0)   # => 1 (TCP_NODELAY is on)
    """

  @available_on(:network)

  pub fn get_option(socket :: Socket, option_code :: i64) -> i64 {
    :zig.SocketRuntime.get_option(socket.zap_socket_handle, option_code)
  }

}
