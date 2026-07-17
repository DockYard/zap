pub struct SocketTest {
  use Zest.Case

  # Phase S0 acceptance proof (gate-OFF): the socket layer's foundation —
  # the fourth kernel-owned allocation domain behind a single-owner,
  # move-only, generation-validated handle — driven end to end at the Zap
  # surface WITHOUT the concurrency kernel (Decision D: a plain script gets
  # sockets too, offloading inline on the single OS thread). What these pin:
  #
  #   * `listen(_, 0)` binds an ephemeral port discoverable via `local_port`;
  #   * a loopback `connect` succeeds (the connection completes in the
  #     kernel's accept queue with no `accept` — the S0 minimal listener);
  #   * `close` recycles the domain slot so `open?` flips true → false and
  #     the handle goes stale (a later close would panic — the stale-handle
  #     discipline; the panic path is exercised by the smoke/zir suites);
  #   * every open/close is leak-exact against `Socket.live_count`;
  #   * a failed connect surfaces a typed `SocketError`, not a crash.
  #
  # The gate-ON twins (blocking-pool offload + drop-list fd reclaim on
  # process exit AND kill) live in `test_concurrency/socket_test.zap`.

  describe("Socket loopback and lifetime (gate-OFF)") {
    test("listen/connect/close round-trips, flips open? true→false, and is leak-exact") {
      base = Socket.live_count()
      outcome = SocketTest.run_loopback()
      assert(outcome == :ok)
      assert(Socket.live_count() == base)
    }

    test("local_port reports a nonzero ephemeral port for a listener") {
      case Socket.listen(SocketAddress.loopback(0), 8) {
        Result.Ok(listener) ->
          {
            port = SocketListener.local_port(listener)
            _closed = SocketListener.close(listener)
            assert(port > 0)
          }
        Result.Error(_e) ->
          {
            assert(false)
          }
      }
    }

    test("connect to a closed port yields a typed SocketError (not a crash)") {
      case Socket.listen(SocketAddress.loopback(0), 1) {
        Result.Ok(listener) ->
          {
            port = SocketListener.local_port(listener)
            _closed = SocketListener.close(listener)
            # The port is now bound to nothing; a connect must return a
            # typed `Result.Error(SocketError)`, never an `Ok` or a crash.
            assert(SocketTest.connect_refused?(port))
          }
        Result.Error(_e) ->
          {
            assert(false)
          }
      }
    }
  }

  describe("Socket.connect_host / Happy Eyeballs (gate-OFF)") {
    test("connect_host resolves localhost and connects to a live loopback listener, leak-exact") {
      base = Socket.live_count()
      assert(SocketTest.connect_host_ok())
      assert(Socket.live_count() == base)
    }

    test("connect_host rejects a syntactically invalid host name with :einval, no crash") {
      assert(SocketTest.connect_host_reason("not a host", 80) == :einval)
    }
  }

  describe("Socket.local_port / peer_port (gate-OFF)") {
    test("peer_port reports the remote endpoint's port; local_port a nonzero ephemeral source port") {
      base = Socket.live_count()
      assert(SocketTest.port_symmetry() == :ok)
      assert(Socket.live_count() == base)
    }
  }

  describe("Socket.set_options / get_option (gate-OFF)") {
    test("set_options(nodelay: true) is ACTUALLY applied — get_option reads back 1 (was 0)") {
      # PRE-fix there was no way to set TCP_NODELAY at all; POST-fix it is set
      # AND reads back on the socket (Nagle off), proving the option reached
      # setsockopt, not merely that the call was accepted.
      assert(SocketTest.nodelay_readback() == :applied)
    }

    test("set_options applies keepalive and a receive buffer (both read back)") {
      assert(SocketTest.keepalive_and_buffer_readback())
    }

    test("set_options on a stale/closed handle yields a typed SocketError, no crash") {
      assert(SocketTest.set_options_on_closed_is_error())
    }

    test("listen/3 with reuse_port lets two listeners bind the same port (EADDRINUSE without)") {
      assert(SocketTest.reuse_port_double_bind())
    }
  }

  # A connected client's PEER port is the listener's bound port it dialed; its
  # LOCAL port is a nonzero ephemeral source port the OS assigned. Proves
  # `peer_port` mirrors `local_port` over the same connected data `Socket`.
  fn port_symmetry() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          result = SocketTest.port_symmetry_on_client(port)
          _closed = SocketListener.close(listener)
          result
        }
    }
  }

  fn port_symmetry_on_client(port :: i64) -> Atom {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) -> :connect_failed
      Result.Ok(client) ->
        {
          peer = Socket.peer_port(client)
          local = Socket.local_port(client)
          _c = Socket.close(client)
          case peer == port {
            false -> :peer_wrong
            true ->
              case local > 0 {
                true -> :ok
                false -> :local_wrong
              }
          }
        }
    }
  }

  fn connect_host_ok() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          connected = case Socket.connect_host("localhost", port, 5000) {
            Result.Ok(client) ->
              {
                _c = Socket.close(client)
                true
              }
            Result.Error(_e) -> false
          }
          _closed = SocketListener.close(listener)
          connected
        }
    }
  }

  fn connect_host_reason(host :: String, port :: i64) -> Atom {
    case Socket.connect_host(host, port, 1000) {
      Result.Ok(client) ->
        {
          _c = Socket.close(client)
          :ok
        }
      Result.Error(error) -> error.reason
    }
  }

  fn run_loopback() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 128) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          SocketTest.connect_phase(listener, port)
        }
    }
  }

  fn connect_phase(listener :: SocketListener, port :: i64) -> Atom {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _closed = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) ->
        {
          open_before = Socket.open?(client)
          _c1 = Socket.close(client)
          open_after = Socket.open?(client)
          _c2 = SocketListener.close(listener)
          both = open_before and (open_after == false)
          case both {
            true -> :ok
            false -> :stale_check_failed
          }
        }
    }
  }

  fn connect_refused?(port :: i64) -> Bool {
    case Socket.connect(SocketAddress.loopback(port), 1000) {
      Result.Error(_e) -> true
      Result.Ok(client) ->
        {
          _closed = Socket.close(client)
          false
        }
    }
  }

  # Connect a loopback client, set nodelay on it, and prove get_option(0)
  # flipped 0 -> 1 (TCP_NODELAY read back set). Returns :applied on success.
  fn nodelay_readback() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          result = SocketTest.nodelay_on_client(port)
          _closed = SocketListener.close(listener)
          result
        }
    }
  }

  fn nodelay_on_client(port :: i64) -> Atom {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) -> :connect_failed
      Result.Ok(client) ->
        {
          before = Socket.get_option(client, 0)
          case Socket.set_options(client, %SocketOptions{nodelay: true}) {
            Result.Error(_e) ->
              {
                _c = Socket.close(client)
                :set_failed
              }
            Result.Ok(configured) ->
              {
                after = Socket.get_option(configured, 0)
                _c = Socket.close(configured)
                nodelay_on = (before == 0) and (after == 1)
                case nodelay_on {
                  true -> :applied
                  false -> :not_applied
                }
              }
          }
        }
    }
  }

  # Prove a second, non-boolean option end-to-end: SO_KEEPALIVE reads back on,
  # and SO_RCVBUF reads back >= the requested size (the OS may round up).
  fn keepalive_and_buffer_readback() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          result = SocketTest.keepalive_on_client(port)
          _closed = SocketListener.close(listener)
          result
        }
    }
  }

  fn keepalive_on_client(port :: i64) -> Bool {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) -> false
      Result.Ok(client) ->
        {
          options = %SocketOptions{keepalive: true, recv_buffer: 16384}
          case Socket.set_options(client, options) {
            Result.Error(_e) ->
              {
                _c = Socket.close(client)
                false
              }
            Result.Ok(configured) ->
              {
                keepalive = Socket.get_option(configured, 1)
                recv_buffer = Socket.get_option(configured, 2)
                _c = Socket.close(configured)
                (keepalive == 1) and (recv_buffer >= 16384)
              }
          }
        }
    }
  }

  # A config op on a closed handle must return Result.Error (the ownership
  # gate), never panic/crash — unlike send/recv, which treat it as a bug.
  fn set_options_on_closed_is_error() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          result = SocketTest.set_options_after_close(port)
          _closed = SocketListener.close(listener)
          result
        }
    }
  }

  fn set_options_after_close(port :: i64) -> Bool {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) -> false
      Result.Ok(client) ->
        {
          _closed = Socket.close(client)
          case Socket.set_options(client, SocketOptions.default()) {
            Result.Ok(_configured) -> false
            Result.Error(error) -> error.reason == :closed
          }
        }
    }
  }

  # listen/3 with reuse_port: a second listener binds the SAME port while the
  # first is still listening — only possible because SO_REUSEPORT was set
  # PRE-bind. Without it the second bind fails EADDRINUSE.
  fn reuse_port_double_bind() -> Bool {
    reuse = %SocketOptions{reuse_port: true, reuse_address: true}
    case Socket.listen(SocketAddress.loopback(0), 8, reuse) {
      Result.Error(_e) -> false
      Result.Ok(first) ->
        {
          port = SocketListener.local_port(first)
          second_ok = SocketTest.second_listener_on(port)
          _closed = SocketListener.close(first)
          second_ok
        }
    }
  }

  fn second_listener_on(port :: i64) -> Bool {
    reuse = %SocketOptions{reuse_port: true, reuse_address: true}
    case Socket.listen(SocketAddress.ip4(127, 0, 0, 1, port), 8, reuse) {
      Result.Error(_e) -> false
      Result.Ok(second) ->
        {
          _closed = SocketListener.close(second)
          true
        }
    }
  }
}
