pub struct Concurrency.SocketServerTest {
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
    Concurrency.SocketServerTest.sup_loop(state)
  }

  pub fn sup_loop(state :: SupervisorState) -> Nil {
    current = Supervisor.step(state)
    case current.action {
      :start -> Concurrency.SocketServerTest.sup_loop(Supervisor.installed(current.state, current.child_id, Concurrency.SocketServerTest.sup_dispatch(current.child_id)))
      :stop -> Process.exit_with(current.reason)
      _ -> Concurrency.SocketServerTest.sup_loop(current.state)
    }
  }

  pub fn sup_dispatch(child_id :: Atom) -> u64 {
    case child_id {
      :acceptor -> Process.spawn_link(&Concurrency.SocketServerTest.acceptor_entry/0)
      _ -> Process.spawn_link(&Concurrency.SocketServerTest.acceptor_entry/0)
    }
  }

  # The acceptor: bind a listener on an ephemeral port, report the port to the
  # test coordinator by name, TRAP EXITS via `SocketServer.init`, and run the
  # accept loop. It OWNS the listener for its whole life. The echo/crash tests
  # use the default policy (50 ms poll, NO connection cap, 5 s drain grace).
  pub fn acceptor_entry() -> Nil {
    Concurrency.SocketServerTest.acceptor_boot(SocketServer.options(50, 0, 5000))
  }

  # The DRAIN acceptor (Job 4): the same loop, but a SHORT 1200 ms drain grace so
  # the graceful-drain test can measure a stalling handler being force-killed at
  # the deadline without waiting five seconds. No connection cap.
  pub fn drain_acceptor_entry() -> Nil {
    Concurrency.SocketServerTest.acceptor_boot(SocketServer.options(50, 0, 1200))
  }

  # The CAPACITY acceptor (Job 5): a per-acceptor `max_connections` cap of 2, so
  # the load-shedding test can prove the acceptor STOPS ACCEPTING at the cap and
  # resumes when a slot frees. Default 5 s drain grace.
  pub fn capacity_acceptor_entry() -> Nil {
    Concurrency.SocketServerTest.acceptor_boot(SocketServer.options(50, 2, 5000))
  }

  # Shared acceptor boot: bind an ephemeral loopback listener, report the port to
  # the coordinator, TRAP EXITS via `SocketServer.init(options)`, and run the
  # shared accept loop under the given policy. The ONLY thing that differs
  # between the echo, drain, and capacity acceptors is their `SocketServerOptions`.
  fn acceptor_boot(options :: SocketServerOptions) -> Nil {
    case Socket.listen(SocketAddress.loopback(0), 128) {
      Result.Error(_e) -> nil
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          _reported = Process.send(:socket_echo_coordinator, port)
          state = SocketServer.init(options)
          Concurrency.SocketServerTest.acceptor_loop(state, listener)
        }
    }
  }

  # One turn: reap dead handlers / observe shutdown, then either DRAIN (Job 4) or
  # accept the next connection (subject to the Job 5 capacity gate).
  #
  # This is deliberately a SINGLE self-recursive function: every "keep serving"
  # step is a tail call to `acceptor_loop` ITSELF, so the compiler's
  # self-recursion TCO loopifies it into a CONSTANT-STACK loop. Splitting it into
  # two mutually-recursive functions (an `acceptor_loop` ⇄ `acceptor_accept`
  # pair) would NOT be tail-call-optimized — the compiler only rewrites a tail
  # call to the SAME function; a tail call to a DIFFERENT function stays an
  # ordinary `call + ret` and grows one fiber-stack frame per accept, so a
  # long-lived acceptor would OVERFLOW its 256 KiB stack at high connection
  # counts (a latent DoS). Keeping the whole turn in one self-recursive function
  # is what makes the accept loop safe for an unbounded connection lifetime.
  fn acceptor_loop(state :: SocketServerState, listener :: SocketListener) -> Nil {
    reaped = SocketServer.reap_signals(state)
    case SocketServer.draining?(reaped) {
      true ->
        {
          # Graceful drain (Job 4): close the listener IMMEDIATELY so new connects
          # get ECONNREFUSED, then give the in-flight handlers up to
          # `shutdown_timeout_ms` to finish (`SocketServer.drain`) and force-kill
          # any stragglers so every connection fd is reclaimed before we exit.
          _closed = SocketListener.close(listener)
          _drained = SocketServer.drain(reaped)
          Process.exit_with(:normal)
        }
      false ->
        # Capacity gate (Job 5): at the `max_connections` cap, STOP ACCEPTING —
        # park (kill/drain-responsive) until a handler EXIT frees a slot, then
        # re-loop. The kernel backlog absorbs the wait; nothing is accepted-then-reset.
        case SocketServer.at_capacity?(reaped) {
          true -> Concurrency.SocketServerTest.acceptor_loop(SocketServer.wait_for_slot(reaped), listener)
          false ->
            case Socket.accept(listener, reaped.options.accept_poll_ms) {
              # A connection arrived: hand it to a fresh, `spawn_link`ed handler by
              # MOVE (controlling_process). `conn` is CONSUMED by `send_move`.
              Result.Ok(conn) ->
                {
                  handler = Process.spawn_link(&Concurrency.SocketServerTest.handler_entry/0)
                  _moved = Process.send_move((Pid.of(handler) :: Pid(Socket)), conn)
                  Concurrency.SocketServerTest.acceptor_loop(SocketServer.admitted(reaped, handler), listener)
                }
              # `:etimedout` on a quiet poll (the common case) — just loop, re-reaping
              # and re-checking for shutdown. Any real accept error is transient here.
              Result.Error(_e) -> Concurrency.SocketServerTest.acceptor_loop(reaped, listener)
            }
        }
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
    Concurrency.SocketServerTest.echo_serve(conn)
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
              Concurrency.SocketServerTest.echo_serve(conn)
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
    _result = Concurrency.SocketServerTest.normal_client_run(port)
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
      Result.Ok(client) -> Concurrency.SocketServerTest.normal_client_exchange(client, payload)
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
    _result = Concurrency.SocketServerTest.poison_client_run(port)
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

  # ---- drain clients (Job 4) -----------------------------------------------

  # The FINISHER: an in-flight connection that must be allowed to COMPLETE during
  # a drain. It connects, echoes once (proving its handler is live), reports
  # ready, then PARKS for a `go` message the test sends AFTER it triggers the
  # drain — and only THEN does a SECOND echo + graceful half-close. That second
  # echo succeeding proves the draining acceptor keeps serving live connections
  # (it does NOT cut them off); the clean close lets its handler exit `:normal`
  # and be REAPED by the drain grace (never force-killed).
  pub fn finisher_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = Concurrency.SocketServerTest.finisher_client_run(port)
    nil
  }

  fn finisher_client_run(port :: i64) -> Atom {
    payload = "fin-" <> Integer.to_string(Process.self())
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:socket_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketServerTest.finisher_exchange(client, payload)
    }
  }

  fn finisher_exchange(client :: Socket, payload :: String) -> Atom {
    _sent1 = Socket.send(client, payload)
    ready = Concurrency.SocketServerTest.echo_verdict(client, payload)
    _ready_reported = Process.send(:socket_echo_coordinator, ready)
    # Wait for the test's `go` — sent AFTER the drain is triggered.
    _go = receive i64 {
      g -> g
    }
    # The during-drain second exchange: still served because the acceptor lets
    # live handlers finish.
    _sent2 = Socket.send(client, payload)
    final = Concurrency.SocketServerTest.echo_verdict(client, payload)
    # Graceful half-close so the handler sees EOF and exits cleanly (reaped, not
    # force-killed).
    _shut = Socket.shutdown(client, :write)
    _drain = Socket.recv(client, 0, 5000)
    _closed = Socket.close(client)
    _final_reported = Process.send(:socket_echo_coordinator, final)
    :done
  }

  # The STRAGGLER: a connection whose handler NEVER finishes within the drain
  # grace. It connects, echoes once (proving its handler is live), reports ready,
  # then HOLDS — never sends again, never half-closes — so its handler parks in
  # `recv` past the drain deadline and must be FORCE-KILLED. When the drain kills
  # the handler, the reset/FIN wakes this parked `recv`; the client then closes,
  # so its fd is reclaimed too (leak-exact). Reports NO final verdict — its
  # teardown is observed through `Socket.live_count`.
  pub fn straggler_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = Concurrency.SocketServerTest.straggler_client_run(port)
    nil
  }

  fn straggler_client_run(port :: i64) -> Atom {
    payload = "str-" <> Integer.to_string(Process.self())
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:socket_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketServerTest.straggler_hold(client, payload)
    }
  }

  fn straggler_hold(client :: Socket, payload :: String) -> Atom {
    _sent = Socket.send(client, payload)
    ready = Concurrency.SocketServerTest.echo_verdict(client, payload)
    _ready_reported = Process.send(:socket_echo_coordinator, ready)
    # HOLD: park reading until the drain force-kills the handler (which resets or
    # FINs the connection), then close.
    _drain = Socket.recv(client, 0, 10000)
    _closed = Socket.close(client)
    :done
  }

  # ---- capacity clients (Job 5) --------------------------------------------

  # A HELD client: connect, echo once (proving it was served), report ready, then
  # HOLD the connection open until the test sends a release message — occupying a
  # `max_connections` slot for as long as the test needs. On release it does a
  # graceful half-close (freeing its slot) and reports a final verdict.
  pub fn held_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = Concurrency.SocketServerTest.held_client_run(port)
    nil
  }

  fn held_client_run(port :: i64) -> Atom {
    payload = "held-" <> Integer.to_string(Process.self())
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:socket_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketServerTest.held_serve(client, payload)
    }
  }

  fn held_serve(client :: Socket, payload :: String) -> Atom {
    _sent = Socket.send(client, payload)
    ready = Concurrency.SocketServerTest.echo_verdict(client, payload)
    _ready_reported = Process.send(:socket_echo_coordinator, ready)
    # HOLD open (occupying a slot) until the test releases us.
    _release = receive i64 {
      r -> r
    }
    _shut = Socket.shutdown(client, :write)
    _drain = Socket.recv(client, 0, 5000)
    _closed = Socket.close(client)
    _final_reported = Process.send(:socket_echo_coordinator, (1 :: i64))
    :done
  }

  # The EXTRA client: the `(cap + 1)`th connection, offered while the server is at
  # capacity. The kernel backlog completes its TCP handshake, but the acceptor
  # STOPS ACCEPTING at the cap, so no handler serves it — its first `recv` MUST
  # time out (queued, not served). It reports that (phase A), then RETRIES until a
  # slot frees and its buffered payload is finally echoed (phase B), reporting
  # `served`.
  pub fn extra_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = Concurrency.SocketServerTest.extra_client_run(port)
    nil
  }

  fn extra_client_run(port :: i64) -> Atom {
    payload = "extra-" <> Integer.to_string(Process.self())
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _r1 = Process.send(:socket_echo_coordinator, (0 :: i64))
          _r2 = Process.send(:socket_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) -> Concurrency.SocketServerTest.extra_probe(client, payload)
    }
  }

  fn extra_probe(client :: Socket, payload :: String) -> Atom {
    _sent = Socket.send(client, payload)
    # Phase A: at capacity nobody serves us — the first recv MUST time out.
    unserved = case Socket.recv(client, 0, 700) {
      SocketRecv.TimedOut(_p) -> (1 :: i64)
      SocketRecv.Chunk(_b) -> (0 :: i64)
      SocketRecv.Closed -> (0 :: i64)
      SocketRecv.Failed(_e) -> (0 :: i64)
    }
    _unserved_reported = Process.send(:socket_echo_coordinator, unserved)
    # Phase B: once a slot frees, the acceptor accepts us and the handler echoes
    # our buffered payload — retry until served (or a generous deadline).
    served = Concurrency.SocketServerTest.extra_retry(client, payload, Process.monotonic_millis() + 5000)
    _served_reported = Process.send(:socket_echo_coordinator, served)
    _shut = Socket.shutdown(client, :write)
    _drain = Socket.recv(client, 0, 5000)
    _closed = Socket.close(client)
    :done
  }

  fn extra_retry(client :: Socket, payload :: String, deadline_ms :: i64) -> i64 {
    case Process.monotonic_millis() >= deadline_ms {
      true -> (0 :: i64)
      false ->
        case Socket.recv(client, 0, 300) {
          SocketRecv.Chunk(bytes) ->
            case bytes == payload {
              true -> (1 :: i64)
              false -> (0 :: i64)
            }
          SocketRecv.TimedOut(_p) -> Concurrency.SocketServerTest.extra_retry(client, payload, deadline_ms)
          SocketRecv.Closed -> (0 :: i64)
          SocketRecv.Failed(_e) -> (0 :: i64)
        }
    }
  }

  # Shared: read one echo and return `1` iff it matches `payload`, else `0`.
  fn echo_verdict(client :: Socket, payload :: String) -> i64 {
    case Socket.recv(client, String.length(payload), 5000) {
      SocketRecv.Chunk(bytes) ->
        case bytes == payload {
          true -> (1 :: i64)
          false -> (0 :: i64)
        }
      SocketRecv.TimedOut(_p) -> (0 :: i64)
      SocketRecv.Closed -> (0 :: i64)
      SocketRecv.Failed(_e) -> (0 :: i64)
    }
  }

  # ---- single-acceptor high-count stress (constant-stack accept loop) -------
  #
  # Driving ONE acceptor through a high SEQUENTIAL connection count forces its
  # accept loop to iterate thousands of times. If that loop is NOT constant-stack
  # — e.g. the mutually recursive `acceptor_loop` ⇄ `acceptor_accept`, which the
  # compiler does NOT tail-call-optimize (only SELF-recursion loopifies to a
  # constant-stack loop; a tail call to a DIFFERENT function stays `call + ret`
  # and grows a frame) — each accept grows the acceptor's 256 KiB fiber stack one
  # frame and it eventually OVERFLOWS (guard-page bus_error): a latent DoS a
  # long-lived server hits at scale. A single self-recursive `acceptor_loop` is
  # loopified to a constant-stack loop, so every connection is served no matter
  # how many.

  # Sequentially open `remaining` connections to ONE acceptor's `port`, one at a
  # time, summing the per-connection echo verdicts (all-served ⇒ sum == count).
  fn stress_serial(port :: i64, remaining :: i64, acc :: i64) -> i64 {
    case remaining <= 0 {
      true -> acc
      false ->
        {
          verdict = Concurrency.SocketServerTest.stress_one(port)
          Concurrency.SocketServerTest.stress_serial(port, remaining - 1, acc + verdict)
        }
    }
  }

  # One stress connection: connect, echo a 1-byte payload, then a graceful
  # half-close so the handler sees EOF, exits cleanly, and is reaped by the
  # acceptor (the live set stays bounded across the whole run). Returns `1` on a
  # correct echo, `0` otherwise.
  fn stress_one(port :: i64) -> i64 {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) -> (0 :: i64)
      Result.Ok(client) ->
        {
          _sent = Socket.send(client, "s")
          verdict = case Socket.recv(client, 1, 5000) {
            SocketRecv.Chunk(bytes) ->
              case bytes == "s" {
                true -> (1 :: i64)
                false -> (0 :: i64)
              }
            SocketRecv.TimedOut(_p) -> (0 :: i64)
            SocketRecv.Closed -> (0 :: i64)
            SocketRecv.Failed(_e) -> (0 :: i64)
          }
          _shut = Socket.shutdown(client, :write)
          _drain = Socket.recv(client, 0, 5000)
          _closed = Socket.close(client)
          verdict
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
          client = Process.spawn(&Concurrency.SocketServerTest.normal_client_entry/0)
          _sent = Process.send((Pid.of(client) :: Pid(i64)), port)
          Concurrency.SocketServerTest.spawn_normals(remaining - 1, port)
        }
    }
  }

  # Spawn `count` HELD clients, hand each the port, and return their pids so the
  # test can RELEASE them one at a time to free `max_connections` slots.
  fn spawn_held(remaining :: i64, port :: i64, collected :: List(u64)) -> List(u64) {
    case remaining <= 0 {
      true -> collected
      false ->
        {
          held = Process.spawn(&Concurrency.SocketServerTest.held_client_entry/0)
          _sent = Process.send((Pid.of(held) :: Pid(i64)), port)
          Concurrency.SocketServerTest.spawn_held(remaining - 1, port, List.push(collected, held))
        }
    }
  }

  # Release the held clients `pids[index, total)` (each frees its slot with a
  # graceful half-close).
  fn release_rest(pids :: List(u64), index :: i64, total :: i64) -> Nil {
    case index < total {
      true ->
        {
          _r = Process.send((Pid.of(List.at(pids, index)) :: Pid(i64)), (1 :: i64))
          Concurrency.SocketServerTest.release_rest(pids, index + 1, total)
        }
      false -> nil
    }
  }

  # Collect `remaining` i64 verdicts from clients, summing them. All-correct ⇒
  # the sum equals the client count. BOUNDED: each verdict wait is capped
  # (`after 15000`), so a client that never reports — a coordination bug or a
  # real serving stall — makes the collection return a PARTIAL sum the caller's
  # `assert(total == count)` rejects FAST (a clear "only K of N served" failure),
  # instead of the whole test parking forever. Verdicts are always `0`/`1`, so
  # `-1` is an unambiguous timeout sentinel.
  fn collect_verdicts(remaining :: i64, acc :: i64) -> i64 {
    case remaining <= 0 {
      true -> acc
      false ->
        {
          verdict = receive i64 {
            v -> v
            after 15000 -> (-1 :: i64)
          }
          case verdict < 0 {
            true -> acc
            false -> Concurrency.SocketServerTest.collect_verdicts(remaining - 1, acc + verdict)
          }
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
              Concurrency.SocketServerTest.await_live_count(target, deadline_ms)
            }
        }
    }
  }

  # ---- the exit-gate tests -------------------------------------------------

  describe("Acceptor/handler echo server under a Supervisor (Phase S3)") {
    test("N clients connect concurrently and each round-trips a distinct payload through its handler; leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      server_sup = Supervisor.start(&Concurrency.SocketServerTest.server_sup_entry/0)
      port = receive i64 {
        p -> p
      }
      # The listener is now the one live socket above baseline.
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      client_count = 8
      _spawned = Concurrency.SocketServerTest.spawn_normals(client_count, port)
      total = Concurrency.SocketServerTest.collect_verdicts(client_count, 0)
      # Every one of the 8 concurrent connections echoed its distinct payload.
      assert(total == client_count)

      # All connection fds reclaimed; only the listener remains.
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # Graceful teardown: the acceptor sees the Supervisor's `:shutdown` within
      # one accept poll, closes the listener, and exits.
      _mon = Process.monitor(server_sup)
      _shutdown = Process.exit_signal(server_sup, :shutdown)
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }

    test("a handler crash is ISOLATED: other connections keep echoing, the listener still accepts, no server restart; leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      server_sup = Supervisor.start(&Concurrency.SocketServerTest.server_sup_entry/0)
      port = receive i64 {
        p -> p
      }
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # 1 poison connection + 7 normal ones, all connecting CONCURRENTLY. If the
      # crash propagated to the acceptor, its linked handlers would die and those
      # clients would fail — so all-8-succeed IS the isolation proof.
      _poison = Concurrency.SocketServerTest.spawn_poison(port)
      normal_count = 7
      _spawned = Concurrency.SocketServerTest.spawn_normals(normal_count, port)
      # 8 verdicts: 7 correct echoes + 1 detected crash = 8.
      total = Concurrency.SocketServerTest.collect_verdicts(normal_count + 1, 0)
      assert(total == normal_count + 1)

      # After the crash, a FRESH connection to the ORIGINAL port must be served —
      # proving the acceptor survived AND the Supervisor did NOT restart it (a
      # restart would rebind to a different ephemeral port, refusing this connect).
      _fresh = Concurrency.SocketServerTest.spawn_normals(1, port)
      fresh_total = Concurrency.SocketServerTest.collect_verdicts(1, 0)
      assert(fresh_total == 1)

      # Every connection's sockets reclaimed EXACTLY ONCE (the crashed one via its
      # teardown sweep, the rest via explicit close); only the listener remains.
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      _mon = Process.monitor(server_sup)
      _shutdown = Process.exit_signal(server_sup, :shutdown)
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }
  }

  describe("Single-acceptor high connection count (constant-stack accept loop, Phase S3)") {
    test("one acceptor serves a HIGH sequential connection count without overflowing its fiber stack (self-recursive accept loop is constant-stack); leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      acceptor = Process.spawn(&Concurrency.SocketServerTest.acceptor_entry/0)
      _mon = Process.monitor(acceptor)
      port = receive i64 {
        p -> p
      }
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # Drive the ONE acceptor through a high sequential connection count. PRE-fix
      # the acceptor loop was mutually recursive (`acceptor_loop` ⇄
      # `acceptor_accept`) — NOT tail-call-optimized, so it grew the 256 KiB fiber
      # stack one frame per accept and OVERFLOWED here (a latent DoS at scale).
      # POST-fix the loop is a single self-recursive function → constant stack, so
      # every connection is served regardless of count.
      connection_count = 1500
      served = Concurrency.SocketServerTest.stress_serial(port, connection_count, 0)
      assert(served == connection_count)

      # Every connection fd reclaimed; only the listener remains.
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # Graceful shutdown: the acceptor drains its (empty) live set and exits;
      # every fd (the listener) reclaimed EXACTLY once.
      _shutdown = Process.exit_signal(acceptor, :shutdown)
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }
  }

  describe("Graceful drain (Phase S3, Job 4)") {
    test("a drain closes the listener (new connects refused), lets an in-flight connection finish, and force-kills a stalling handler after the grace; leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      grace = 1200
      acceptor = Process.spawn(&Concurrency.SocketServerTest.drain_acceptor_entry/0)
      _mon = Process.monitor(acceptor)
      port = receive i64 {
        p -> p
      }
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # One FINISHER (must complete DURING the drain) + one STRAGGLER (parks; must
      # be force-killed at the grace deadline). Both connect, echo once, report
      # ready, then hold.
      finisher = Process.spawn(&Concurrency.SocketServerTest.finisher_client_entry/0)
      _fp = Process.send((Pid.of(finisher) :: Pid(i64)), port)
      straggler = Process.spawn(&Concurrency.SocketServerTest.straggler_client_entry/0)
      _sp = Process.send((Pid.of(straggler) :: Pid(i64)), port)
      ready = Concurrency.SocketServerTest.collect_verdicts(2, 0)
      assert(ready == 2)
      # Steady state: listener + 2 handlers + 2 clients.
      assert(Concurrency.SocketServerTest.await_live_count(base + 5, Process.monotonic_millis() + 5000))

      # Trigger the drain (a `:shutdown` from this NON-child process) and time it.
      started = Process.monotonic_millis()
      _shutdown = Process.exit_signal(acceptor, :shutdown)
      # Release the finisher: its during-drain second echo must STILL succeed,
      # proving the draining acceptor keeps serving live connections.
      _go = Process.send((Pid.of(finisher) :: Pid(i64)), (1 :: i64))
      finisher_done = Concurrency.SocketServerTest.collect_verdicts(1, 0)
      assert(finisher_done == 1)

      # The straggler's handler never finishes → force-killed at the grace. Wait
      # for the acceptor to finish draining and exit, then confirm every fd
      # (listener + both handlers + both clients) is reclaimed EXACTLY ONCE.
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      elapsed = Process.monotonic_millis() - started
      # The straggler is killed no earlier than the grace after the drain began.
      assert(elapsed >= grace)
      assert(elapsed < grace + 3000)
      assert(Socket.live_count() == base)

      # The listener was closed on drain: a fresh connect to the port is REFUSED.
      refused = case Socket.connect(SocketAddress.loopback(port), 500) {
        Result.Error(_e) -> (1 :: i64)
        Result.Ok(late) ->
          {
            _c = Socket.close(late)
            (0 :: i64)
          }
      }
      assert(refused == 1)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }
  }

  describe("max_connections load-shedding (Phase S3, Job 5)") {
    test("at capacity the acceptor STOPS ACCEPTING (a new connection is queued-not-served), a freed slot IS served, and served concurrency never exceeds the cap; leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      cap = 2
      acceptor = Process.spawn(&Concurrency.SocketServerTest.capacity_acceptor_entry/0)
      _mon = Process.monitor(acceptor)
      port = receive i64 {
        p -> p
      }
      assert(Concurrency.SocketServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # Fill the cap: `cap` HELD connections, each echoes once then holds open.
      held = Concurrency.SocketServerTest.spawn_held(cap, port, (List.new_empty(cap) :: List(u64)))
      ready = Concurrency.SocketServerTest.collect_verdicts(cap, 0)
      assert(ready == cap)
      # Steady state AT capacity: listener + cap handlers + cap held clients.
      assert(Concurrency.SocketServerTest.await_live_count(base + 1 + 2 * cap, Process.monotonic_millis() + 5000))

      # An EXTRA connection while at capacity: the kernel backlog completes its
      # handshake, but the acceptor STOPS ACCEPTING at the cap, so nobody serves
      # it — its first recv must TIME OUT (queued, not served).
      extra = Process.spawn(&Concurrency.SocketServerTest.extra_client_entry/0)
      _ep = Process.send((Pid.of(extra) :: Pid(i64)), port)
      unserved = Concurrency.SocketServerTest.collect_verdicts(1, 0)
      assert(unserved == 1)
      # Served concurrency is EXACTLY the cap: listener + cap handlers + cap held
      # clients + 1 extra CLIENT socket (its server side was never accepted, so it
      # holds no handle and does not count). More than cap handlers here would
      # break this equality.
      assert(Socket.live_count() == base + 2 + 2 * cap)

      # Free ONE slot: release a held connection. The freed slot lets the acceptor
      # accept the queued extra and echo its buffered payload.
      _released = Process.send((Pid.of(List.at(held, 0)) :: Pid(i64)), (1 :: i64))
      # Two verdicts (order-free): the released held's clean teardown + the extra
      # finally served.
      slot_freed = Concurrency.SocketServerTest.collect_verdicts(2, 0)
      assert(slot_freed == 2)

      # Teardown: release the remaining held connections, collect their finals,
      # then shut the acceptor down and confirm leak-exactness.
      _rest = Concurrency.SocketServerTest.release_rest(held, 1, List.length(held))
      rest_finals = Concurrency.SocketServerTest.collect_verdicts(cap - 1, 0)
      assert(rest_finals == cap - 1)

      _shutdown = Process.exit_signal(acceptor, :shutdown)
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }
  }

  describe("SO_REUSEPORT acceptor pool (Phase S3, Job 6)") {
    test("two reuse_port listeners bind the SAME port (multi-bind probe) and per_acceptor_cap splits the max/N quota") {
      base = Socket.live_count()
      # Multi-bind probe: a FIRST reuse_port listener on an ephemeral port, then a
      # SECOND reuse_port listener on that SAME port — both bind simultaneously
      # because `SO_REUSEPORT` permits it. This confirms the multi-bind actually
      # works on THIS host: on Linux the kernel hash-balances connections across
      # such listeners; on Darwin the multi-bind succeeds but distribution favors
      # the newest listener. CORRECTNESS (every connection served, drain,
      # crash-safety) holds on BOTH — only BALANCE is Linux-grade — so the pool
      # tests below assert TOTALS, never per-acceptor distribution.
      probe = case Socket.listen(SocketAddress.loopback(0), 128, %SocketOptions{reuse_port: true}) {
        Result.Error(_e) -> (0 :: i64)
        Result.Ok(first) ->
          {
            shared_port = SocketListener.local_port(first)
            result = case Socket.listen(SocketAddress.loopback(shared_port), 128, %SocketOptions{reuse_port: true}) {
              Result.Error(_e2) -> (0 :: i64)
              Result.Ok(second) ->
                {
                  # Both listeners are bound to the SAME port at the same instant.
                  same = case SocketListener.local_port(second) == shared_port {
                    true -> (1 :: i64)
                    false -> (0 :: i64)
                  }
                  _c2 = SocketListener.close(second)
                  same
                }
            }
            _c1 = SocketListener.close(first)
            result
          }
      }
      assert(probe == 1)
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))

      # `per_acceptor_cap` is the Job 6 per-acceptor `max_connections` quota
      # (`max / N`) each pooled acceptor is given so the pool's aggregate served
      # concurrency stays near a global budget WITHOUT cross-acceptor coordination.
      assert(SocketServer.per_acceptor_cap(9, 3) == 3)
      assert(SocketServer.per_acceptor_cap(10, 3) == 3)
      assert(SocketServer.per_acceptor_cap(2, 4) == 1)
      assert(SocketServer.per_acceptor_cap(0, 4) == 0)
      assert(SocketServer.per_acceptor_cap(7, 0) == 7)
    }

    test("N reuse_port acceptors on ONE port each own a listener; M clients spread across the pool are ALL served (totals); leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      pool_size = 3
      sup = Process.spawn(&Concurrency.SocketServerTest.pool_sup_entry/0)
      # The first acceptor bound an ephemeral port with reuse_port and reported it;
      # hand that port back to the supervisor so it binds the REST of the pool to it.
      port = receive i64 {
        p -> p
      }
      _tellsup = Process.send((Pid.of(sup) :: Pid(i64)), port)
      # Every one of the N reuse_port listeners is now binding the SAME port; wait
      # until all are up (N live listeners above baseline). This proves the
      # multi-bind pool actually stands up end to end.
      assert(Concurrency.SocketServerTest.await_live_count(base + pool_size, Process.monotonic_millis() + 5000))

      # M clients all connect to the ONE shared port and each round-trips a DISTINCT
      # payload through whichever acceptor's handler got it.
      client_count = 9
      _spawned = Concurrency.SocketServerTest.spawn_normals(client_count, port)
      total = Concurrency.SocketServerTest.collect_verdicts(client_count, 0)
      # All M served. WHICH acceptor served each is platform-dependent (Linux
      # balances, Darwin may favor the newest), so we assert the TOTAL only.
      assert(total == client_count)

      # All connection fds reclaimed; only the N listeners remain.
      assert(Concurrency.SocketServerTest.await_live_count(base + pool_size, Process.monotonic_millis() + 5000))

      # Pool drain: shut the pool supervisor down; it drives EVERY acceptor's own
      # Job-4 drain (each closes its own listener), then exits.
      _mon = Process.monitor(sup)
      _shutdown = Process.exit_signal(sup, :shutdown)
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }

    test("a pool drain closes EVERY acceptor's listener (new connects refused) while an in-flight connection still finishes; leak-exact") {
      assert(Process.register(:socket_echo_coordinator))
      base = Socket.live_count()
      pool_size = 3
      sup = Process.spawn(&Concurrency.SocketServerTest.pool_sup_entry/0)
      port = receive i64 {
        p -> p
      }
      _tellsup = Process.send((Pid.of(sup) :: Pid(i64)), port)
      assert(Concurrency.SocketServerTest.await_live_count(base + pool_size, Process.monotonic_millis() + 5000))

      # One in-flight FINISHER lands on SOME acceptor: it echoes once, reports
      # ready, then parks for a `go` the test sends AFTER the drain begins.
      finisher = Process.spawn(&Concurrency.SocketServerTest.finisher_client_entry/0)
      _fp = Process.send((Pid.of(finisher) :: Pid(i64)), port)
      ready = Concurrency.SocketServerTest.collect_verdicts(1, 0)
      assert(ready == 1)
      # Steady state: N listeners + 1 handler + 1 finisher client.
      assert(Concurrency.SocketServerTest.await_live_count(base + pool_size + 2, Process.monotonic_millis() + 5000))

      # Trigger the pool-wide drain: the supervisor signals every acceptor to run
      # its own Job-4 drain (each closes its OWN listener), then waits for them all.
      _mon = Process.monitor(sup)
      _shutdown = Process.exit_signal(sup, :shutdown)
      # Release the finisher: its during-drain second echo must STILL succeed —
      # whichever draining acceptor holds it lets the live connection finish.
      _go = Process.send((Pid.of(finisher) :: Pid(i64)), (1 :: i64))
      finisher_done = Concurrency.SocketServerTest.collect_verdicts(1, 0)
      assert(finisher_done == 1)

      # Wait for the whole pool to drain and the supervisor to exit, then confirm
      # every fd (all N listeners + the handler + the client) is reclaimed.
      _down = Process.await_signal()
      assert(Concurrency.SocketServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)

      # EVERY acceptor's listener was closed on drain: a fresh connect to the shared
      # port is REFUSED (no listener remains anywhere in the pool).
      refused = case Socket.connect(SocketAddress.loopback(port), 500) {
        Result.Error(_e) -> (1 :: i64)
        Result.Ok(late) ->
          {
            _c = Socket.close(late)
            (0 :: i64)
          }
      }
      assert(refused == 1)
      _unreg = Process.unregister(:socket_echo_coordinator)
    }
  }

  # Spawn the single poison client and hand it the port.
  fn spawn_poison(port :: i64) -> Nil {
    poison = Process.spawn(&Concurrency.SocketServerTest.poison_client_entry/0)
    _sent = Process.send((Pid.of(poison) :: Pid(i64)), port)
    nil
  }

  # ---- reuse_port acceptor pool (Job 6) ------------------------------------
  #
  # The pool is N acceptor processes, each OWNING ITS OWN listener fd bound to the
  # SAME port via `SO_REUSEPORT` (single-owner Decision B — no shared listener, no
  # kernel change). Port coordination: the FIRST acceptor binds port 0 (ephemeral)
  # and reports the OS-assigned port; the REST bind that SAME port. Each acceptor
  # then runs the EXACT same `acceptor_loop` (bounded accept + spawn_link/send_move
  # handlers + drain) from Jobs 2-5 on its own listener. A pool-wide drain signals
  # every acceptor, and each drains its OWN listener per Job 4.

  # The pool SUPERVISOR: spawn_links the N acceptors, traps their exits (an
  # acceptor crash is reaped and the pool keeps serving on the survivors' listeners
  # — the crashed acceptor's listener + linked handlers are reclaimed by the
  # drop-list), and coordinates the pool-wide drain. It owns NO listener itself.
  pub fn pool_sup_entry() -> Nil {
    _trapped = Process.trap_exit(true)
    # Boot the FIRST acceptor: it binds port 0 with reuse_port and reports the
    # assigned port to the test coordinator, which hands it back to us so we can
    # bind the rest of the pool to the SAME port.
    first = Process.spawn_link(&Concurrency.SocketServerTest.pool_first_acceptor_entry/0)
    port = receive i64 {
      p -> p
    }
    # Pool size 3: the first acceptor plus 2 more bound to the same port.
    acceptors = Concurrency.SocketServerTest.spawn_pool_rest(2, port, List.push((List.new_empty(4) :: List(u64)), first))
    Concurrency.SocketServerTest.pool_sup_loop(acceptors)
  }

  # The FIRST pool acceptor: bind an ephemeral port WITH reuse_port, report the
  # assigned port to the coordinator, then run the shared accept loop on its own
  # listener (2 s drain grace).
  pub fn pool_first_acceptor_entry() -> Nil {
    case Socket.listen(SocketAddress.loopback(0), 128, %SocketOptions{reuse_port: true}) {
      Result.Error(_e) -> nil
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          _reported = Process.send(:socket_echo_coordinator, port)
          state = SocketServer.init(SocketServer.options(50, 0, 2000))
          Concurrency.SocketServerTest.acceptor_loop(state, listener)
        }
    }
  }

  # A REST pool acceptor: receive the shared port, bind it WITH reuse_port
  # (co-existing with the other acceptors' listeners), then run the shared accept
  # loop on its own listener.
  pub fn pool_rest_acceptor_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    case Socket.listen(SocketAddress.loopback(port), 128, %SocketOptions{reuse_port: true}) {
      Result.Error(_e) -> nil
      Result.Ok(listener) ->
        {
          state = SocketServer.init(SocketServer.options(50, 0, 2000))
          Concurrency.SocketServerTest.acceptor_loop(state, listener)
        }
    }
  }

  # Spawn `remaining` REST acceptors, hand each the shared `port`, and return the
  # full acceptor pid list (starting from `collected`, which already holds the
  # first acceptor) so the supervisor can drain/reap them.
  fn spawn_pool_rest(remaining :: i64, port :: i64, collected :: List(u64)) -> List(u64) {
    case remaining <= 0 {
      true -> collected
      false ->
        {
          acceptor = Process.spawn_link(&Concurrency.SocketServerTest.pool_rest_acceptor_entry/0)
          _sent = Process.send((Pid.of(acceptor) :: Pid(i64)), port)
          Concurrency.SocketServerTest.spawn_pool_rest(remaining - 1, port, List.push(collected, acceptor))
        }
    }
  }

  # The supervisor loop: block for one signal, then either reap a dead acceptor
  # (keep serving on the survivors) or, on a shutdown order from a NON-acceptor
  # (the test/parent), drive a pool-wide drain and exit.
  fn pool_sup_loop(acceptors :: List(u64)) -> Nil {
    _got = Process.await_signal()
    from = Process.last_signal_from()
    case Concurrency.SocketServerTest.pool_contains(acceptors, from, 0, List.length(acceptors)) {
      # An acceptor exited (a crash reclaims its listener + linked handlers via the
      # drop-list). Drop it; the pool keeps serving on the survivors. When the last
      # acceptor is gone the pool is gone, so exit.
      true ->
        {
          remaining = Concurrency.SocketServerTest.pool_without(acceptors, from, 0, List.length(acceptors), (List.new_empty(4) :: List(u64)))
          case List.empty?(remaining) {
            true -> Process.exit_with(:normal)
            false -> Concurrency.SocketServerTest.pool_sup_loop(remaining)
          }
        }
      # A shutdown order from a NON-acceptor: signal every acceptor to run its own
      # Job-4 drain, wait for them all to finish, then exit.
      false ->
        {
          _drained = Concurrency.SocketServerTest.pool_drain_all(acceptors, 0, List.length(acceptors))
          _waited = Concurrency.SocketServerTest.pool_wait_all(acceptors)
          Process.exit_with(:normal)
        }
    }
  }

  # Send an `:shutdown` exit to every acceptor in `acceptors[index, total)` — each
  # (trapping) acceptor treats it as a drain order and closes its own listener.
  fn pool_drain_all(acceptors :: List(u64), index :: i64, total :: i64) -> Bool {
    case index < total {
      true ->
        {
          _s = Process.exit_signal(List.at(acceptors, index), :shutdown)
          Concurrency.SocketServerTest.pool_drain_all(acceptors, index + 1, total)
        }
      false -> true
    }
  }

  # Reap exactly one exit per still-live acceptor in `remaining` (each linked
  # acceptor delivers its exit as it finishes draining), removing each as it
  # arrives; a stray signal from a non-acceptor leaves the set unchanged and is
  # re-awaited. Terminates once every acceptor has exited.
  fn pool_wait_all(remaining :: List(u64)) -> Bool {
    case List.empty?(remaining) {
      true -> true
      false ->
        {
          _r = Process.await_signal()
          from = Process.last_signal_from()
          Concurrency.SocketServerTest.pool_wait_all(Concurrency.SocketServerTest.pool_without(remaining, from, 0, List.length(remaining), (List.new_empty(4) :: List(u64))))
        }
    }
  }

  # Whether `target` raw pid bits appear in `pids[index, total)`.
  fn pool_contains(pids :: List(u64), target :: u64, index :: i64, total :: i64) -> Bool {
    case index < total {
      true ->
        case List.at(pids, index) == target {
          true -> true
          false -> Concurrency.SocketServerTest.pool_contains(pids, target, index + 1, total)
        }
      false -> false
    }
  }

  # Copy `pids[index, total)` into `collected`, skipping every occurrence of
  # `target` — the acceptor set with one entry removed.
  fn pool_without(pids :: List(u64), target :: u64, index :: i64, total :: i64, collected :: List(u64)) -> List(u64) {
    case index < total {
      true ->
        {
          pid = List.at(pids, index)
          next_collected = case pid == target {
            true -> collected
            false -> List.push(collected, pid)
          }
          Concurrency.SocketServerTest.pool_without(pids, target, index + 1, total, next_collected)
        }
      false -> collected
    }
  }
}
