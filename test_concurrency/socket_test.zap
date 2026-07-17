pub struct TestConcurrency.SocketTest {
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
      assert(TestConcurrency.SocketTest.loopback_ok())
      assert(Socket.live_count() == base)
    }

    test("connect_host (Happy Eyeballs) resolves localhost and connects under the kernel, leak-exactly") {
      base = Socket.live_count()
      assert(TestConcurrency.SocketTest.connect_host_ok())
      # Every attempt fd (winner closed, any resolved loser reclaimed by the
      # racing driver) is accounted for — back to baseline under the kernel.
      assert(Socket.live_count() == base)
    }

    test("fd is reclaimed by the drop-list when the owning process EXITS without closing") {
      base = Socket.live_count()
      _monitored = Process.spawn_monitor(&TestConcurrency.SocketTest.leaky_worker/0)
      _down = Process.await_signal()
      # The worker exited having opened a socket it never closed; its
      # socket-sweep drop destructor closed the fd at teardown.
      assert(Socket.live_count() == base)
    }

    test("fd is reclaimed by the drop-list when the owning process is KILLED") {
      _named = Process.register(:socket_kill_parent)
      base = Socket.live_count()
      pair = Process.spawn_monitor(&TestConcurrency.SocketTest.parked_worker/0)
      _ack = receive Atom {
        _opened -> :ok
      }
      # The worker has opened a socket and parked.
      assert(Socket.live_count() == base + 1)
      _killed = Process.kill(pair.0)
      _down = Process.await_signal()
      # The kill teardown path ran the same drop-list sweep.
      assert(Socket.live_count() == base)
    }
  }

  fn loopback_ok() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 128) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          TestConcurrency.SocketTest.connect_close(listener, port)
        }
    }
  }

  fn connect_host_ok() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 128) {
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

  fn connect_close(listener :: SocketListener, port :: i64) -> Bool {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _c = SocketListener.close(listener)
          false
        }
      Result.Ok(client) ->
        {
          was_open = Socket.open?(client)
          _c1 = Socket.close(client)
          gone = Socket.open?(client) == false
          _c2 = SocketListener.close(listener)
          was_open and gone
        }
    }
  }

  # Opens a listener and exits WITHOUT closing it — the drop-list sweep must
  # close its fd at teardown (normal exit path).
  pub fn leaky_worker() -> Nil {
    _result = Socket.listen(SocketAddress.loopback(0), 1)
    nil
  }

  # Opens a listener, tells the parent it is open, then parks forever — so
  # the parent can KILL it and verify the drop-list closes its fd on the
  # kill path too.
  pub fn parked_worker() -> Nil {
    _result = Socket.listen(SocketAddress.loopback(0), 1)
    _sent = Process.send(:socket_kill_parent, :opened)
    _parked = receive Atom {
      _any -> :ok
    }
    nil
  }
}
