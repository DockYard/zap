pub struct Concurrency.SocketTest {
  use Zest.Case

  # Phase S0 acceptance proof (gate-ON): the socket layer under the live
  # concurrency kernel. What these pin, end to end at the Zap surface:
  #
  #   * a green process opens a loopback socket, offloading the blocking
  #     connect/listen onto the blocking pool (Decision D — off its core),
  #     and closes it leak-exactly against `Socket.live_count`;
  #   * a process that opens a socket and EXITS without closing it has its
  #     fd reclaimed by the drop-list socket-sweep at teardown — the
  #     per-process socket ledger drained on every exit path;
  #   * the SAME reclaim holds when the owner is KILLED (the drop-list runs
  #     on the kill teardown path too), so a crashing handler leaks no fd.
  #
  # The single-owner, move-only handle + generation-validated stale-handle
  # discipline is shared with the gate-OFF suite
  # (`test/socket_test.zap`); the kernel-domain leak-exactness oracle is
  # `Socket.live_count` returning to its baseline after every close/exit.

  describe("Socket under the concurrency kernel (gate-ON)") {
    test("a green process opens a loopback socket and closes it leak-exactly") {
      base = Socket.live_count()
      assert(Concurrency.SocketTest.loopback_ok())
      assert(Socket.live_count() == base)
    }

    test("connect_host (Happy Eyeballs) resolves localhost and connects under the kernel, leak-exactly") {
      base = Socket.live_count()
      assert(Concurrency.SocketTest.connect_host_ok())
      # Every attempt fd (winner closed, any resolved loser reclaimed by the
      # racing driver) is accounted for — back to baseline under the kernel.
      assert(Socket.live_count() == base)
    }

    test("fd is reclaimed by the drop-list when the owning process EXITS without closing") {
      base = Socket.live_count()
      _monitored = Process.spawn_monitor(&Concurrency.SocketTest.leaky_worker/0)
      _down = Process.await_signal()
      # The worker exited having opened a socket it never closed; its
      # socket-sweep drop destructor closed the fd at teardown.
      assert(Socket.live_count() == base)
    }

    test("fd is reclaimed by the drop-list when the owning process is KILLED") {
      assert(Process.register(:socket_kill_parent))
      base = Socket.live_count()
      pair = Process.spawn_monitor(&Concurrency.SocketTest.parked_worker/0)
      _ack = receive Atom {
        _opened -> :ok
      }
      # The worker has opened a socket and parked.
      assert(Socket.live_count() == base + 1)
      _killed = Process.kill(pair.0)
      _down = Process.await_signal()
      # The kill teardown path ran the same drop-list sweep.
      assert(Socket.live_count() == base)
      # Release the root process's registered name — the shared root process
      # holds at most ONE name and never exits, so a leaked registration here
      # makes every later root-process `Process.register` in the run silently
      # fail and hang its name-routed receives (cross-test hygiene; see
      # SupervisorTest.cleanup for the same discipline).
      _unreg = Process.unregister(:socket_kill_parent)
    }
  }

  describe("Socket.set_options under the concurrency kernel (gate-ON)") {
    test("set_options(nodelay: true) is applied through the ABI/ledger path — get_option reads back 1") {
      base = Socket.live_count()
      # The full gate-ON path: the ownership-gated zap_socket_set_option ABI
      # over the per-process ledger, applying setsockopt inline on the owned fd.
      assert(Concurrency.SocketTest.nodelay_applied_under_kernel() == :applied)
      assert(Socket.live_count() == base)
    }

    test("set_options on a stale handle returns a typed Socket.Error (ownership gate), no crash") {
      assert(Concurrency.SocketTest.set_options_on_closed_is_error())
    }
  }

  fn loopback_ok() -> Bool {
    case Socket.listen(Socket.Address.loopback(0), 128) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          Concurrency.SocketTest.connect_close(listener, port)
        }
    }
  }

  fn connect_host_ok() -> Bool {
    case Socket.listen(Socket.Address.loopback(0), 128) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          connected = case Socket.connect_host("localhost", port, 5000) {
            Result.Ok(client) ->
              {
                _c = Socket.close(client)
                true
              }
            Result.Error(_e) -> false
          }
          _closed = Socket.Listener.close(listener)
          connected
        }
    }
  }

  fn connect_close(listener :: Socket.Listener, port :: i64) -> Bool {
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _c = Socket.Listener.close(listener)
          false
        }
      Result.Ok(client) ->
        {
          was_open = Socket.open?(client)
          _c1 = Socket.close(client)
          gone = Socket.open?(client) == false
          _c2 = Socket.Listener.close(listener)
          was_open and gone
        }
    }
  }

  # Gate-ON read-back: connect a loopback client under the kernel, set nodelay
  # via the ownership-gated ABI, and confirm get_option(0) flipped 0 -> 1.
  fn nodelay_applied_under_kernel() -> Atom {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          result = Concurrency.SocketTest.nodelay_on_client(port)
          _closed = Socket.Listener.close(listener)
          result
        }
    }
  }

  fn nodelay_on_client(port :: i64) -> Atom {
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) -> :connect_failed
      Result.Ok(client) ->
        {
          before = Socket.get_option(client, 0)
          case Socket.set_options(client, %Socket.Options{nodelay: true}) {
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

  fn set_options_on_closed_is_error() -> Bool {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          result = Concurrency.SocketTest.set_options_after_close(port)
          _closed = Socket.Listener.close(listener)
          result
        }
    }
  }

  fn set_options_after_close(port :: i64) -> Bool {
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) -> false
      Result.Ok(client) ->
        {
          _closed = Socket.close(client)
          case Socket.set_options(client, Socket.Options.default()) {
            Result.Ok(_configured) -> false
            Result.Error(error) -> error.reason == :closed
          }
        }
    }
  }

  # Opens a listener and exits WITHOUT closing it — the drop-list sweep must
  # close its fd at teardown (normal exit path).
  pub fn leaky_worker() -> Nil {
    _result = Socket.listen(Socket.Address.loopback(0), 1)
    nil
  }

  # Opens a listener, tells the parent it is open, then parks forever — so
  # the parent can KILL it and verify the drop-list closes its fd on the
  # kill path too.
  pub fn parked_worker() -> Nil {
    _result = Socket.listen(Socket.Address.loopback(0), 1)
    _sent = Process.send(:socket_kill_parent, :opened)
    _parked = receive Atom {
      _any -> :ok
    }
    nil
  }
}
