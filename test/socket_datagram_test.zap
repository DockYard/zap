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
  #     `Socket.Address` (listen/connect/accept/send/recv);
  #   * a Unix-domain DATAGRAM roundtrip works through `Socket.Datagram`;
  #   * everything is leak-exact against `Socket.live_count`.
  #
  # The gate-ON twins live in `test_concurrency/socket_datagram_test.zap`.

  # ---- a run-unique Unix socket path (ephemeral-port suffix) ---------------

  fn unique_unix_path(prefix :: String) -> String {
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Ok(probe) ->
        {
          port = Socket.Datagram.local_port(probe)
          _ = Socket.Datagram.close(probe)
          "/tmp/" <> prefix <> "-" <> Integer.to_string(port) <> ".sock"
        }
      Result.Error(_e) -> "/tmp/" <> prefix <> "-x.sock"
    }
  }

  # ---- UDP loopback roundtrip (binary-safe, peer surfaced) -----------------

  fn udp_roundtrip() -> Atom {
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.udp_after_receiver(receiver)
    }
  }

  fn udp_after_receiver(receiver :: Socket.Datagram) -> Atom {
    port = Socket.Datagram.local_port(receiver)
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Error(_e) ->
        {
          _c = Socket.Datagram.close(receiver)
          :bind_failed
        }
      Result.Ok(sender) -> SocketDatagramTest.udp_exchange(receiver, sender, port)
    }
  }

  fn udp_exchange(receiver :: Socket.Datagram, sender :: Socket.Datagram, port :: i64) -> Atom {
    payload = "dg\x00\xfem"
    _sent = Socket.Datagram.send_to(sender, Socket.Address.loopback(port), payload)
    result = case Socket.Datagram.recv_from(receiver, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) ->
        case d.data == payload {
          true -> case d.peer.family == :ip4 {
            true -> :ok
            false -> :peer_wrong
          }
          false -> :mismatch
        }
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :unexpected_timeout
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.Datagram.close(sender)
    _c2 = Socket.Datagram.close(receiver)
    result
  }

  # ---- UDP truncation surfaces the Truncated variant + prefix + size -------

  fn udp_truncation() -> Atom {
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.truncation_after_receiver(receiver)
    }
  }

  fn truncation_after_receiver(receiver :: Socket.Datagram) -> Atom {
    port = Socket.Datagram.local_port(receiver)
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Error(_e) ->
        {
          _c = Socket.Datagram.close(receiver)
          :bind_failed
        }
      Result.Ok(sender) -> SocketDatagramTest.truncation_exchange(receiver, sender, port)
    }
  }

  fn truncation_exchange(receiver :: Socket.Datagram, sender :: Socket.Datagram, port :: i64) -> Atom {
    # A 100-byte datagram whose first 10 bytes are a known prefix.
    payload = "ABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJ"
    _sent = Socket.Datagram.send_to(sender, Socket.Address.loopback(port), payload)
    # Receive with a 10-byte cap: the datagram MUST be reported truncated with
    # the 10-byte prefix and a true size at least the captured length.
    result = case Socket.Datagram.recv_from(receiver, 10, 5000) {
      Socket.DatagramRecv.Truncated(d) ->
        case d.data == "ABCDEFGHIJ" {
          true -> case d.datagram_size >= 10 {
            true -> :ok
            false -> :size_wrong
          }
          false -> :prefix_wrong
        }
      Socket.DatagramRecv.Datagram(_d) -> :not_truncated
      Socket.DatagramRecv.TimedOut -> :unexpected_timeout
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.Datagram.close(sender)
    _c2 = Socket.Datagram.close(receiver)
    result
  }

  # ---- connected UDP filters to the connected peer -------------------------

  fn connected_udp() -> Atom {
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(peer) -> SocketDatagramTest.connected_after_peer(peer)
    }
  }

  fn connected_after_peer(peer :: Socket.Datagram) -> Atom {
    peer_port = Socket.Datagram.local_port(peer)
    case Socket.Datagram.connect(Socket.Address.ip4(127, 0, 0, 1, peer_port)) {
      Result.Error(_e) ->
        {
          _c = Socket.Datagram.close(peer)
          :connect_failed
        }
      Result.Ok(connected) -> SocketDatagramTest.connected_filter(peer, connected)
    }
  }

  fn connected_filter(peer :: Socket.Datagram, connected :: Socket.Datagram) -> Atom {
    connected_port = Socket.Datagram.local_port(connected)
    filtered = SocketDatagramTest.impostor_dropped(connected_port, connected)
    # The real peer's datagram IS delivered (connected to the peer).
    _sent = Socket.Datagram.send_to(peer, Socket.Address.loopback(connected_port), "from-peer")
    delivered = case Socket.Datagram.recv(connected, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) ->
        case d.data == "from-peer" {
          true -> :ok
          false -> :mismatch
        }
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :not_delivered
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.Datagram.close(connected)
    _c2 = Socket.Datagram.close(peer)
    case filtered == :filtered {
      true -> delivered
      false -> filtered
    }
  }

  fn impostor_dropped(connected_port :: i64, connected :: Socket.Datagram) -> Atom {
    case Socket.Datagram.bind(Socket.Address.loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(third) ->
        {
          _sent = Socket.Datagram.send_to(third, Socket.Address.loopback(connected_port), "impostor")
          # The connected socket is connected to `peer`, so the impostor's
          # datagram (a different source) is DROPPED by the kernel → recv times
          # out (nothing to deliver).
          result = case Socket.Datagram.recv(connected, 65536, 200) {
            Socket.DatagramRecv.TimedOut -> :filtered
            Socket.DatagramRecv.Datagram(_d) -> :leaked
            Socket.DatagramRecv.Truncated(_d) -> :leaked
            Socket.DatagramRecv.Failed(_e) -> :recv_failed
          }
          _c = Socket.Datagram.close(third)
          result
        }
    }
  }

  # ---- Unix-domain STREAM echo via Socket + :unix address ------------------

  fn unix_stream_echo() -> Atom {
    path = SocketDatagramTest.unique_unix_path("zap-s2-stream-goff")
    _rm = File.rm(path)
    case Socket.listen(Socket.Address.unix(path), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketDatagramTest.unix_after_listen(listener, path)
    }
  }

  fn unix_after_listen(listener :: Socket.Listener, path :: String) -> Atom {
    result = case Socket.connect(Socket.Address.unix(path), 5000) {
      Result.Error(_e) -> :connect_failed
      Result.Ok(client) -> SocketDatagramTest.unix_after_connect(listener, client)
    }
    _rm = File.rm(path)
    result
  }

  fn unix_after_connect(listener :: Socket.Listener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketDatagramTest.unix_echo_exchange(listener, client, server)
    }
  }

  fn unix_echo_exchange(listener :: Socket.Listener, client :: Socket, server :: Socket) -> Atom {
    payload = "ux\x00\xffz"
    _sent = Socket.send(client, payload)
    forward = case Socket.recv(server, String.length(payload), 5000) {
      Socket.Recv.Chunk(bytes) ->
        case bytes == payload {
          true -> :ok
          false -> :mismatch
        }
      Socket.Recv.TimedOut(_p) -> :unexpected_timeout
      Socket.Recv.Closed -> :unexpected_eof
      Socket.Recv.Failed(_e) -> :recv_failed
    }
    _reply = Socket.send(server, "ok")
    backward = case Socket.recv(client, 0, 5000) {
      Socket.Recv.Chunk(bytes) ->
        case bytes == "ok" {
          true -> :ok
          false -> :mismatch
        }
      Socket.Recv.TimedOut(_p) -> :unexpected_timeout
      Socket.Recv.Closed -> :unexpected_eof
      Socket.Recv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = Socket.Listener.close(listener)
    case forward == :ok {
      true -> backward
      false -> forward
    }
  }

  # ---- Unix-domain DATAGRAM roundtrip --------------------------------------

  fn unix_dgram_roundtrip() -> Atom {
    receiver_path = SocketDatagramTest.unique_unix_path("zap-s2-dgram-goff")
    _rm = File.rm(receiver_path)
    case Socket.Datagram.bind(Socket.Address.unix(receiver_path)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.unix_dgram_after_bind(receiver, receiver_path)
    }
  }

  fn unix_dgram_after_bind(receiver :: Socket.Datagram, receiver_path :: String) -> Atom {
    sender_path = SocketDatagramTest.unique_unix_path("zap-s2-dgtx-goff")
    _rm = File.rm(sender_path)
    result = case Socket.Datagram.bind(Socket.Address.unix(sender_path)) {
      Result.Error(_e) -> :sender_bind_failed
      Result.Ok(sender) -> SocketDatagramTest.unix_dgram_exchange(receiver, sender, receiver_path)
    }
    _c = Socket.Datagram.close(receiver)
    _r1 = File.rm(receiver_path)
    _r2 = File.rm(sender_path)
    result
  }

  fn unix_dgram_exchange(receiver :: Socket.Datagram, sender :: Socket.Datagram, receiver_path :: String) -> Atom {
    payload = "ud\x00\x01g"
    _sent = Socket.Datagram.send_to(sender, Socket.Address.unix(receiver_path), payload)
    result = case Socket.Datagram.recv_from(receiver, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) ->
        case d.data == payload {
          true -> :ok
          false -> :mismatch
        }
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :unexpected_timeout
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c = Socket.Datagram.close(sender)
    result
  }

  # ---- IPv6 UDP loopback roundtrip (::1), peer surfaced as :ip6 ------------

  fn udp6_roundtrip() -> Atom {
    case Socket.Datagram.bind(Socket.Address.ip6_loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(receiver) -> SocketDatagramTest.udp6_after_receiver(receiver)
    }
  }

  fn udp6_after_receiver(receiver :: Socket.Datagram) -> Atom {
    port = Socket.Datagram.local_port(receiver)
    case Socket.Datagram.bind(Socket.Address.ip6_loopback(0)) {
      Result.Error(_e) ->
        {
          _c = Socket.Datagram.close(receiver)
          :sender_bind_failed
        }
      Result.Ok(sender) -> SocketDatagramTest.udp6_exchange(receiver, sender, port)
    }
  }

  fn udp6_exchange(receiver :: Socket.Datagram, sender :: Socket.Datagram, port :: i64) -> Atom {
    payload = "v6\x00\xfed"
    _sent = Socket.Datagram.send_to(sender, Socket.Address.ip6_loopback(port), payload)
    result = case Socket.Datagram.recv_from(receiver, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) -> SocketDatagramTest.check_v6_peer(d, payload)
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :unexpected_timeout
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.Datagram.close(sender)
    _c2 = Socket.Datagram.close(receiver)
    result
  }

  fn check_v6_peer(d :: Socket.DatagramData, payload :: String) -> Atom {
    case d.data == payload {
      false -> :mismatch
      true ->
        case d.peer.family == :ip6 {
          false -> :peer_wrong
          # ::1 → h0..h6 are 0 and h7 is 1.
          true ->
            case d.peer.h0 == 0 {
              false -> :peer_addr_wrong
              true ->
                case d.peer.h7 == 1 {
                  true -> :ok
                  false -> :peer_addr_wrong
                }
            }
        }
    }
  }

  # ---- connected IPv6 UDP filters to the connected v6 peer -----------------

  fn connected_udp6() -> Atom {
    case Socket.Datagram.bind(Socket.Address.ip6_loopback(0)) {
      Result.Error(_e) -> :bind_failed
      Result.Ok(peer) -> SocketDatagramTest.connected6_after_peer(peer)
    }
  }

  fn connected6_after_peer(peer :: Socket.Datagram) -> Atom {
    peer_port = Socket.Datagram.local_port(peer)
    case Socket.Datagram.connect(Socket.Address.ip6(0, 0, 0, 0, 0, 0, 0, 1, 0, peer_port)) {
      Result.Error(_e) ->
        {
          _c = Socket.Datagram.close(peer)
          :connect_failed
        }
      Result.Ok(connected) -> SocketDatagramTest.connected6_exchange(peer, connected)
    }
  }

  fn connected6_exchange(peer :: Socket.Datagram, connected :: Socket.Datagram) -> Atom {
    connected_port = Socket.Datagram.local_port(connected)
    _sent = Socket.Datagram.send_to(peer, Socket.Address.ip6_loopback(connected_port), "v6-peer")
    delivered = case Socket.Datagram.recv(connected, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) ->
        case d.data == "v6-peer" {
          true -> :ok
          false -> :mismatch
        }
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :not_delivered
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.Datagram.close(connected)
    _c2 = Socket.Datagram.close(peer)
    delivered
  }

  # ---- Unix DATAGRAM reply-to-sender: recv_from surfaces the sender PATH ----

  fn unix_dgram_reply() -> Atom {
    server_path = SocketDatagramTest.unique_unix_path("zap-s2-reply-srv")
    _rm = File.rm(server_path)
    case Socket.Datagram.bind(Socket.Address.unix(server_path)) {
      Result.Error(_e) -> :server_bind_failed
      Result.Ok(server) -> SocketDatagramTest.reply_after_server(server, server_path)
    }
  }

  fn reply_after_server(server :: Socket.Datagram, server_path :: String) -> Atom {
    client_path = SocketDatagramTest.unique_unix_path("zap-s2-reply-cli")
    _rm = File.rm(client_path)
    result = case Socket.Datagram.bind(Socket.Address.unix(client_path)) {
      Result.Error(_e) -> :client_bind_failed
      Result.Ok(client) -> SocketDatagramTest.reply_exchange(server, client, server_path, client_path)
    }
    _c = Socket.Datagram.close(server)
    _r1 = File.rm(server_path)
    _r2 = File.rm(client_path)
    result
  }

  fn reply_exchange(server :: Socket.Datagram, client :: Socket.Datagram, server_path :: String, client_path :: String) -> Atom {
    _sent = Socket.Datagram.send_to(client, Socket.Address.unix(server_path), "ping")
    result = case Socket.Datagram.recv_from(server, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) -> SocketDatagramTest.reply_to_peer(server, d, client, client_path)
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :unexpected_timeout
      Socket.DatagramRecv.Failed(_e) -> :recv_failed
    }
    _c = Socket.Datagram.close(client)
    result
  }

  fn reply_to_peer(server :: Socket.Datagram, d :: Socket.DatagramData, client :: Socket.Datagram, client_path :: String) -> Atom {
    case d.peer.family == :unix {
      false -> :peer_not_unix
      true ->
        case d.peer.path == client_path {
          false -> :peer_path_wrong
          # Reply STRAIGHT BACK to the sender's surfaced path.
          true -> SocketDatagramTest.deliver_reply(server, d.peer, client)
        }
    }
  }

  fn deliver_reply(server :: Socket.Datagram, peer :: Socket.Address, client :: Socket.Datagram) -> Atom {
    _sent = Socket.Datagram.send_to(server, peer, "pong")
    case Socket.Datagram.recv_from(client, 65536, 5000) {
      Socket.DatagramRecv.Datagram(d) ->
        case d.data == "pong" {
          true -> :ok
          false -> :reply_mismatch
        }
      Socket.DatagramRecv.Truncated(_d) -> :unexpected_truncated
      Socket.DatagramRecv.TimedOut -> :reply_not_delivered
      Socket.DatagramRecv.Failed(_e) -> :reply_failed
    }
  }

  # ---- Unix STREAM local/peer address surface the bound PATH ----------------

  fn unix_stream_paths() -> Atom {
    path = SocketDatagramTest.unique_unix_path("zap-s2-spath")
    _rm = File.rm(path)
    case Socket.listen(Socket.Address.unix(path), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketDatagramTest.spath_after_listen(listener, path)
    }
  }

  fn spath_after_listen(listener :: Socket.Listener, path :: String) -> Atom {
    result = case Socket.connect(Socket.Address.unix(path), 5000) {
      Result.Error(_e) -> :connect_failed
      Result.Ok(client) -> SocketDatagramTest.spath_after_connect(listener, client, path)
    }
    _rm = File.rm(path)
    result
  }

  fn spath_after_connect(listener :: Socket.Listener, client :: Socket, path :: String) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketDatagramTest.spath_check(listener, client, server, path)
    }
  }

  fn spath_check(listener :: Socket.Listener, client :: Socket, server :: Socket, path :: String) -> Atom {
    # The client's PEER (getpeername) is the server's listen path; the accepted
    # server's LOCAL (getsockname) is that same bound listen path.
    client_peer = Socket.peer_address(client)
    server_local = Socket.local_address(server)
    result = SocketDatagramTest.spath_verdict(client_peer, server_local, path)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = Socket.Listener.close(listener)
    result
  }

  fn spath_verdict(client_peer :: Socket.Address, server_local :: Socket.Address, path :: String) -> Atom {
    case client_peer.family == :unix {
      false -> :client_peer_not_unix
      true ->
        case client_peer.path == path {
          false -> :client_peer_path_wrong
          true ->
            case server_local.family == :unix {
              false -> :server_local_not_unix
              true ->
                case server_local.path == path {
                  true -> :ok
                  false -> :server_local_path_wrong
                }
            }
        }
    }
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

    test("IPv6 UDP loopback (::1) roundtrip surfaces a :ip6 peer, leak-exact") {
      base = Socket.live_count()
      assert(SocketDatagramTest.udp6_roundtrip() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a connected IPv6 UDP socket delivers its connected v6 peer, leak-exact") {
      base = Socket.live_count()
      assert(SocketDatagramTest.connected_udp6() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a Unix datagram server recv_from surfaces the sender PATH and can reply to it") {
      base = Socket.live_count()
      assert(SocketDatagramTest.unix_dgram_reply() == :ok)
      assert(Socket.live_count() == base)
    }

    test("Unix stream local/peer_address surface the bound PATH") {
      base = Socket.live_count()
      assert(SocketDatagramTest.unix_stream_paths() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
