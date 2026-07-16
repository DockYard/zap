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
}
