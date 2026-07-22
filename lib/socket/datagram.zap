@doc = """
  `Socket.Datagram` — a value-threaded handle to a DATAGRAM socket: UDP
  (`:ip4`) or Unix-domain datagram (`:unix`) (Phase S2,
  `docs/socket-implementation-plan.md`).

  Like `Socket`/`Socket.Listener` it is a **one-word, single-owner, move-only**
  handle (Decision B): the reserved `zap_socket_handle` field is a
  generation-validated token into the runtime's socket domain, NOT a raw fd. A
  datagram socket travels between processes only by `Process.send_move`, and
  using a closed/stale handle **panics loudly** (the generation check makes it
  memory-safe, never corrupting).

  Datagrams differ from streams in three ways the type surface makes explicit:

  * **No connection, no EOF.** `bind` opens an unconnected socket; `send_to`
    addresses each datagram explicitly and `recv_from` reports each datagram's
    SENDER. A datagram socket has no end-of-stream, so `Socket.DatagramRecv` has
    no `Closed` variant.
  * **Truncation is first-class.** A datagram larger than the receive buffer is
    surfaced through the distinct `Socket.DatagramRecv.Truncated` variant — never
    silently dropped. An exhaustive `case` FORCES a `Truncated` arm, so
    silent datagram loss is unrepresentable.
  * **Connected mode.** `connect` fixes a default peer; the kernel then FILTERS
    inbound datagrams to that peer and `send`/`recv` (no explicit address)
    address it.

  Works in BOTH concurrent (gate-ON) and plain-script (gate-OFF) programs
  (Decision D). S2 surfaces `:ip4` UDP, `:ip6` UDP (including a `:ip6` sender
  peer on `recv_from`), and `:unix` datagram (including the sender's reply PATH
  on `recv_from`); `bind`/`connect`/`send_to` on a genuinely-unsupported family
  return `:einval`.

  ## Availability

  Every declaration requires the `:network` target capability; `wasm32-wasi`
  rejects socket code at compile time.

  ## Examples

      case Socket.Datagram.bind(Socket.Address.loopback(0)) {
        Result.Ok(receiver) -> {
          port = Socket.Datagram.local_port(receiver)
          case Socket.Datagram.bind(Socket.Address.loopback(0)) {
            Result.Ok(sender) -> {
              _ = Socket.Datagram.send_to(sender, Socket.Address.loopback(port), "ping")
              case Socket.Datagram.recv_from(receiver, 65536, 5000) {
                Socket.DatagramRecv.Datagram(d)  -> d.data
                Socket.DatagramRecv.Truncated(d) -> d.data
                Socket.DatagramRecv.TimedOut     -> "timeout"
                Socket.DatagramRecv.Failed(_e)   -> "error"
              }
            }
            Result.Error(_e) -> "bind_failed"
          }
        }
        Result.Error(_e) -> "bind_failed"
      }
  """

@available_on(:network)

pub struct Socket.Datagram {
  zap_socket_handle :: u64

  @doc = """
    Binds a datagram socket to `address` (an `:ip4` or `:ip6` UDP socket, or a
    `:unix` Unix-domain datagram socket at the address's path). Port 0 (`:ip4`/
    `:ip6`) → an ephemeral port, discoverable via `local_port`. Returns
    `Result.Ok(socket)` or `Result.Error(%Socket.Error{...})`. For a Unix
    filesystem path, unlink any stale socket file before binding (Decision 4 —
    caller-managed cleanup). A genuinely-unsupported family returns `:einval`.

    ## Examples

        Socket.Datagram.bind(Socket.Address.loopback(0))
        Socket.Datagram.bind(Socket.Address.ip6_loopback(0))
        Socket.Datagram.bind(Socket.Address.unix("/tmp/app.sock"))
    """

  @available_on(:network)

  pub fn bind(address :: Socket.Address) -> Result(Socket.Datagram, Socket.Error) {
    case address.family {
      :ip4 -> Socket.Datagram.result_from_handle(:zig.SocketRuntime.bind_udp(address.a, address.b, address.c, address.d, address.port))
      :ip6 -> Socket.Datagram.result_from_handle(:zig.SocketRuntime.bind_udp6(address.h0, address.h1, address.h2, address.h3, address.h4, address.h5, address.h6, address.h7, address.scope_id, address.port))
      :unix -> Socket.Datagram.result_from_handle(:zig.SocketRuntime.bind_udp_unix(address.path))
      _ -> Result(Socket.Datagram, Socket.Error).Error(%Socket.Error{reason: :einval})
    }
  }

