pub struct SocketStreamTest {
  use Zest.Case

  # Phase S1 exit-gate acceptance (gate-OFF): the full Tier-1 value-threaded
  # surface driven end to end over a self-contained loopback pair on the single
  # OS thread (Decision D). What these pin:
  #
  #   * a full-duplex echo roundtrip with a BINARY-SAFE payload (embedded NUL +
  #     an invalid-UTF-8 byte) survives intact through send/recv both ways;
  #   * `recv_exact` reads exactly N bytes;
  #   * `shutdown(:write)` half-closes: the peer reads `SocketRecv.Closed` (EOF)
  #     while the writer's handle stays valid (graceful handshake);
  #   * an idle `recv` timeout yields `TimedOut(partial)` and leaves the socket
  #     OPEN and usable (Erlang semantics — timeout never closes); a
  #     `recv_exact` that times out mid-frame SURFACES the already-consumed
  #     partial bytes (no desync — MED-1) so a follow-up recv stays aligned;
  #   * `Socket.chunks` streams: a `for` comprehension consumes a bounded
  #     loopback stream to EOF (folding the byte total); `Enum.take` early-exits
  #     and `dispose` releases only the iterator state (the fd stays open — a
  #     fresh `chunks` resumes); `Socket.fold` halts mid-stream on a protocol
  #     terminator. (`Enum.reduce`/`reduce_while`/`each` DIRECTLY over a
  #     `Result`-element stream currently hit a compiler gap in the generic
  #     callback dispatch — reported; `for`/`take`/`fold` cover the surface.)
  #   * everything is leak-exact against `Socket.live_count`.
  #
  # Single-threaded loopback ordering: `listen` → `connect` (the kernel
  # completes the handshake and queues the connection, so `connect` returns) →
  # `accept` (dequeues it). Payloads are small (fit the socket buffers) so a
  # `send` never blocks waiting for a reader on the same thread.

  # ---- connection setup helpers (return an atom result; assert in the test) --

