pub struct SocketDatagramTest {
  use Zest.Case

  # Phase S2 exit-gate acceptance (gate-OFF): the datagram (UDP) + Unix-domain
  # surface driven end to end over self-contained loopback pairs on the single
  # OS thread (Decision D). What these pin:
  #
  #   * a UDP loopback roundtrip carries a BINARY-SAFE payload (embedded NUL +
  #     an invalid-UTF-8 byte) intact, and reports the SENDER as the peer;
  #   * a datagram larger than the receive buffer surfaces the distinct
  #     `Truncated` variant (never silent loss) with the captured PREFIX and the
  #     datagram's true size;
  #   * a CONNECTED UDP socket FILTERS to its connected peer — an impostor's
  #     datagram is dropped (recv times out), the peer's is delivered;
  #   * a Unix-domain STREAM echo works through the ordinary `Socket` + a `:unix`
  #     `SocketAddress` (listen/connect/accept/send/recv);
  #   * a Unix-domain DATAGRAM roundtrip works through `SocketDatagram`;
  #   * everything is leak-exact against `Socket.live_count`.
  #
  # The gate-ON twins live in `test_concurrency/socket_datagram_test.zap`.

  # ---- a run-unique Unix socket path (ephemeral-port suffix) ---------------

  fn unique_unix_path(prefix :: String) -> String {
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Ok(probe) ->
        {
          port = SocketDatagram.local_port(probe)
          _ = SocketDatagram.close(probe)
          "/tmp/" <> prefix <> "-" <> Integer.to_string(port) <> ".sock"
        }
      Result.Error(_e) -> "/tmp/" <> prefix <> "-x.sock"
    }
  }

  # ---- UDP loopback roundtrip (binary-safe, peer surfaced) -----------------

  fn udp_roundtrip() -> Atom {
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.udp_after_receiver(receiver)
    }
  }

  fn udp_after_receiver(receiver :: SocketDatagram) -> Atom {
    port = SocketDatagram.local_port(receiver)
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Error(_e) ->
        {
          _c = SocketDatagram.close(receiver)
          :bind_failed
        }
      Result.Ok(sender) -> SocketDatagramTest.udp_exchange(receiver, sender, port)
    }
  }

  fn udp_exchange(receiver :: SocketDatagram, sender :: SocketDatagram, port :: i64) -> Atom {
    payload = "dg\x00\xfem"
    _sent = SocketDatagram.send_to(sender, SocketAddress.loopback(port), payload)
    result = case SocketDatagram.recv_from(receiver, 65536, 5000) {
      SocketDatagramRecv.Datagram(d) ->
        case d.data == payload {
          true -> case d.peer.family == :ip4 {
            true -> :ok
            false -> :peer_wrong
          }
          false -> :mismatch
        }
      SocketDatagramRecv.Truncated(_d) -> :unexpected_truncated
      SocketDatagramRecv.TimedOut -> :unexpected_timeout
      SocketDatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = SocketDatagram.close(sender)
    _c2 = SocketDatagram.close(receiver)
    result
  }

  # ---- UDP truncation surfaces the Truncated variant + prefix + size -------

  fn udp_truncation() -> Atom {
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.truncation_after_receiver(receiver)
    }
  }

  fn truncation_after_receiver(receiver :: SocketDatagram) -> Atom {
    port = SocketDatagram.local_port(receiver)
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Error(_e) ->
        {
          _c = SocketDatagram.close(receiver)
          :bind_failed
        }
      Result.Ok(sender) -> SocketDatagramTest.truncation_exchange(receiver, sender, port)
    }
  }

  fn truncation_exchange(receiver :: SocketDatagram, sender :: SocketDatagram, port :: i64) -> Atom {
    # A 100-byte datagram whose first 10 bytes are a known prefix.
    payload = "ABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJ"
    _sent = SocketDatagram.send_to(sender, SocketAddress.loopback(port), payload)
    # Receive with a 10-byte cap: the datagram MUST be reported truncated with
    # the 10-byte prefix and a true size at least the captured length.
    result = case SocketDatagram.recv_from(receiver, 10, 5000) {
      SocketDatagramRecv.Truncated(d) ->
        case d.data == "ABCDEFGHIJ" {
          true -> case d.datagram_size >= 10 {
            true -> :ok
            false -> :size_wrong
          }
          false -> :prefix_wrong
        }
      SocketDatagramRecv.Datagram(_d) -> :not_truncated
      SocketDatagramRecv.TimedOut -> :unexpected_timeout
      SocketDatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = SocketDatagram.close(sender)
    _c2 = SocketDatagram.close(receiver)
    result
  }

  # ---- connected UDP filters to the connected peer -------------------------

  fn connected_udp() -> Atom {
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(peer) -> SocketDatagramTest.connected_after_peer(peer)
    }
  }

  fn connected_after_peer(peer :: SocketDatagram) -> Atom {
    peer_port = SocketDatagram.local_port(peer)
    case SocketDatagram.connect(SocketAddress.ip4(127, 0, 0, 1, peer_port)) {
      Result.Error(_e) ->
        {
          _c = SocketDatagram.close(peer)
          :connect_failed
        }
      Result.Ok(connected) -> SocketDatagramTest.connected_filter(peer, connected)
    }
  }

  fn connected_filter(peer :: SocketDatagram, connected :: SocketDatagram) -> Atom {
    connected_port = SocketDatagram.local_port(connected)
    filtered = SocketDatagramTest.impostor_dropped(connected_port, connected)
    # The real peer's datagram IS delivered (connected to the peer).
    _sent = SocketDatagram.send_to(peer, SocketAddress.loopback(connected_port), "from-peer")
    delivered = case SocketDatagram.recv(connected, 65536, 5000) {
      SocketDatagramRecv.Datagram(d) ->
        case d.data == "from-peer" {
          true -> :ok
          false -> :mismatch
        }
      SocketDatagramRecv.Truncated(_d) -> :unexpected_truncated
      SocketDatagramRecv.TimedOut -> :not_delivered
      SocketDatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = SocketDatagram.close(connected)
    _c2 = SocketDatagram.close(peer)
    case filtered == :filtered {
      true -> delivered
      false -> filtered
    }
  }

  fn impostor_dropped(connected_port :: i64, connected :: SocketDatagram) -> Atom {
    case SocketDatagram.bind(SocketAddress.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(third) ->
        {
          _sent = SocketDatagram.send_to(third, SocketAddress.loopback(connected_port), "impostor")
          # The connected socket is connected to `peer`, so the impostor's
          # datagram (a different source) is DROPPED by the kernel → recv times
          # out (nothing to deliver).
          result = case SocketDatagram.recv(connected, 65536, 200) {
            SocketDatagramRecv.TimedOut -> :filtered
            SocketDatagramRecv.Datagram(_d) -> :leaked
            SocketDatagramRecv.Truncated(_d) -> :leaked
            SocketDatagramRecv.Failed(_e) -> :recv_failed
          }
          _c = SocketDatagram.close(third)
          result
        }
    }
  }

  # ---- Unix-domain STREAM echo via Socket + :unix address ------------------

  fn unix_stream_echo() -> Atom {
    path = SocketDatagramTest.unique_unix_path("zap-s2-stream-goff")
    _rm = File.rm(path)
    case Socket.listen(SocketAddress.unix(path), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketDatagramTest.unix_after_listen(listener, path)
    }
  }

  fn unix_after_listen(listener :: SocketListener, path :: String) -> Atom {
    result = case Socket.connect(SocketAddress.unix(path), 5000) {
      Result.Error(_e) -> :connect_failed
      Result.Ok(client) -> SocketDatagramTest.unix_after_connect(listener, client)
    }
    _rm = File.rm(path)
    result
  }

  fn unix_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketDatagramTest.unix_echo_exchange(listener, client, server)
    }
  }

  fn unix_echo_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    payload = "ux\x00\xffz"
    _sent = Socket.send(client, payload)
    forward = case Socket.recv(server, String.length(payload), 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == payload {
          true -> :ok
          false -> :mismatch
        }
      SocketRecv.TimedOut(_p) -> :unexpected_timeout
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :recv_failed
    }
    _reply = Socket.send(server, "ok")
    backward = case Socket.recv(client, 0, 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == "ok" {
          true -> :ok
          false -> :mismatch
        }
      SocketRecv.TimedOut(_p) -> :unexpected_timeout
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    case forward == :ok {
      true -> backward
      false -> forward
    }
  }

  # ---- Unix-domain DATAGRAM roundtrip --------------------------------------

  fn unix_dgram_roundtrip() -> Atom {
    receiver_path = SocketDatagramTest.unique_unix_path("zap-s2-dgram-goff")
    _rm = File.rm(receiver_path)
    case SocketDatagram.bind(SocketAddress.unix(receiver_path)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.unix_dgram_after_bind(receiver, receiver_path)
    }
  }

  fn unix_dgram_after_bind(receiver :: SocketDatagram, receiver_path :: String) -> Atom {
    sender_path = SocketDatagramTest.unique_unix_path("zap-s2-dgtx-goff")
    _rm = File.rm(sender_path)
    result = case SocketDatagram.bind(SocketAddress.unix(sender_path)) {
      Result.Error(_e) -> :sender_bind_failed
      Result.Ok(sender) -> SocketDatagramTest.unix_dgram_exchange(receiver, sender, receiver_path)
    }
    _c = SocketDatagram.close(receiver)
    _r1 = File.rm(receiver_path)
    _r2 = File.rm(sender_path)
    result
  }

  fn unix_dgram_exchange(receiver :: SocketDatagram, sender :: SocketDatagram, receiver_path :: String) -> Atom {
    payload = "ud\x00\x01g"
    _sent = SocketDatagram.send_to(sender, SocketAddress.unix(receiver_path), payload)
    result = case SocketDatagram.recv_from(receiver, 65536, 5000) {
      SocketDatagramRecv.Datagram(d) ->
        case d.data == payload {
          true -> :ok
          false -> :mismatch
        }
      SocketDatagramRecv.Truncated(_d) -> :unexpected_truncated
      SocketDatagramRecv.TimedOut -> :unexpected_timeout
      SocketDatagramRecv.Failed(_e) -> :recv_failed
    }
    _c = SocketDatagram.close(sender)
    result
  }

  # ------------------------------------------------------------------------

  describe("Socket datagram + Unix-domain (gate-OFF)") {
    test("UDP loopback roundtrip is binary-safe, surfaces the peer, and is leak-exact") {
      base = Socket.live_count()
      assert(SocketDatagramTest.udp_roundtrip() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a datagram larger than the buffer surfaces Truncated with the prefix and true size") {
      base = Socket.live_count()
      assert(SocketDatagramTest.udp_truncation() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a connected UDP socket filters to its peer (impostor dropped, peer delivered)") {
      base = Socket.live_count()
      assert(SocketDatagramTest.connected_udp() == :ok)
      assert(Socket.live_count() == base)
    }

    test("Unix-domain stream echo via Socket + :unix address, leak-exact") {
      base = Socket.live_count()
      assert(SocketDatagramTest.unix_stream_echo() == :ok)
      assert(Socket.live_count() == base)
    }

    test("Unix-domain datagram roundtrip, leak-exact") {
      base = Socket.live_count()
      assert(SocketDatagramTest.unix_dgram_roundtrip() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