  @doc = """
    Connects a UDP datagram socket to `address` (an `:ip4` or `:ip6` endpoint) —
    sets a DEFAULT peer so the kernel filters inbound datagrams to it and
    `send`/`recv` (no explicit address) address it. Returns `Result.Ok(socket)`
    or `Result.Error(%Socket.Error{...})`. Unlike a stream connect this completes
    immediately (a datagram has no handshake). A genuinely-unsupported family
    returns `:einval`.

    ## Examples

        Socket.Datagram.connect(Socket.Address.ip4(127, 0, 0, 1, 9000))
        Socket.Datagram.connect(Socket.Address.ip6_loopback(9000))
    """

  @available_on(:network)

  pub fn connect(address :: Socket.Address) -> Result(Socket.Datagram, Socket.Error) {
    case address.family {
      :ip4 -> Socket.Datagram.result_from_handle(:zig.SocketRuntime.connect_udp(address.a, address.b, address.c, address.d, address.port))
      :ip6 -> Socket.Datagram.result_from_handle(:zig.SocketRuntime.connect_udp6(address.h0, address.h1, address.h2, address.h3, address.h4, address.h5, address.h6, address.h7, address.scope_id, address.port))
      _ -> Result(Socket.Datagram, Socket.Error).Error(%Socket.Error{reason: :einval})
    }
  }

  @doc = """
    Turns a runtime handle-bits result into a `Result(Socket.Datagram,
    Socket.Error)`: `0` → the typed last-error, else `Ok`. The error reason is
    read immediately after the failed op (a non-yielding per-process slot).
    Shared by `bind`/`connect` (an unsupported family never reaches here — those
    arms return `:einval` directly).
    """

  @available_on(:network)

