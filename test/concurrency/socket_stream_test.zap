pub struct Concurrency.SocketStreamTest {
  use Zest.Case

  # Phase S1 exit-gate acceptance (gate-ON): the Tier-1 stream surface under
  # the LIVE concurrency kernel — every blocking op (connect/accept/recv/send)
  # offloads onto the blocking pool off the process's core (Decision D), and
  # the poll-quantum leaf enforces the recv timeout (§6.1). What these pin:
  #
  #   * a binary-safe full-duplex echo roundtrip completes under the kernel;
  #   * `shutdown(:write)` half-close: the peer reads EOF (`SocketRecv.Closed`);
  #   * an idle `recv` timeout yields `TimedOut(partial)` off-core and leaves
  #     the socket usable;
  #   * a `for` comprehension folds a live `Socket.chunks` stream to EOF while
  #     the fiber PARKS between chunks (the core is freed to run peers);
  #   * everything is leak-exact against `Socket.live_count`.
  #
  # The single-owner, value-threaded surface is exercised within ONE process
  # here; cross-process `send_move` handoff re-parenting is Phase S3.

  fn echo_binary_safe() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> Concurrency.SocketStreamTest.echo_after_listen(listener)
    }
  }

  fn echo_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketStreamTest.echo_after_connect(listener, client)
    }
  }

  fn echo_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> Concurrency.SocketStreamTest.echo_exchange(listener, client, server)
    }
  }

  fn echo_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    payload = "hi\x00\xffz"
    plen = String.length(payload)
    _sent = Socket.send(client, payload)
    forward = case Socket.recv(server, plen, 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == payload {
          true -> :ok
          false -> :mismatch
        }
      SocketRecv.TimedOut(_partial) -> :unexpected_timeout
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    forward
  }

  fn stream_total() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> Concurrency.SocketStreamTest.stream_after_listen(listener)
    }
  }

  fn stream_after_listen(listener :: SocketListener) -> i64 {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(client) -> Concurrency.SocketStreamTest.stream_after_connect(listener, client)
    }
  }

  fn stream_after_connect(listener :: SocketListener, client :: Socket) -> i64 {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(server) -> Concurrency.SocketStreamTest.stream_exchange(listener, client, server)
    }
  }

  fn stream_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _sent = Socket.send(server, "abcdefghij")
    _shut = Socket.shutdown(server, :write)
    # A `for` comprehension folds the live stream to EOF under the kernel (the
    # fiber PARKS between chunks; the core runs peers). Sizes sum to 10.
    sizes = for chunk <- Socket.chunks(client, 5000) {
      Concurrency.SocketStreamTest.chunk_size(chunk)
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    Enum.sum(sizes)
  }

  fn chunk_size(chunk :: Result(String, SocketError)) -> i64 {
    case chunk {
      Result.Ok(bytes) -> String.length(bytes)
      Result.Error(_e) -> 0
    }
  }

  fn timeout_usable() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> Concurrency.SocketStreamTest.timeout_after_listen(listener)
    }
  }

  fn timeout_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketStreamTest.timeout_after_connect(listener, client)
    }
  }

  fn timeout_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> Concurrency.SocketStreamTest.timeout_exchange(listener, client, server)
    }
  }

  fn timeout_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    timed = case Socket.recv(server, 0, 150) {
      # A next-available idle timeout is the dedicated TimedOut variant off-core
      # (empty partial — nothing arrived before the deadline), NOT Failed.
      SocketRecv.TimedOut(_partial) -> :timeout
      SocketRecv.Failed(_e) -> :wrong_reason
      SocketRecv.Chunk(_b) -> :unexpected_data
      SocketRecv.Closed -> :unexpected_eof
    }
    _sent = Socket.send(client, "after")
    usable = case Socket.recv(server, 0, 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == "after" {
          true -> :ok
          false -> :mismatch
        }
      SocketRecv.TimedOut(_partial) -> :not_usable
      SocketRecv.Closed -> :not_usable
      SocketRecv.Failed(_e) -> :not_usable
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    passed = (timed == :timeout) and (usable == :ok)
    case passed {
      true -> :ok
      false -> :timeout_failed
    }
  }

  # A MULTI-RECV loop over one connection — the recv-String reclamation gate
  # (HIGH-4). Each `recv` returns a fresh transient String; a long-lived
  # connection performs many recvs, so a per-recv leak would be a memory-
  # exhaustion DoS. The recv String now lives in the receiving PROCESS'S PRIVATE
  # recv arena (bound to the process's lifetime, wholesale-reclaimed at its
  # teardown), NOT the program-global `runtime_arena` it used to accumulate in
  # forever. That arena is a raw arena OUTSIDE every manager (like the old
  # `runtime_arena` path), so a recv String is still LEAK-EXACT under
  # `Memory.Tracking` — never recorded by a tracked manager, so no header-less-
  # slice false positive: this test drives 32 recvs and, run under
  # `-Dmemory=Memory.Tracking`, must report ZERO leaks. `Socket.live_count`
  # returns to baseline (no fd leak either).
  fn many_recvs() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> Concurrency.SocketStreamTest.many_after_listen(listener)
    }
  }

  fn many_after_listen(listener :: SocketListener) -> i64 {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(client) -> Concurrency.SocketStreamTest.many_after_connect(listener, client)
    }
  }

  fn many_after_connect(listener :: SocketListener, client :: Socket) -> i64 {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(server) -> Concurrency.SocketStreamTest.many_exchange(listener, client, server)
    }
  }

  fn many_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _pumped = Concurrency.SocketStreamTest.pump_chunks(client, 32)
    total = Concurrency.SocketStreamTest.drain_chunks(server, 32, 0)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    total
  }

  fn pump_chunks(client :: Socket, remaining :: i64) -> Bool {
    case remaining <= 0 {
      true -> true
      false ->
        {
          _sent = Socket.send(client, "wxyz")
          Concurrency.SocketStreamTest.pump_chunks(client, remaining - 1)
        }
    }
  }

  fn drain_chunks(server :: Socket, remaining :: i64, acc :: i64) -> i64 {
    case remaining <= 0 {
      true -> acc
      false ->
        case Socket.recv(server, 4, 5000) {
          SocketRecv.Chunk(bytes) -> Concurrency.SocketStreamTest.drain_chunks(server, remaining - 1, acc + String.length(bytes))
          SocketRecv.TimedOut(_partial) -> acc
          SocketRecv.Closed -> acc
          SocketRecv.Failed(_e) -> acc
        }
    }
  }

  # A worker that STALLS in a blocking send to a peer that never reads
  # (slowloris-on-send): it sets up a loopback pair, holds the receiving end
  # WITHOUT reading it, tells the parent it is stalled, then sends a payload far
  # larger than the OS send buffer — which blocks. Under the pre-fix code a bare
  # blocking write pins the pool thread FOREVER and the process is UNKILLABLE;
  # with the poll-quantum + kill_flag send loop (HIGH-2), a kill is observed
  # within a quantum and the process tears down, closing every fd (drop-list).
  pub fn stalled_sender_entry() -> Nil {
    # The chain returns an Atom (all arms Atom-typed, like the echo chain); the
    # spawn entry discards it and returns Nil. A `case` with a bare `nil` in one
    # arm and a concrete-Nil helper call in another does not type-unify (the
    # `nil` literal is `@TypeOf(null)`), so the helpers thread an Atom instead.
    _result = Concurrency.SocketStreamTest.stalled_sender_run()
    nil
  }

  fn stalled_sender_run() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) ->
        {
          _n = Process.send(:socket_send_kill_parent, :stalled)
          :listen_failed
        }
      Result.Ok(listener) -> Concurrency.SocketStreamTest.stalled_sender_connect(listener)
    }
  }

  fn stalled_sender_connect(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _n = Process.send(:socket_send_kill_parent, :stalled)
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketStreamTest.stalled_sender_accept(listener, client)
    }
  }

  fn stalled_sender_accept(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _n = Process.send(:socket_send_kill_parent, :stalled)
          :accept_failed
        }
      # The server end is held but NEVER read — the send buffer fills and the
      # send below blocks. Notify the parent, then stall (no timeout) so the
      # ONLY way out is a kill: this is the kill-responsiveness assertion.
      Result.Ok(_server) ->
        {
          _n = Process.send(:socket_send_kill_parent, :stalled)
          _stuck = Socket.send(client, String.repeat("x", 4000000))
          :sent
        }
    }
  }

  # A worker that STALLS in a blocking connect to a black-hole address
  # (192.0.2.1, TEST-NET-1): the SYN goes unanswered so the connect parks in
  # its poll-quantum loop. Under the pre-fix code the blocking connect pins the
  # pool thread on the OS default (~127s), unkillable; with the kill_flag
  # threaded into the connect leaf (HIGH-2) a kill is observed within a quantum.
  # (Where the environment rejects the SYN immediately the connect just returns
  # and the worker exits — the parent's `await_signal` returns either way; the
  # regression it guards against is the UNKILLABLE hang.)
  pub fn stalled_connector_entry() -> Nil {
    _n = Process.send(:socket_connect_kill_parent, :stalled)
    _stuck = Socket.connect(SocketAddress.ip4(192, 0, 2, 1, 80), 0)
    nil
  }

  # A worker that BLOCKS in `Socket.accept` with no incoming connection — the
  # only way out is a kill. `accept` offloads onto the blocking pool and polls
  # its kill_flag each poll quantum (HIGH-1 kill-responsiveness); a regression
  # would pin the pool thread forever and leave the process UNKILLABLE, hanging
  # the parent's `await_signal`. The listener fd is reclaimed on the kill path
  # by the drop-list sweep (live_count returns to baseline).
  pub fn stalled_acceptor_entry() -> Nil {
    _result = Concurrency.SocketStreamTest.stalled_acceptor_run()
    nil
  }

  fn stalled_acceptor_run() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) ->
        {
          _n = Process.send(:socket_accept_kill_parent, :stalled)
          :listen_failed
        }
      Result.Ok(listener) ->
        {
          _n = Process.send(:socket_accept_kill_parent, :stalled)
          _blocked = Socket.accept(listener)
          :accepted
        }
    }
  }

  describe("Socket Tier-1 streams under the concurrency kernel (gate-ON)") {
    test("a process stalled in a slowloris send is KILLABLE (send is kill-responsive off-core)") {
      assert(Process.register(:socket_send_kill_parent))
      base = Socket.live_count()
      pair = Process.spawn_monitor(&Concurrency.SocketStreamTest.stalled_sender_entry/0)
      _ack = receive Atom {
        _stalled -> :ok
      }
      # The worker is blocked in a send to a non-reading peer. Killing it must
      # tear it down PROMPTLY (this returns only if the send yielded to the
      # kill); a regression would hang here forever.
      _killed = Process.kill(pair.0)
      _down = Process.await_signal()
      # Every fd (listener + client + server) reclaimed on the kill path.
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_send_kill_parent)
    }

    test("a process stalled in a black-hole connect is KILLABLE (connect is kill-responsive off-core)") {
      assert(Process.register(:socket_connect_kill_parent))
      base = Socket.live_count()
      pair = Process.spawn_monitor(&Concurrency.SocketStreamTest.stalled_connector_entry/0)
      _ack = receive Atom {
        _stalled -> :ok
      }
      _killed = Process.kill(pair.0)
      _down = Process.await_signal()
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_connect_kill_parent)
    }

    test("a process blocked in accept with no connection is KILLABLE (accept is kill-responsive off-core)") {
      assert(Process.register(:socket_accept_kill_parent))
      base = Socket.live_count()
      pair = Process.spawn_monitor(&Concurrency.SocketStreamTest.stalled_acceptor_entry/0)
      _ack = receive Atom {
        _stalled -> :ok
      }
      # The worker is blocked in `accept` with nothing to accept. Killing it must
      # tear it down PROMPTLY (this returns only if accept yielded to the kill);
      # a regression would hang here forever. Every fd (the listener) is
      # reclaimed on the kill path.
      _killed = Process.kill(pair.0)
      _down = Process.await_signal()
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_accept_kill_parent)
    }

    test("binary-safe echo roundtrip offloaded off-core, leak-exact") {
      base = Socket.live_count()
      assert(Concurrency.SocketStreamTest.echo_binary_safe() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a multi-recv loop is leak-exact (recv Strings reclaimed; no per-recv leak)") {
      base = Socket.live_count()
      assert(Concurrency.SocketStreamTest.many_recvs() == 128)
      assert(Socket.live_count() == base)
    }

    test("a for comprehension folds a live Socket.chunks stream to EOF (fiber parks)") {
      base = Socket.live_count()
      assert(Concurrency.SocketStreamTest.stream_total() == 10)
      assert(Socket.live_count() == base)
    }

    test("idle recv timeout yields :etimedout off-core; socket stays usable") {
      base = Socket.live_count()
      assert(Concurrency.SocketStreamTest.timeout_usable() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
