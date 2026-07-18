pub struct TestConcurrency.SocketServerTest {
  use Zest.Case

  # Phase S3 Jobs 2+3 acceptance proof (gate-ON): the ACCEPTOR/HANDLER server
  # pattern — bounded accept (Job 2) + the SocketServer policy module + the
  # canonical echo server under a real Supervisor (Job 3). What this pins, end
  # to end:
  #
  #   * a supervised, TRAPPING acceptor OWNS a loopback listener and loops
  #     `Socket.accept(listener, accept_poll_ms)` — the BOUNDED accept (Job 2);
  #     an infinite accept would never let a trapping acceptor observe a
  #     cooperative `:shutdown`, so the poll deadline is what makes shutdown and
  #     handler-reaping responsive;
  #   * for each accepted connection the acceptor `Process.spawn_link`s a fresh
  #     handler and `Process.send_move`s it the `Socket` (controlling_process —
  #     owner-executed handoff, newly legal in S1/S3); the handler ADOPTS it via
  #     `receive Socket { s -> s }` and echoes on it;
  #   * N clients connect CONCURRENTLY, each round-tripping a DISTINCT payload
  #     through its own handler — all N correct;
  #   * a handler that CRASHES mid-connection (a poison payload) is ISOLATED: the
  #     acceptor traps the EXIT and reaps it (`SocketServer.reap_signals`) instead
  #     of dying, the OTHER concurrent connections keep echoing correctly, the
  #     crashed connection's socket fd is reclaimed by the handler's teardown
  #     sweep, the listener still accepts a fresh connection (same port — the
  #     Supervisor did NOT restart the acceptor), and everything is leak-exact;
  #   * teardown is graceful: `SocketServer.reap_signals` sees the Supervisor's
  #     `:shutdown` (an exit from a non-handler) within one accept poll, the
  #     acceptor closes the listener and exits, and `Socket.live_count` returns to
  #     its baseline — every fd (listener + all connections) reclaimed EXACTLY
  #     ONCE.
  #
  # Blast radius (honest S3 scope): handlers are `spawn_link`ed to the ACCEPTOR,
  # so a HANDLER crash is isolated but an ACCEPTOR crash would kill its linked
  # handlers (fds reclaimed) and be restarted by the tree. The Ranch-style
  # separate connection-supervisor (handlers survive an acceptor restart) needs a
  # dynamic-children supervisor variant and is future work.
  #
  # The kernel-level bounded-accept fd discipline (timeout leaks no fd; a kill
  # mid-bounded-accept reclaims) lives in `src/runtime/concurrency/socket_io.zig`
  # and `.../abi.zig`; the pure `SocketServer` policy is `lib/socket/server.zap`.

  # ---- the supervised acceptor tree ----------------------------------------

  # ServerSup: an ordinary `Supervisor` (one_for_one) whose single `:permanent`
  # worker is the acceptor. A handler crash never reaches HERE (the acceptor
  # traps it), so the Supervisor never restarts the server on a bad connection.
  pub fn server_sup_entry() -> Nil {
    children = [Supervisor.worker(:acceptor)]
    state = Supervisor.init(children, Supervisor.default_options())
    TestConcurrency.SocketServerTest.sup_loop(state)
  }

  pub fn sup_loop(state :: SupervisorState) -> Nil {
    current = Supervisor.step(state)
    case current.action {
      :start -> TestConcurrency.SocketServerTest.sup_loop(Supervisor.installed(current.state, current.child_id, TestConcurrency.SocketServerTest.sup_dispatch(current.child_id)))
      :stop -> Process.exit_with(current.reason)
      _ -> TestConcurrency.SocketServerTest.sup_loop(current.state)
    }
  }

  pub fn sup_dispatch(child_id :: Atom) -> u64 {
    case child_id {
      :acceptor -> Process.spawn_link(&TestConcurrency.SocketServerTest.acceptor_entry/0)
      _ -> Process.spawn_link(&TestConcurrency.SocketServerTest.acceptor_entry/0)
    }
  }

  # The acceptor: bind a listener on an ephemeral port, report the port to the
  # test coordinator by name, TRAP EXITS via `SocketServer.init`, and run the
  # accept loop. It OWNS the listener for its whole life.
  pub fn acceptor_entry() -> Nil {
    case Socket.listen(SocketAddress.loopback(0), 128) {
      Result.Error(_e) -> nil
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          _reported = Process.send(:socket_echo_coordinator, port)
          state = SocketServer.init(SocketServer.options(50, 0, 5000))
          TestConcurrency.SocketServerTest.acceptor_loop(state, listener)
        }
    }
  }

  # One turn: reap dead handlers / observe shutdown, then either drain (close the
  # listener and exit) or accept the next connection.
  fn acceptor_loop(state :: SocketServerState, listener :: SocketListener) -> Nil {
    reaped = SocketServer.reap_signals(state)
    case SocketServer.draining?(reaped) {
      true ->
        {
          # Minimal graceful teardown (the full drain — in-flight grace +
          # straggler kill — is Job 4): stop accepting and exit. Any live handler
          # is `spawn_link`ed to us, so it dies with us and its fd is reclaimed.
          _closed = SocketListener.close(listener)
          Process.exit_with(:shutdown)
        }
      false -> TestConcurrency.SocketServerTest.acceptor_accept(reaped, listener)
    }
  }

  fn acceptor_accept(state :: SocketServerState, listener :: SocketListener) -> Nil {
    case Socket.accept(listener, state.options.accept_poll_ms) {
      # A connection arrived: hand it to a fresh, `spawn_link`ed handler by MOVE
      # (controlling_process). `conn` is CONSUMED by `send_move`.
      Result.Ok(conn) ->
        {
          handler = Process.spawn_link(&TestConcurrency.SocketServerTest.handler_entry/0)
          _moved = Process.send_move((Pid.of(handler) :: Pid(Socket)), conn)
          TestConcurrency.SocketServerTest.acceptor_loop(SocketServer.admitted(state, handler), listener)
        }
      # `:etimedout` on a quiet poll (the common case) — just loop, re-reaping and
      # re-checking for shutdown. Any real accept error is likewise transient here.
      Result.Error(_e) -> TestConcurrency.SocketServerTest.acceptor_loop(state, listener)
    }
  }

  # ---- the per-connection handler ------------------------------------------

  # A handler ADOPTS the moved connection (newly-legal `receive Socket`), then
  # serves it with a bounded-recv echo loop. Handlers do NOT trap — a crash here
  # is an EXIT delivered to the (trapping) acceptor, never a cascade.
  pub fn handler_entry() -> Nil {
    conn = receive Socket {
      s -> s
    }
    TestConcurrency.SocketServerTest.echo_serve(conn)
  }

  # Bounded-recv echo loop with a first-class idle timeout: echo each chunk until
  # the peer closes (EOF), goes idle, or errors — then close the connection. A
  # `"POISON"` payload CRASHES this handler abnormally (`Process.exit_with` — the
  # concurrency suite's process-crash primitive; an unhandled `raise` aborts the
  # runtime rather than delivering a trappable per-process EXIT). The crash
  # leaves the socket unclosed on purpose: its fd is reclaimed by the handler's
  # teardown sweep (crash-safe fd lifetime), NOT an explicit close.
  fn echo_serve(conn :: Socket) -> Nil {
    case Socket.recv(conn, 0, 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == "POISON" {
          true -> Process.exit_with(:poisoned)
          false ->
            {
              _sent = Socket.send(conn, bytes)
              TestConcurrency.SocketServerTest.echo_serve(conn)
            }
        }
      SocketRecv.Closed ->
        {
          _c = Socket.close(conn)
          nil
        }
      SocketRecv.TimedOut(_partial) ->
        {
          _c = Socket.close(conn)
          nil
        }
      SocketRecv.Failed(_error) ->
        {
          _c = Socket.close(conn)
          nil
        }
    }
  }

  # ---- clients (separate processes, connect CONCURRENTLY) ------------------

  # A normal client: connect, round-trip a payload made DISTINCT by its own pid,
  # confirm the echo, then a half-close handshake makes the teardown ORDER
  # deterministic — we signal EOF (shutdown write), wait for the handler's FIN
  # (its close), and only THEN close + report, so by the time the coordinator
  # sees our verdict BOTH connection fds are already closed. Reports `1` on a
  # correct echo, `0` otherwise.
  pub fn normal_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = TestConcurrency.SocketServerTest.normal_client_run(port)
    nil
  }

  fn normal_client_run(port :: i64) -> Atom {
    payload = "echo-" <> Integer.to_string(Process.self())
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:socket_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) -> TestConcurrency.SocketServerTest.normal_client_exchange(client, payload)
    }
  }

  fn normal_client_exchange(client :: Socket, payload :: String) -> Atom {
    _sent = Socket.send(client, payload)
    verdict = case Socket.recv(client, String.length(payload), 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == payload {
          true -> (1 :: i64)
          false -> (0 :: i64)
        }
      SocketRecv.TimedOut(_partial) -> (0 :: i64)
      SocketRecv.Closed -> (0 :: i64)
      SocketRecv.Failed(_error) -> (0 :: i64)
    }
    # Half-close handshake: FIN to the handler, then wait for its FIN back (it
    # closes on our EOF) before we close — so both fds are closed before we report.
    _shut = Socket.shutdown(client, :write)
    _drain = Socket.recv(client, 0, 5000)
    _closed = Socket.close(client)
    _reported = Process.send(:socket_echo_coordinator, verdict)
    :done
  }

  # The poison client: send `"POISON"`, which CRASHES its handler. It must
  # observe the connection DIE (Closed/Failed) — never an echo — proving the
  # crash happened. Reports `1` when the crash was detected (the isolation is
  # then proven by the OTHER clients still succeeding), `0` on an unexpected echo.
  pub fn poison_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = TestConcurrency.SocketServerTest.poison_client_run(port)
    nil
  }

  fn poison_client_run(port :: i64) -> Atom {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:socket_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) ->
        {
          _sent = Socket.send(client, "POISON")
          verdict = case Socket.recv(client, 0, 3000) {
            SocketRecv.Closed -> (1 :: i64)
            SocketRecv.Failed(_error) -> (1 :: i64)
            SocketRecv.Chunk(_bytes) -> (0 :: i64)
            SocketRecv.TimedOut(_partial) -> (0 :: i64)
          }
          _closed = Socket.close(client)
          _reported = Process.send(:socket_echo_coordinator, verdict)
          :done
        }
    }
  }

  # ---- coordinator helpers -------------------------------------------------

  # Spawn `count` normal clients and hand each the port. They connect
  # CONCURRENTLY (all spawned before any completes).
  fn spawn_normals(remaining :: i64, port :: i64) -> Nil {
    case remaining <= 0 {
      true -> nil
      false ->
        {
          client = Process.spawn(&TestConcurrency.SocketServerTest.normal_client_entry/0)
          _sent = Process.send((Pid.of(client) :: Pid(i64)), port)
          TestConcurrency.SocketServerTest.spawn_normals(remaining - 1, port)
        }
    }
  }

  # Collect `remaining` i64 verdicts from clients, summing them. All-correct ⇒
  # the sum equals the client count.
  fn collect_verdicts(remaining :: i64, acc :: i64) -> i64 {
    case remaining <= 0 {
      true -> acc
      false ->
        {
          verdict = receive i64 {
            v -> v
          }
          TestConcurrency.SocketServerTest.collect_verdicts(remaining - 1, acc + verdict)
        }
    }
  }

  # Wait (bounded) until the GLOBAL live socket count reaches `target` — the
  # leak-exact synchronizer. `live_count` only DECREASES as sockets close, so it
  # monotonically settles to `target`; a leak leaves it stuck above (this times
  # out and returns false → the caller's assert fails). Naps via the zero-signal
  # timed wait rather than busy-spinning.
  fn await_live_count(target :: i64, deadline_ms :: i64) -> Bool {
    case Socket.live_count() == target {
      true -> true
      false ->
        case Process.monotonic_millis() >= deadline_ms {
          true -> false
          false ->
            {
              _napped = :zig.ProcessRuntime.await_signal_timeout(5)
              TestConcurrency.SocketServerTest.await_live_count(target, deadline_ms)
            }
        }
    }
  }

  # ---- the exit-gate tests -------------------------------------------------

  describe("Acceptor/handler echo server under a Supervisor (Phase S3)") {
    test("N clients connect concurrently and each round-trips a distinct payload through its handler; leak-exact") {
      _named = Process.register(:socket_echo_coordinator)
      base = Socket.live_count()
      server_sup = Supervisor.start(&TestConcurrency.SocketServerTest.server_sup_entry/0)
      port = receive i64 {
        p -> p
      }
      # The listener is now the one live socket above baseline.
      assert(TestConcurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      client_count = 8
      _spawned = TestConcurrency.SocketServerTest.spawn_normals(client_count, port)
      total = TestConcurrency.SocketServerTest.collect_verdicts(client_count, 0)
      # Every one of the 8 concurrent connections echoed its distinct payload.
      assert(total == client_count)

      # All connection fds reclaimed; only the listener remains.
      assert(TestConcurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # Graceful teardown: the acceptor sees the Supervisor's `:shutdown` within
      # one accept poll, closes the listener, and exits.
      _mon = Process.monitor(server_sup)
      _shutdown = Process.exit_signal(server_sup, :shutdown)
      _down = Process.await_signal()
      assert(TestConcurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }

    test("a handler crash is ISOLATED: other connections keep echoing, the listener still accepts, no server restart; leak-exact") {
      _named = Process.register(:socket_echo_coordinator)
      base = Socket.live_count()
      server_sup = Supervisor.start(&TestConcurrency.SocketServerTest.server_sup_entry/0)
      port = receive i64 {
        p -> p
      }
      assert(TestConcurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # 1 poison connection + 7 normal ones, all connecting CONCURRENTLY. If the
      # crash propagated to the acceptor, its linked handlers would die and those
      # clients would fail — so all-8-succeed IS the isolation proof.
      _poison = TestConcurrency.SocketServerTest.spawn_poison(port)
      normal_count = 7
      _spawned = TestConcurrency.SocketServerTest.spawn_normals(normal_count, port)
      # 8 verdicts: 7 correct echoes + 1 detected crash = 8.
      total = TestConcurrency.SocketServerTest.collect_verdicts(normal_count + 1, 0)
      assert(total == normal_count + 1)

      # After the crash, a FRESH connection to the ORIGINAL port must be served —
      # proving the acceptor survived AND the Supervisor did NOT restart it (a
      # restart would rebind to a different ephemeral port, refusing this connect).
      _fresh = TestConcurrency.SocketServerTest.spawn_normals(1, port)
      fresh_total = TestConcurrency.SocketServerTest.collect_verdicts(1, 0)
      assert(fresh_total == 1)

      # Every connection's sockets reclaimed EXACTLY ONCE (the crashed one via its
      # teardown sweep, the rest via explicit close); only the listener remains.
      assert(TestConcurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      _mon = Process.monitor(server_sup)
      _shutdown = Process.exit_signal(server_sup, :shutdown)
      _down = Process.await_signal()
      assert(TestConcurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }
  }

  # Spawn the single poison client and hand it the port.
  fn spawn_poison(port :: i64) -> Nil {
    poison = Process.spawn(&TestConcurrency.SocketServerTest.poison_client_entry/0)
    _sent = Process.send((Pid.of(poison) :: Pid(i64)), port)
    nil
  }
}
