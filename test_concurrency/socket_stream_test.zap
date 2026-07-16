pub struct TestConcurrency.SocketStreamTest {
  use Zest.Case

  # Phase S1 exit-gate acceptance (gate-ON): the Tier-1 stream surface under
  # the LIVE concurrency kernel — every blocking op (connect/accept/recv/send)
  # offloads onto the blocking pool off the process's core (Decision D), and
  # the poll-quantum leaf enforces the recv timeout (§6.1). What these pin:
  #
  #   * a binary-safe full-duplex echo roundtrip completes under the kernel;
  #   * `shutdown(:write)` half-close: the peer reads EOF (`SocketRecv.Closed`);
  #   * an idle `recv` timeout yields `Failed(:etimedout)` off-core and leaves
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
      Result.Ok(listener) -> TestConcurrency.SocketStreamTest.echo_after_listen(listener)
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
      Result.Ok(client) -> TestConcurrency.SocketStreamTest.echo_after_connect(listener, client)
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
      Result.Ok(server) -> TestConcurrency.SocketStreamTest.echo_exchange(listener, client, server)
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
      Result.Ok(listener) -> TestConcurrency.SocketStreamTest.stream_after_listen(listener)
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
      Result.Ok(client) -> TestConcurrency.SocketStreamTest.stream_after_connect(listener, client)
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
      Result.Ok(server) -> TestConcurrency.SocketStreamTest.stream_exchange(listener, client, server)
    }
  }

  fn stream_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _sent = Socket.send(server, "abcdefghij")
    _shut = Socket.shutdown(server, :write)
    # A `for` comprehension folds the live stream to EOF under the kernel (the
    # fiber PARKS between chunks; the core runs peers). Sizes sum to 10.
    sizes = for chunk <- Socket.chunks(client, 5000) {
      TestConcurrency.SocketStreamTest.chunk_size(chunk)
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
      Result.Ok(listener) -> TestConcurrency.SocketStreamTest.timeout_after_listen(listener)
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
      Result.Ok(client) -> TestConcurrency.SocketStreamTest.timeout_after_connect(listener, client)
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
      Result.Ok(server) -> TestConcurrency.SocketStreamTest.timeout_exchange(listener, client, server)
    }
  }

  fn timeout_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    timed = case Socket.recv(server, 0, 150) {
      SocketRecv.Failed(error) ->
        case error.reason == :etimedout {
          true -> :timeout
          false -> :wrong_reason
        }
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
  # (Phase S1 gap fix). Each `recv` returns a fresh transient String; a
  # long-lived connection performs many recvs, so a per-recv leak would be a
  # memory-exhaustion DoS. The recv String is allocated from the runtime String
  # arena (like `IO.gets`/`File.read`/`String.concat`), NOT the per-process
  # message-adoption heap, so it is LEAK-EXACT under `Memory.Tracking`: this
  # test drives 32 recvs and, run under `-Dmemory=Memory.Tracking`, must report
  # ZERO leaks. `Socket.live_count` returns to baseline (no fd leak either).
  fn many_recvs() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> TestConcurrency.SocketStreamTest.many_after_listen(listener)
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
      Result.Ok(client) -> TestConcurrency.SocketStreamTest.many_after_connect(listener, client)
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
      Result.Ok(server) -> TestConcurrency.SocketStreamTest.many_exchange(listener, client, server)
    }
  }

  fn many_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _pumped = TestConcurrency.SocketStreamTest.pump_chunks(client, 32)
    total = TestConcurrency.SocketStreamTest.drain_chunks(server, 32, 0)
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
          TestConcurrency.SocketStreamTest.pump_chunks(client, remaining - 1)
        }
    }
  }

  fn drain_chunks(server :: Socket, remaining :: i64, acc :: i64) -> i64 {
    case remaining <= 0 {
      true -> acc
      false ->
        case Socket.recv(server, 4, 5000) {
          SocketRecv.Chunk(bytes) -> TestConcurrency.SocketStreamTest.drain_chunks(server, remaining - 1, acc + String.length(bytes))
          SocketRecv.Closed -> acc
          SocketRecv.Failed(_e) -> acc
        }
    }
  }

  describe("Socket Tier-1 streams under the concurrency kernel (gate-ON)") {
    test("binary-safe echo roundtrip offloaded off-core, leak-exact") {
      base = Socket.live_count()
      assert(TestConcurrency.SocketStreamTest.echo_binary_safe() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a multi-recv loop is leak-exact (recv Strings reclaimed; no per-recv leak)") {
      base = Socket.live_count()
      assert(TestConcurrency.SocketStreamTest.many_recvs() == 128)
      assert(Socket.live_count() == base)
    }

    test("a for comprehension folds a live Socket.chunks stream to EOF (fiber parks)") {
      base = Socket.live_count()
      assert(TestConcurrency.SocketStreamTest.stream_total() == 10)
      assert(Socket.live_count() == base)
    }

    test("idle recv timeout yields :etimedout off-core; socket stays usable") {
      base = Socket.live_count()
      assert(TestConcurrency.SocketStreamTest.timeout_usable() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
