@doc = """
  `SocketDatagram` — a value-threaded handle to a DATAGRAM socket: UDP
  (`:ip4`) or Unix-domain datagram (`:unix`) (Phase S2,
  `docs/socket-implementation-plan.md`).

  Like `Socket`/`SocketListener` it is a **one-word, single-owner, move-only**
  handle (Decision B): the reserved `zap_socket_handle` field is a
  generation-validated token into the runtime's socket domain, NOT a raw fd. A
  datagram socket travels between processes only by `Process.send_move`, and
  using a closed/stale handle **panics loudly** (the generation check makes it
  memory-safe, never corrupting).

  Datagrams differ from streams in three ways the type surface makes explicit:

  * **No connection, no EOF.** `bind` opens an unconnected socket; `send_to`
    addresses each datagram explicitly and `recv_from` reports each datagram's
    SENDER. A datagram socket has no end-of-stream, so `SocketDatagramRecv` has
    no `Closed` variant.
  * **Truncation is first-class.** A datagram larger than the receive buffer is
    surfaced through the distinct `SocketDatagramRecv.Truncated` variant — never
    silently dropped. An exhaustive `case` FORCES a `Truncated` arm, so
    silent datagram loss is unrepresentable.
  * **Connected mode.** `connect` fixes a default peer; the kernel then FILTERS
    inbound datagrams to that peer and `send`/`recv` (no explicit address)
    address it.

  Works in BOTH concurrent (gate-ON) and plain-script (gate-OFF) programs
  (Decision D). S2 surfaces `:ip4` UDP and `:unix` datagram; `:ip6` UDP is a
  documented follow-up (`send_to`/`bind` on a non-`:ip4`/`:unix` address returns
  `:einval`).

  ## Availability

  Every declaration requires the `:network` target capability; `wasm32-wasi`
  rejects socket code at compile time.

  ## Examples

      case SocketDatagram.bind(SocketAddress.loopback(0)) {
        Result.Ok(receiver) -> {
          port = SocketDatagram.local_port(receiver)
          case SocketDatagram.bind(SocketAddress.loopback(0)) {
            Result.Ok(sender) -> {
              _ = SocketDatagram.send_to(sender, SocketAddress.loopback(port), "ping")
              case SocketDatagram.recv_from(receiver, 65536, 5000) {
                SocketDatagramRecv.Datagram(d)  -> d.data
                SocketDatagramRecv.Truncated(d) -> d.data
                SocketDatagramRecv.TimedOut     -> "timeout"
                SocketDatagramRecv.Failed(_e)   -> "error"
              }
            }
            Result.Error(_e) -> "bind_failed"
          }
        }
        Result.Error(_e) -> "bind_failed"
      }
  """

@available_on(:network)

pub struct SocketDatagram {
  zap_socket_handle :: u64

  @doc = """
    Binds a datagram socket to `address` (an `:ip4` UDP socket, or a `:unix`
    Unix-domain datagram socket at the address's path). Port 0 (`:ip4`) → an
    ephemeral port, discoverable via `local_port`. Returns `Result.Ok(socket)`
    or `Result.Error(%SocketError{...})`. For a Unix filesystem path, unlink any
    stale socket file before binding (Decision 4 — caller-managed cleanup). A
    non-`:ip4`/`:unix` address returns `:einval` (`:ip6` UDP is a follow-up).

    ## Examples

        SocketDatagram.bind(SocketAddress.loopback(0))
        SocketDatagram.bind(SocketAddress.unix("/tmp/app.sock"))
    """

  @available_on(:network)

  pub fn bind(address :: SocketAddress) -> Result(SocketDatagram, SocketError) {
    case address.family {
      :ip4 -> SocketDatagram.result_from_handle(:zig.SocketRuntime.bind_udp(address.a, address.b, address.c, address.d, address.port))
      :unix -> SocketDatagram.result_from_handle(:zig.SocketRuntime.bind_udp_unix(address.path))
      _ -> Result(SocketDatagram, SocketError).Error(%SocketError{reason: :einval})
    }
  }

  @doc = """
    Connects a UDP datagram socket to `address` (an `:ip4` endpoint) — sets a
    DEFAULT peer so the kernel filters inbound datagrams to it and `send`/`recv`
    (no explicit address) address it. Returns `Result.Ok(socket)` or
    `Result.Error(%SocketError{...})`. Unlike a stream connect this completes
    immediately (a datagram has no handshake). A non-`:ip4` address returns
    `:einval`.

    ## Examples

        SocketDatagram.connect(SocketAddress.ip4(127, 0, 0, 1, 9000))
    """

  @available_on(:network)

  pub fn connect(address :: SocketAddress) -> Result(SocketDatagram, SocketError) {
    case address.family {
      :ip4 -> SocketDatagram.result_from_handle(:zig.SocketRuntime.connect_udp(address.a, address.b, address.c, address.d, address.port))
      _ -> Result(SocketDatagram, SocketError).Error(%SocketError{reason: :einval})
    }
  }

