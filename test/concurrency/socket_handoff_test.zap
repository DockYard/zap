pub struct Concurrency.SocketHandoffTest {
  use Zest.Case

  # Phase S3 Job 1 acceptance proof (gate-ON): CROSS-PROCESS SOCKET HANDLE
  # TRANSFER at the Zap surface — the load-bearing prerequisite for the server
  # phase. What this pins, end to end:
  #
  #   * a green process sets up a connected loopback pair and `send_move`s the
  #     ACCEPTED server socket to a child process. The move CONSUMES the handle
  #     (a use after it is a compile error — the exactly-one-owner tooth, pinned
  #     as a compile-fail fixture in `src/zir_integration_tests.zig`);
  #   * the child ADOPTS the socket through the newly-legal `receive Socket`
  #     scrutinee (Phase S3 admits the move-only handle as a top-level receive
  #     type), then USES it — reads a chunk and echoes it straight back on the
  #     SAME fd — proving ownership re-parented across the process boundary;
  #   * the child closes the adopted socket and exits; the parent drives the
  #     echo through its own end of the connection and confirms the bytes made
  #     the full round trip THROUGH the handed-off socket;
  #   * `Socket.live_count` returns to its baseline — the fd was closed EXACTLY
  #     ONCE across the two processes (no leak, no double-close), the socket
  #     tier's leak-exactness oracle.
  #
  # The kernel-level crash matrix for the same handoff (dead-letter undo,
  # receiver-teardown drain, sender-death survival) lives in
  # `src/runtime/concurrency/abi.zig`; the domain handoff state machine's unit
  # proofs live in `src/runtime/concurrency/socket_table.zig`.

  describe("Socket cross-process handoff (send_move, Phase S3)") {
    test("send_move hands a connected socket to a child; the child echoes on it and closes; leak-exact") {
      base = Socket.live_count()
      assert(Concurrency.SocketHandoffTest.handoff_echo() == :ok)
      assert(Socket.live_count() == base)
    }
  }

  fn handoff_echo() -> Atom {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> Concurrency.SocketHandoffTest.after_listen(listener)
    }
  }

  fn after_listen(listener :: Socket.Listener) -> Atom {
    port = Socket.Listener.local_port(listener)
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = Socket.Listener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketHandoffTest.after_connect(listener, client)
    }
  }

  fn after_connect(listener :: Socket.Listener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> Concurrency.SocketHandoffTest.hand_off(listener, client, server)
    }
  }

  fn hand_off(listener :: Socket.Listener, client :: Socket, server :: Socket) -> Atom {
    child = Process.spawn(&Concurrency.SocketHandoffTest.echo_child_entry/0)
    _monitor_ref = Process.monitor(child)
    # Hand the ACCEPTED server socket to the child. `server` is CONSUMED here —
    # a use after this move is a compile error (the S3 exactly-one-owner tooth).
    _moved = Process.send_move((Pid.of(child) :: Pid(Socket)), server)

    # Drive the echo through OUR end (`client`): the child now owns `server`,
    # reads these bytes off it, and writes them straight back.
    _sent = Socket.send(client, "handoff-echo")
    echoed = case Socket.recv(client, 12, 5000) {
      Socket.Recv.Chunk(bytes) -> bytes
      Socket.Recv.TimedOut(_partial) -> "!timeout"
      Socket.Recv.Closed -> "!eof"
      Socket.Recv.Failed(_e) -> "!failed"
    }

    # Wait for the child to be FULLY dead (its socket-sweep has run) before the
    # caller checks the leak baseline.
    _down = Process.await_signal()

    _cc = Socket.close(client)
    _lc = Socket.Listener.close(listener)
    case echoed == "handoff-echo" {
      true -> :ok
      false -> :mismatch
    }
  }

  # The child: ADOPT the handed-off socket through the newly-legal `receive
  # Socket` scrutinee, echo one chunk back on it, then close it.
  pub fn echo_child_entry() -> Nil {
    conn = receive Socket {
      s -> s
    }
    _echoed = case Socket.recv(conn, 12, 5000) {
      Socket.Recv.Chunk(bytes) ->
        {
          _s = Socket.send(conn, bytes)
          :echoed
        }
      Socket.Recv.TimedOut(_partial) -> :no_echo
      Socket.Recv.Closed -> :no_echo
      Socket.Recv.Failed(_e) -> :no_echo
    }
    _closed = Socket.close(conn)
    nil
  }
}