  fn result_from_handle(raw :: u64) -> Result(Socket.Datagram, Socket.Error) {
    case raw {
      0 -> Result(Socket.Datagram, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket.Datagram, Socket.Error).Ok(%Socket.Datagram{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Sends `bytes` as ONE datagram to `address`, with NO deadline. Identical to
    `send_to/4` with a `0` timeout.

    ## Examples

        Socket.Datagram.send_to(socket, Socket.Address.loopback(9000), "ping")
    """

  @available_on(:network)

  pub fn send_to(datagram :: Socket.Datagram, address :: Socket.Address, bytes :: String) -> Result(i64, Socket.Error) {
    Socket.Datagram.send_to(datagram, address, bytes, 0)
  }

  @doc = """
    Sends `bytes` as ONE datagram to `address`, waiting at most `timeout_ms`
    milliseconds for the socket to become writable (`0` = no deadline). A
    datagram is ATOMIC — delivered whole or not at all — so on success the whole
    payload is sent (`Result.Ok(String.length(bytes))`); an oversize payload
    fails with `:einval` (`EMSGSIZE`), never a partial. Binary-safe. Dispatches
    on `address.family` (`:ip4`/`:ip6` UDP or `:unix` Unix datagram); a
    genuinely-unsupported family returns `:einval`. Panics on a stale handle.

    ## Examples

        Socket.Datagram.send_to(socket, Socket.Address.loopback(9000), payload, 5000)
    """

  @available_on(:network)

  pub fn send_to(datagram :: Socket.Datagram, address :: Socket.Address, bytes :: String, timeout_ms :: i64) -> Result(i64, Socket.Error) {
    total = String.length(bytes)
    case address.family {
      :ip4 -> Socket.Datagram.classify_send(:zig.SocketRuntime.send_to_ip4(datagram.zap_socket_handle, address.a, address.b, address.c, address.d, address.port, bytes, timeout_ms), total)
      :ip6 -> Socket.Datagram.classify_send(:zig.SocketRuntime.send_to_ip6(datagram.zap_socket_handle, address.h0, address.h1, address.h2, address.h3, address.h4, address.h5, address.h6, address.h7, address.scope_id, address.port, bytes, timeout_ms), total)
      :unix -> Socket.Datagram.classify_send(:zig.SocketRuntime.send_to_unix(datagram.zap_socket_handle, address.path, bytes, timeout_ms), total)
      _ -> Result(i64, Socket.Error).Error(%Socket.Error{reason: :einval})
    }
  }

  @doc = """
    Sends `bytes` on a CONNECTED datagram socket (its peer fixed by `connect`),
    waiting at most `timeout_ms` (`0` = no deadline). One atomic datagram to the
    connected peer. Returns `Result.Ok(String.length(bytes))` on success or a
    typed error. Panics on a stale handle.

    ## Examples

        Socket.Datagram.send(connected, "ping", 5000)
    """

  @available_on(:network)

  pub fn send(datagram :: Socket.Datagram, bytes :: String, timeout_ms :: i64) -> Result(i64, Socket.Error) {
    total = String.length(bytes)
    sent = :zig.SocketRuntime.send(datagram.zap_socket_handle, bytes, timeout_ms)
    Socket.Datagram.classify_send(sent, total)
  }

  @doc = """
    Classifies a datagram send's byte count against the payload length: the full
    payload committed → `Ok`; else the typed last-error reason with the bytes
    that committed (`0` for a datagram). The error reason is read immediately
    after the failed send (a non-yielding per-process slot).
    """

  @available_on(:network)

  fn classify_send(sent :: i64, total :: i64) -> Result(i64, Socket.Error) {
    case sent == total {
      true -> Result(i64, Socket.Error).Ok(sent)
      false -> Result(i64, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(:zig.SocketRuntime.last_error()), bytes_sent: sent})
    }
  }

  @doc = """
    Receives ONE datagram (blocking until one arrives or `timeout_ms` elapses),
    returning the truncation-safe `Socket.DatagramRecv` union. `max_bytes` caps
    the receive buffer (clamped by the runtime to the 64 KiB datagram maximum;
    `0` or less uses that maximum). On success a `Datagram(data)` (or
    `Truncated(data)` when the datagram exceeded `max_bytes`) carries the bytes,
    the SENDER's `Socket.Address`, and the datagram's true size; an idle timeout
    yields `TimedOut` (the socket stays OPEN — Decision E); a failure yields
    `Failed(error)`. Parks the fiber off its core gate-ON, blocks the single OS
    thread gate-OFF. Panics on a stale handle.

    ## Examples

        case Socket.Datagram.recv_from(socket, 65536, 5000) {
          Socket.DatagramRecv.Datagram(d)  -> handle(d.data, d.peer)
          Socket.DatagramRecv.Truncated(d) -> handle_partial(d.data, d.datagram_size)
          Socket.DatagramRecv.TimedOut     -> :idle
          Socket.DatagramRecv.Failed(_e)   -> :error
        }
    """

  @available_on(:network)

  pub fn recv_from(datagram :: Socket.Datagram, max_bytes :: i64, timeout_ms :: i64) -> Socket.DatagramRecv {
    bytes = :zig.SocketRuntime.recv_from(datagram.zap_socket_handle, max_bytes, timeout_ms)
    Socket.Datagram.decode_recv(bytes)
  }

  @doc = """
    Receives ONE datagram on a CONNECTED datagram socket (from its fixed peer),
    identical to `recv_from/3` — the connected-mode receive. The kernel already
    filtered to the connected peer, so `data.peer` is that peer.

    ## Examples

        Socket.Datagram.recv(connected, 65536, 5000)
    """

  @available_on(:network)

  pub fn recv(datagram :: Socket.Datagram, max_bytes :: i64, timeout_ms :: i64) -> Socket.DatagramRecv {
    Socket.Datagram.recv_from(datagram, max_bytes, timeout_ms)
  }

  @doc = """
    Reads the recv metadata slots (status, truncation flag, datagram length, and
    the sender endpoint) IMMEDIATELY after a `recv_from` and decodes them, with
    `bytes`, into the `Socket.DatagramRecv` union via
    `Socket.DatagramRecvDecoder.decode` — the single decode point. The reads are
    paired with the receive (a non-yielding per-process slot), so no other op
    can interpose.
    """

  @available_on(:network)

  fn decode_recv(bytes :: String) -> Socket.DatagramRecv {
    status = :zig.SocketRuntime.recv_status()
    truncated = :zig.SocketRuntime.recv_truncated()
    datagram_size = :zig.SocketRuntime.recv_datagram_len()
    peer = Socket.Datagram.recv_peer_address()
    Socket.DatagramRecvDecoder.decode(status, truncated, bytes, peer, datagram_size)
  }

  @doc = """
    Reconstructs the SENDER's `Socket.Address` from the recv-peer accessor slots
    (the datagram-peer twin of `Socket.Address.of_handle`'s decode): the packed v4
    fast path, else the four v6 words (a real `:ip6` sender surfaces its address),
    else the Unix `sun_path` (`recv_peer_path` → a String → `unix_from_path`), so
    a BOUND Unix datagram sender surfaces a `:unix` reply address the server can
    `send_to`. Only an UNNAMED/unbound sender (no v4, no v6, empty path) surfaces
    `:unavailable`.
    """

  @available_on(:network)

  fn recv_peer_address() -> Socket.Address {
    packed = :zig.SocketRuntime.recv_peer()
    case packed < 0 {
      false -> Socket.Address.from_packed(packed)
      true ->
        {
          word0 = :zig.SocketRuntime.recv_peer_v6_word(0)
          case word0 < 0 {
            true -> Socket.Datagram.recv_peer_unix()
            false ->
              {
                word1 = :zig.SocketRuntime.recv_peer_v6_word(1)
                word2 = :zig.SocketRuntime.recv_peer_v6_word(2)
                word3 = :zig.SocketRuntime.recv_peer_v6_word(3)
                scope_id = :zig.SocketRuntime.recv_peer_scope()
                port = :zig.SocketRuntime.recv_peer_port()
                Socket.Address.ip6_from_words(word0, word1, word2, word3, scope_id, port)
              }
          }
        }
    }
  }

  @doc = """
    Resolves a non-v4/non-v6 `recv_from` sender to a `:unix` `Socket.Address`
    carrying the sender's `sun_path` (`recv_peer_path` → a String →
    `unix_from_path`), or `:unavailable` when the sender is UNBOUND (empty path —
    it has no reply address). The datagram-recv twin of
    `Socket.Address.of_unix_handle`.
    """

  @available_on(:network)

  fn recv_peer_unix() -> Socket.Address {
    path = :zig.SocketRuntime.recv_peer_path()
    case String.length(path) == 0 {
      true -> %Socket.Address{family: :unavailable}
      false -> Socket.Address.unix_from_path(path)
    }
  }

  @doc = """
    Returns the LOCAL (bound) `Socket.Address` of the datagram socket via
    `getsockname`. Panics on a stale handle.

    ## Examples

        Socket.Datagram.local_address(socket)
    """

  @available_on(:network)

  pub fn local_address(datagram :: Socket.Datagram) -> Socket.Address {
    Socket.Address.of_handle(datagram.zap_socket_handle, 0)
  }

  @doc = """
    Returns the LOCAL port of a UDP datagram socket via `getsockname` — the
    ephemeral port a `bind(_, 0)` was assigned, or the ephemeral SOURCE port the
    OS auto-assigned to a `connect`ed datagram socket (a thin read of
    `local_address(socket).port`, so it is correct for BOTH bound and connected
    sockets, unlike the domain-slot bound port which is `0` for a connected
    socket). Panics on a stale handle. `0` for a Unix datagram socket (no port).

    ## Examples

        Socket.Datagram.local_port(socket)
    """

  @available_on(:network)

  pub fn local_port(datagram :: Socket.Datagram) -> i64 {
    local = Socket.Datagram.local_address(datagram)
    local.port
  }

  @doc = """
    Returns the REMOTE (connected peer) `Socket.Address` of a CONNECTED datagram
    socket via `getpeername`, or `:unavailable` for an unconnected socket. Panics
    on a stale handle.

    ## Examples

        Socket.Datagram.peer_address(connected)
    """

  @available_on(:network)

  pub fn peer_address(datagram :: Socket.Datagram) -> Socket.Address {
    Socket.Address.of_handle(datagram.zap_socket_handle, 1)
  }

  @doc = """
    Closes the datagram socket: recycles its domain slot (every outstanding copy
    of the handle goes stale) and closes the fd. Optional for short-lived
    programs — the runtime closes still-owned fds at exit and on crash. Panics on
    a closed or stale handle (use-after-close), never corrupting memory.

    ## Examples

        Socket.Datagram.close(socket)
    """

  @available_on(:network)

  pub fn close(datagram :: Socket.Datagram) -> Bool {
    :zig.SocketRuntime.close(datagram.zap_socket_handle)
  }

  @doc = """
    Returns `true` while the datagram socket is still open and owned by this
    program, `false` once closed. Never panics.

    ## Examples

        Socket.Datagram.open?(socket)
    """

  @available_on(:network)

  pub fn open?(datagram :: Socket.Datagram) -> Bool {
    :zig.SocketRuntime.is_live(datagram.zap_socket_handle)
  }
}

@doc = """
  `Socket.DatagramData` — the payload of a received datagram (Phase S2): the
  `data` bytes (binary-safe, embedded NULs survive), the SENDER's `peer`
  `Socket.Address`, and the datagram's true `datagram_size` (exact on Linux; the
  captured floor on macOS). Carried by both the `Socket.DatagramRecv.Datagram`
  and `Socket.DatagramRecv.Truncated` variants — on `Truncated`, `data` is the
  captured PREFIX and `datagram_size` reports how much was actually sent, so the
  loss is quantified, never silent.
  """

@available_on(:network)

pub struct Socket.DatagramData {
  data :: String
  peer :: Socket.Address
  datagram_size :: i64
}

@doc = """
  `Socket.DatagramRecv` — the truncation-safe result of a `Socket.Datagram`
  receive (Phase S2), the datagram analogue of the stream `Socket.Recv`.

  A datagram socket has no end-of-stream, so there is NO `Closed` variant; a
  datagram larger than the receive buffer is NOT silently dropped but surfaced
  through its OWN `Truncated` variant, which an exhaustive `case` must handle —
  making silent datagram loss unrepresentable:

  * `Datagram(data)` — a whole datagram arrived; `data` carries the bytes, the
    sender's address, and the true size (`data.datagram_size == length(data)`).
  * `Truncated(data)` — the datagram was LARGER than the receive buffer;
    `data.data` is the captured prefix and `data.datagram_size` the true (larger)
    size, so the caller knows exactly how much was lost.
  * `TimedOut` — the idle `timeout_ms` deadline fired with no datagram; the
    socket stays OPEN and usable (Decision E — a timeout never closes it).
  * `Failed(error)` — the receive failed (a typed `Socket.Error`).

  ## Examples

      case Socket.Datagram.recv_from(socket, 1024, 5000) {
        Socket.DatagramRecv.Datagram(d)  -> use(d.data)
        Socket.DatagramRecv.Truncated(d) -> log_oversize(d.datagram_size)
        Socket.DatagramRecv.TimedOut     -> :idle
        Socket.DatagramRecv.Failed(_e)   -> :error
      }
  """

@available_on(:network)

pub union Socket.DatagramRecv {
  Datagram :: Socket.DatagramData
  Truncated :: Socket.DatagramData
  TimedOut
  Failed :: Socket.Error
}

@doc = """
  `Socket.DatagramRecvDecoder` — the ONE shared decode core that turns a runtime
  `recv_from` status (+ truncation flag, bytes, peer, datagram size) into the
  `Socket.DatagramRecv` union.

  A stateless namespace (no fields), the single point every datagram receive form
  (`recv_from`, connected `recv`) routes its status → variant mapping through, so
  the mapping lives in ONE place and cannot drift between forms. This is the
  datagram twin of `Socket.RecvDecoder`, on its own struct so the receive forms
  call it without a mutual struct cycle.

  ## Examples

      Socket.DatagramRecvDecoder.decode(0, 0, "hi", peer, 2)   # => Datagram
      Socket.DatagramRecvDecoder.decode(0, 1, "hi", peer, 100) # => Truncated
  """

@available_on(:network)

pub struct Socket.DatagramRecvDecoder {
  @doc = """
    Decodes a `recv_from` result into the `Socket.DatagramRecv` union: `status 0`
    = a datagram (`truncated 1` → `Truncated`, else `Datagram`, both carrying a
    `Socket.DatagramData` of `bytes`/`peer`/`datagram_size`); `status 2` = an idle
    `TimedOut` (the socket stays open); any other positive `status` = a `Failed`
    reason. There is NO `Closed` (datagrams have no EOF). A plain Bool cascade
    (no integer-literal `case` arm).

    ## Examples

        Socket.DatagramRecvDecoder.decode(2, 0, "", peer, 0)   # => TimedOut
    """

  @available_on(:network)

  pub fn decode(status :: i64, truncated :: i64, bytes :: String, peer :: Socket.Address, datagram_size :: i64) -> Socket.DatagramRecv {
    case status == 0 {
      true ->
        {
          data = %Socket.DatagramData{data: bytes, peer: peer, datagram_size: datagram_size}
          case truncated == 1 {
            true -> Socket.DatagramRecv.Truncated(data)
            false -> Socket.DatagramRecv.Datagram(data)
          }
        }
      false ->
        case status == 2 {
          true -> Socket.DatagramRecv.TimedOut
          false -> Socket.DatagramRecv.Failed(Socket.Error.from_code(status))
        }
    }
  }
}