  @doc = """
    Turns a runtime handle-bits result into a `Result(SocketDatagram,
    SocketError)`: `0` → the typed last-error, else `Ok`. The error reason is
    read immediately after the failed op (a non-yielding per-process slot).
    Shared by `bind`/`connect` (an unsupported family never reaches here — those
    arms return `:einval` directly).
    """

  @available_on(:network)

  fn result_from_handle(raw :: u64) -> Result(SocketDatagram, SocketError) {
    case raw {
      0 -> Result(SocketDatagram, SocketError).Error(SocketError.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(SocketDatagram, SocketError).Ok(%SocketDatagram{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Sends `bytes` as ONE datagram to `address`, with NO deadline. Identical to
    `send_to/4` with a `0` timeout.

    ## Examples

        SocketDatagram.send_to(socket, SocketAddress.loopback(9000), "ping")
    """

  @available_on(:network)

  pub fn send_to(datagram :: SocketDatagram, address :: SocketAddress, bytes :: String) -> Result(i64, SocketError) {
    SocketDatagram.send_to(datagram, address, bytes, 0)
  }

  @doc = """
    Sends `bytes` as ONE datagram to `address`, waiting at most `timeout_ms`
    milliseconds for the socket to become writable (`0` = no deadline). A
    datagram is ATOMIC — delivered whole or not at all — so on success the whole
    payload is sent (`Result.Ok(String.length(bytes))`); an oversize payload
    fails with `:einval` (`EMSGSIZE`), never a partial. Binary-safe. Dispatches
    on `address.family` (`:ip4` UDP or `:unix` Unix datagram); a non-`:ip4`/
    `:unix` address returns `:einval`. Panics on a stale handle.

    ## Examples

        SocketDatagram.send_to(socket, SocketAddress.loopback(9000), payload, 5000)
    """

  @available_on(:network)

  pub fn send_to(datagram :: SocketDatagram, address :: SocketAddress, bytes :: String, timeout_ms :: i64) -> Result(i64, SocketError) {
    total = String.length(bytes)
    case address.family {
      :ip4 -> SocketDatagram.classify_send(:zig.SocketRuntime.send_to_ip4(datagram.zap_socket_handle, address.a, address.b, address.c, address.d, address.port, bytes, timeout_ms), total)
      :unix -> SocketDatagram.classify_send(:zig.SocketRuntime.send_to_unix(datagram.zap_socket_handle, address.path, bytes, timeout_ms), total)
      _ -> Result(i64, SocketError).Error(%SocketError{reason: :einval})
    }
  }

  @doc = """
    Sends `bytes` on a CONNECTED datagram socket (its peer fixed by `connect`),
    waiting at most `timeout_ms` (`0` = no deadline). One atomic datagram to the
    connected peer. Returns `Result.Ok(String.length(bytes))` on success or a
    typed error. Panics on a stale handle.

    ## Examples

        SocketDatagram.send(connected, "ping", 5000)
    """

  @available_on(:network)

  pub fn send(datagram :: SocketDatagram, bytes :: String, timeout_ms :: i64) -> Result(i64, SocketError) {
    total = String.length(bytes)
    sent = :zig.SocketRuntime.send(datagram.zap_socket_handle, bytes, timeout_ms)
    SocketDatagram.classify_send(sent, total)
  }

  @doc = """
    Classifies a datagram send's byte count against the payload length: the full
    payload committed → `Ok`; else the typed last-error reason with the bytes
    that committed (`0` for a datagram). The error reason is read immediately
    after the failed send (a non-yielding per-process slot).
    """

  @available_on(:network)

  fn classify_send(sent :: i64, total :: i64) -> Result(i64, SocketError) {
    case sent == total {
      true -> Result(i64, SocketError).Ok(sent)
      false -> Result(i64, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(:zig.SocketRuntime.last_error()), bytes_sent: sent})
    }
  }

  @doc = """
    Receives ONE datagram (blocking until one arrives or `timeout_ms` elapses),
    returning the truncation-safe `SocketDatagramRecv` union. `max_bytes` caps
    the receive buffer (clamped by the runtime to the 64 KiB datagram maximum;
    `0` or less uses that maximum). On success a `Datagram(data)` (or
    `Truncated(data)` when the datagram exceeded `max_bytes`) carries the bytes,
    the SENDER's `SocketAddress`, and the datagram's true size; an idle timeout
    yields `TimedOut` (the socket stays OPEN — Decision E); a failure yields
    `Failed(error)`. Parks the fiber off its core gate-ON, blocks the single OS
    thread gate-OFF. Panics on a stale handle.

    ## Examples

        case SocketDatagram.recv_from(socket, 65536, 5000) {
          SocketDatagramRecv.Datagram(d)  -> handle(d.data, d.peer)
          SocketDatagramRecv.Truncated(d) -> handle_partial(d.data, d.datagram_size)
          SocketDatagramRecv.TimedOut     -> :idle
          SocketDatagramRecv.Failed(_e)   -> :error
        }
    """

  @available_on(:network)

  pub fn recv_from(datagram :: SocketDatagram, max_bytes :: i64, timeout_ms :: i64) -> SocketDatagramRecv {
    bytes = :zig.SocketRuntime.recv_from(datagram.zap_socket_handle, max_bytes, timeout_ms)
    SocketDatagram.decode_recv(bytes)
  }

  @doc = """
    Receives ONE datagram on a CONNECTED datagram socket (from its fixed peer),
    identical to `recv_from/3` — the connected-mode receive. The kernel already
    filtered to the connected peer, so `data.peer` is that peer.

    ## Examples

        SocketDatagram.recv(connected, 65536, 5000)
    """

  @available_on(:network)

  pub fn recv(datagram :: SocketDatagram, max_bytes :: i64, timeout_ms :: i64) -> SocketDatagramRecv {
    SocketDatagram.recv_from(datagram, max_bytes, timeout_ms)
  }

  @doc = """
    Reads the recv metadata slots (status, truncation flag, datagram length, and
    the sender endpoint) IMMEDIATELY after a `recv_from` and decodes them, with
    `bytes`, into the `SocketDatagramRecv` union via
    `SocketDatagramRecvDecoder.decode` — the single decode point. The reads are
    paired with the receive (a non-yielding per-process slot), so no other op
    can interpose.
    """

  @available_on(:network)

  fn decode_recv(bytes :: String) -> SocketDatagramRecv {
    status = :zig.SocketRuntime.recv_status()
    truncated = :zig.SocketRuntime.recv_truncated()
    datagram_size = :zig.SocketRuntime.recv_datagram_len()
    peer = SocketDatagram.recv_peer_address()
    SocketDatagramRecvDecoder.decode(status, truncated, bytes, peer, datagram_size)
  }

  @doc = """
    Reconstructs the SENDER's `SocketAddress` from the recv-peer accessor slots
    (the datagram-peer twin of `Socket.local_address`'s decode): the packed v4
    fast path, else the four v6 words (`-1` first word = `:unavailable`). A
    Unix-domain sender surfaces `:unavailable` in S2 (the path is not carried
    across the peer channel — a documented follow-up).
    """

  @available_on(:network)

  fn recv_peer_address() -> SocketAddress {
    packed = :zig.SocketRuntime.recv_peer()
    case packed < 0 {
      false -> SocketAddress.from_packed(packed)
      true ->
        {
          word0 = :zig.SocketRuntime.recv_peer_v6_word(0)
          case word0 < 0 {
            true -> %SocketAddress{family: :unavailable}
            false ->
              {
                word1 = :zig.SocketRuntime.recv_peer_v6_word(1)
                word2 = :zig.SocketRuntime.recv_peer_v6_word(2)
                word3 = :zig.SocketRuntime.recv_peer_v6_word(3)
                scope_id = :zig.SocketRuntime.recv_peer_scope()
                port = :zig.SocketRuntime.recv_peer_port()
                SocketAddress.ip6_from_words(word0, word1, word2, word3, scope_id, port)
              }
          }
        }
    }
  }

  @doc = """
    Returns the LOCAL (bound) `SocketAddress` of the datagram socket via
    `getsockname`. Panics on a stale handle.

    ## Examples

        SocketDatagram.local_address(socket)
    """

  @available_on(:network)

  pub fn local_address(datagram :: SocketDatagram) -> SocketAddress {
    SocketAddress.from_packed(:zig.SocketRuntime.endpoint(datagram.zap_socket_handle, 0))
  }

  @doc = """
    Returns the LOCAL port of a UDP datagram socket via `getsockname` — the
    ephemeral port a `bind(_, 0)` was assigned, or the ephemeral SOURCE port the
    OS auto-assigned to a `connect`ed datagram socket (a thin read of
    `local_address(socket).port`, so it is correct for BOTH bound and connected
    sockets, unlike the domain-slot bound port which is `0` for a connected
    socket). Panics on a stale handle. `0` for a Unix datagram socket (no port).

    ## Examples

        SocketDatagram.local_port(socket)
    """

  @available_on(:network)

  pub fn local_port(datagram :: SocketDatagram) -> i64 {
    local = SocketDatagram.local_address(datagram)
    local.port
  }

  @doc = """
    Returns the REMOTE (connected peer) `SocketAddress` of a CONNECTED datagram
    socket via `getpeername`, or `:unavailable` for an unconnected socket. Panics
    on a stale handle.

    ## Examples

        SocketDatagram.peer_address(connected)
    """

  @available_on(:network)

  pub fn peer_address(datagram :: SocketDatagram) -> SocketAddress {
    SocketAddress.from_packed(:zig.SocketRuntime.endpoint(datagram.zap_socket_handle, 1))
  }

  @doc = """
    Closes the datagram socket: recycles its domain slot (every outstanding copy
    of the handle goes stale) and closes the fd. Optional for short-lived
    programs — the runtime closes still-owned fds at exit and on crash. Panics on
    a closed or stale handle (use-after-close), never corrupting memory.

    ## Examples

        SocketDatagram.close(socket)
    """

  @available_on(:network)

  pub fn close(datagram :: SocketDatagram) -> Bool {
    :zig.SocketRuntime.close(datagram.zap_socket_handle)
  }

  @doc = """
    Returns `true` while the datagram socket is still open and owned by this
    program, `false` once closed. Never panics.

    ## Examples

        SocketDatagram.open?(socket)
    """

  @available_on(:network)

  pub fn open?(datagram :: SocketDatagram) -> Bool {
    :zig.SocketRuntime.is_live(datagram.zap_socket_handle)
  }
}

@doc = """
  `SocketDatagramData` — the payload of a received datagram (Phase S2): the
  `data` bytes (binary-safe, embedded NULs survive), the SENDER's `peer`
  `SocketAddress`, and the datagram's true `datagram_size` (exact on Linux; the
  captured floor on macOS). Carried by both the `SocketDatagramRecv.Datagram`
  and `SocketDatagramRecv.Truncated` variants — on `Truncated`, `data` is the
  captured PREFIX and `datagram_size` reports how much was actually sent, so the
  loss is quantified, never silent.
  """

@available_on(:network)

pub struct SocketDatagramData {
  data :: String
  peer :: SocketAddress
  datagram_size :: i64
}

@doc = """
  `SocketDatagramRecv` — the truncation-safe result of a `SocketDatagram`
  receive (Phase S2), the datagram analogue of the stream `SocketRecv`.

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
  * `Failed(error)` — the receive failed (a typed `SocketError`).

  ## Examples

      case SocketDatagram.recv_from(socket, 1024, 5000) {
        SocketDatagramRecv.Datagram(d)  -> use(d.data)
        SocketDatagramRecv.Truncated(d) -> log_oversize(d.datagram_size)
        SocketDatagramRecv.TimedOut     -> :idle
        SocketDatagramRecv.Failed(_e)   -> :error
      }
  """

@available_on(:network)

pub union SocketDatagramRecv {
  Datagram :: SocketDatagramData
  Truncated :: SocketDatagramData
  TimedOut
  Failed :: SocketError
}

@doc = """
  `SocketDatagramRecvDecoder` — the ONE shared decode core that turns a runtime
  `recv_from` status (+ truncation flag, bytes, peer, datagram size) into the
  `SocketDatagramRecv` union.

  A stateless namespace (no fields), the single point every datagram receive form
  (`recv_from`, connected `recv`) routes its status → variant mapping through, so
  the mapping lives in ONE place and cannot drift between forms. This is the
  datagram twin of `SocketRecvDecoder`, on its own struct so the receive forms
  call it without a mutual struct cycle.

  ## Examples

      SocketDatagramRecvDecoder.decode(0, 0, "hi", peer, 2)   # => Datagram
      SocketDatagramRecvDecoder.decode(0, 1, "hi", peer, 100) # => Truncated
  """

@available_on(:network)

pub struct SocketDatagramRecvDecoder {
  @doc = """
    Decodes a `recv_from` result into the `SocketDatagramRecv` union: `status 0`
    = a datagram (`truncated 1` → `Truncated`, else `Datagram`, both carrying a
    `SocketDatagramData` of `bytes`/`peer`/`datagram_size`); `status 2` = an idle
    `TimedOut` (the socket stays open); any other positive `status` = a `Failed`
    reason. There is NO `Closed` (datagrams have no EOF). A plain Bool cascade
    (no integer-literal `case` arm).

    ## Examples

        SocketDatagramRecvDecoder.decode(2, 0, "", peer, 0)   # => TimedOut
    """

  @available_on(:network)

  pub fn decode(status :: i64, truncated :: i64, bytes :: String, peer :: SocketAddress, datagram_size :: i64) -> SocketDatagramRecv {
    case status == 0 {
      true ->
        {
          data = %SocketDatagramData{data: bytes, peer: peer, datagram_size: datagram_size}
          case truncated == 1 {
            true -> SocketDatagramRecv.Truncated(data)
            false -> SocketDatagramRecv.Datagram(data)
          }
        }
      false ->
        case status == 2 {
          true -> SocketDatagramRecv.TimedOut
          false -> SocketDatagramRecv.Failed(SocketError.from_code(status))
        }
    }
  }
}