  fn echo_binary_safe() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketStreamTest.echo_after_listen(listener)
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
      Result.Ok(client) -> SocketStreamTest.echo_after_connect(listener, client)
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
      Result.Ok(server) -> SocketStreamTest.echo_exchange(listener, client, server)
    }
  }

  fn echo_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    payload = "hi\x00\xffz"
    _sent = Socket.send(client, payload)
    forward = SocketStreamTest.classify_exact(Socket.recv(server, String.length(payload), 5000), payload)
    _reply = Socket.send(server, "pong")
    backward = SocketStreamTest.classify_next(Socket.recv(client, 0, 5000), "pong")
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    case forward == :ok {
      true -> backward
      false -> forward
    }
  }

  fn classify_exact(received :: SocketRecv, expected :: String) -> Atom {
    case received {
      SocketRecv.Chunk(bytes) ->
        case bytes == expected {
          true -> :ok
          false -> :mismatch
        }
      SocketRecv.TimedOut(_partial) -> :unexpected_timeout
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :recv_failed
    }
  }

  fn classify_next(received :: SocketRecv, expected :: String) -> Atom {
    SocketStreamTest.classify_exact(received, expected)
  }

  # ---- shutdown(:write) graceful half-close -> peer reads EOF ---------------

  fn half_close_eof() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketStreamTest.half_close_after_listen(listener)
    }
  }

  fn half_close_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> SocketStreamTest.half_close_after_connect(listener, client)
    }
  }

  fn half_close_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketStreamTest.half_close_exchange(listener, client, server)
    }
  }

  fn half_close_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    _sent = Socket.send(client, "final")
    # Client half-closes its WRITE side; the handle must stay valid.
    _shut = Socket.shutdown(client, :write)
    still_open = Socket.open?(client)
    # Server reads the buffered "final", then EOF (Closed) once drained.
    first = Socket.recv(server, 0, 5000)
    got_data = SocketStreamTest.classify_next(first, "final")
    eof = SocketStreamTest.classify_eof(Socket.recv(server, 0, 5000))
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    passed = still_open and (got_data == :ok) and (eof == :closed)
    case passed {
      true -> :ok
      false -> :handshake_failed
    }
  }

  fn classify_eof(received :: SocketRecv) -> Atom {
    case received {
      SocketRecv.Chunk(_bytes) -> :unexpected_data
      SocketRecv.TimedOut(_partial) -> :unexpected_timeout
      SocketRecv.Closed -> :closed
      SocketRecv.Failed(_e) -> :failed
    }
  }

  # ---- idle recv timeout does NOT close the socket -------------------------

  fn timeout_keeps_open() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketStreamTest.timeout_after_listen(listener)
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
      Result.Ok(client) -> SocketStreamTest.timeout_after_connect(listener, client)
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
      Result.Ok(server) -> SocketStreamTest.timeout_exchange(listener, client, server)
    }
  }

  fn timeout_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    # Nothing sent: the recv must TIME OUT (never hang), reason :etimedout.
    timed = SocketStreamTest.classify_timeout(Socket.recv(server, 0, 150))
    # The socket must still be usable after the timeout.
    _sent = Socket.send(client, "after")
    usable = SocketStreamTest.classify_next(Socket.recv(server, 0, 5000), "after")
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    passed = (timed == :timeout) and (usable == :ok)
    case passed {
      true -> :ok
      false -> :timeout_failed
    }
  }

  fn classify_timeout(received :: SocketRecv) -> Atom {
    case received {
      SocketRecv.Chunk(_bytes) -> :unexpected_data
      # A next-available idle timeout is now the dedicated TimedOut variant
      # (empty partial — nothing was read before the deadline), NOT Failed.
      SocketRecv.TimedOut(_partial) -> :timeout
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :wrong_reason
    }
  }

  # ---- streaming: Enum.reduce / for over Socket.chunks to EOF ---------------

  fn stream_total_via_reduce() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> SocketStreamTest.stream_reduce_after_listen(listener)
    }
  }

  fn stream_reduce_after_listen(listener :: SocketListener) -> i64 {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(client) -> SocketStreamTest.stream_reduce_after_connect(listener, client)
    }
  }

  fn stream_reduce_after_connect(listener :: SocketListener, client :: Socket) -> i64 {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(server) -> SocketStreamTest.stream_reduce_exchange(listener, client, server)
    }
  }

  fn stream_reduce_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _sent = Socket.send(server, "abcdefghij")
    _shut = Socket.shutdown(server, :write)
    # A `for` comprehension folds the live stream to EOF, extracting each
    # chunk's byte size; `Enum.sum` totals them. The 10 sent bytes arrive as
    # one or more chunks and sum to 10 once the stream reaches `:done`.
    sizes = for chunk <- Socket.chunks(client, 5000) {
      SocketStreamTest.chunk_size(chunk)
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    Enum.sum(sizes)
  }

  fn stream_count_via_for() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> SocketStreamTest.stream_for_after_listen(listener)
    }
  }

  fn stream_for_after_listen(listener :: SocketListener) -> i64 {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(client) -> SocketStreamTest.stream_for_after_connect(listener, client)
    }
  }

  fn stream_for_after_connect(listener :: SocketListener, client :: Socket) -> i64 {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(server) -> SocketStreamTest.stream_for_exchange(listener, client, server)
    }
  }

  fn stream_for_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _sent = Socket.send(server, "xyz")
    _shut = Socket.shutdown(server, :write)
    sizes = for chunk <- Socket.chunks(client, 5000) {
      SocketStreamTest.chunk_size(chunk)
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

  # ---- borrow semantics: take early-exits, dispose keeps the fd open --------

  fn take_then_resume() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketStreamTest.take_after_listen(listener)
    }
  }

  fn take_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> SocketStreamTest.take_after_connect(listener, client)
    }
  }

  fn take_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketStreamTest.take_exchange(listener, client, server)
    }
  }

  fn take_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    _first = Socket.send(server, "AAAA")
    # take ONE chunk, then dispose the iterator (borrow: fd NOT closed).
    taken = Enum.take(Socket.chunks(client, 5000), 1)
    still_open = Socket.open?(client)
    # A FRESH chunks/recv on the same open fd resumes reading the next bytes.
    _second = Socket.send(server, "BBBB")
    resumed = SocketStreamTest.classify_next(Socket.recv(client, 0, 5000), "BBBB")
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    passed = still_open and (resumed == :ok) and (List.length(taken) == 1)
    case passed {
      true -> :ok
      false -> :resume_failed
    }
  }

  # ---- Socket.fold halts mid-stream on a protocol condition -----------------

  fn fold_halts_on_terminator() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketStreamTest.fold_after_listen(listener)
    }
  }

  fn fold_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> SocketStreamTest.fold_after_connect(listener, client)
    }
  }

  fn fold_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketStreamTest.fold_exchange(listener, client, server)
    }
  }

  fn fold_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    # Server sends a NUL-terminated record; fold halts as soon as it sees NUL,
    # WITHOUT waiting for EOF — the protocol-condition early-halt.
    _sent = Socket.send(server, "ready\x00ignored-trailer")
    outcome = Socket.fold(client, "", 5000, fn(acc :: String, bytes :: String) -> {Atom, String} {
      combined = acc <> bytes
      case String.contains?(combined, "\x00") {
        true -> {:halt, combined}
        false -> {:cont, combined}
      }
    })
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    case outcome {
      Result.Ok(text) ->
        case String.contains?(text, "ready") {
          true -> :ok
          false -> :missing_prefix
        }
      Result.Error(_e) -> :fold_failed
    }
  }

  # ---- recv_exact timeout surfaces the partial bytes (MED-1, no desync) -----

  fn partial_on_timeout() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketStreamTest.partial_after_listen(listener)
    }
  }

  fn partial_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> SocketStreamTest.partial_after_connect(listener, client)
    }
  }

  fn partial_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketStreamTest.partial_exchange(listener, client, server)
    }
  }

  fn partial_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    # Client sends only 3 of the 10 bytes the server's recv_exact will demand.
    _sent = Socket.send(client, "abc")
    # recv_exact(10) consumes the 3 available bytes, then times out waiting for
    # the missing 7. The 3 consumed bytes MUST be surfaced (TimedOut), not
    # silently dropped — dropping them would desync the next framed read.
    partial_ok = case Socket.recv_exact(server, 10, 200) {
      SocketRecv.TimedOut(partial) ->
        case partial == "abc" {
          true -> :ok
          false -> :wrong_partial
        }
      SocketRecv.Chunk(_b) -> :unexpected_full
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :unexpected_failure
    }
    # The remaining bytes arrive; a follow-up recv_exact sees the ALIGNED
    # remainder ("defghij"), proving the partial was surfaced, not re-consumed.
    _more = Socket.send(client, "defghij")
    aligned = case Socket.recv_exact(server, 7, 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == "defghij" {
          true -> :ok
          false -> :misaligned
        }
      SocketRecv.TimedOut(_p) -> :unexpected_timeout
      SocketRecv.Closed -> :unexpected_eof
      SocketRecv.Failed(_e) -> :recv_failed
    }
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    passed = (partial_ok == :ok) and (aligned == :ok)
    case passed {
      true -> :ok
      false -> :partial_failed
    }
  }

  # ------------------------------------------------------------------------

  describe("Socket Tier-1 streams (gate-OFF)") {
    test("binary-safe full-duplex echo roundtrip, leak-exact") {
      base = Socket.live_count()
      assert(SocketStreamTest.echo_binary_safe() == :ok)
      assert(Socket.live_count() == base)
    }

    test("shutdown(:write) half-close: peer reads EOF, writer handle stays valid") {
      base = Socket.live_count()
      assert(SocketStreamTest.half_close_eof() == :ok)
      assert(Socket.live_count() == base)
    }

    test("idle recv timeout yields TimedOut and leaves the socket usable") {
      base = Socket.live_count()
      assert(SocketStreamTest.timeout_keeps_open() == :ok)
      assert(Socket.live_count() == base)
    }

    test("recv_exact idle timeout surfaces the partial bytes (no desync); a follow-up recv is aligned") {
      base = Socket.live_count()
      assert(SocketStreamTest.partial_on_timeout() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a for comprehension folds Socket.chunks byte-total to EOF") {
      base = Socket.live_count()
      assert(SocketStreamTest.stream_total_via_reduce() == 10)
      assert(Socket.live_count() == base)
    }

    test("for comprehension consumes Socket.chunks to EOF") {
      base = Socket.live_count()
      assert(SocketStreamTest.stream_count_via_for() == 3)
      assert(Socket.live_count() == base)
    }

    test("Enum.take early-exits; dispose keeps the fd open; a fresh recv resumes") {
      base = Socket.live_count()
      assert(SocketStreamTest.take_then_resume() == :ok)
      assert(Socket.live_count() == base)
    }

    test("Socket.fold halts mid-stream on a protocol terminator") {
      base = Socket.live_count()
      assert(SocketStreamTest.fold_halts_on_terminator() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
