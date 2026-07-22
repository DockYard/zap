pub struct TestConcurrency.TlsServerTest {
  use Zest.Case

  # Phase S5d acceptance proof (gate-ON): the HERMETIC Zap TLS client <-> Zap TLS
  # server loopback — a real TLS 1.3 handshake, application data both ways, and a
  # clean close, all in ONE process with no network. What this pins, end to end:
  #
  #   * a TRAPPING acceptor OWNS a `Tls.listen` listener (the fixture ECDSA cert +
  #     key parsed once at bind) and loops `Tls.accept(listener, poll_ms)` — each
  #     accept ACCEPTS a plaintext connection AND completes its TLS 1.3 SERVER
  #     handshake off-core, yielding a TLS `Socket`;
  #   * for each accepted TLS `Socket` the acceptor `Process.spawn_link`s a fresh
  #     handler and `Process.send_move`s it the TLS `Socket` — the SESSION TRAVELS
  #     WITH THE HANDLE across the cross-process move (the required send_move
  #     proof) — and the handler recv/sends over it, the record layer transparently
  #     decrypting/encrypting for the new owner (`SocketStream.rearm` re-installs
  #     the handler's kill flag);
  #   * N clients connect CONCURRENTLY with the proven S4 `Tls.connect_host_insecure`
  #     (self-signed fixture), each round-tripping a DISTINCT payload through its
  #     own handler over TLS — all N correct (the handshakes interleave across the
  #     blocking pool, client on one thread, server on another);
  #   * a single connection round-trips MULTIPLE messages, proving the moved TLS
  #     session keeps decrypting/encrypting record after record;
  #   * teardown is graceful and leak-exact: the acceptor sees `:shutdown`, closes
  #     the listener (which scrubs + frees the stored private key), drains, and
  #     `Socket.live_count` returns to baseline — every fd (listener + all TLS
  #     connections) reclaimed EXACTLY once.
  #
  # The single-cert config-parse + bad-cert/bad-key `:tls_config_invalid` bad-path
  # is pinned hermetically gate-OFF in `test/tls_test.zap`; the config parser + the
  # `TlsSession` client/server union + the pinned Reason ABI live in
  # `src/runtime/concurrency/socket_io.zig`'s Zig test suite.

  # ---- the acceptor (owns the TLS listener, traps exits) -------------------

  pub fn acceptor_entry() -> Nil {
    config = %TlsServerConfig{cert_pem: TestConcurrency.TlsServerTest.cert_pem(), key_pem: TestConcurrency.TlsServerTest.key_pem(), alpn: ["http/1.1"]}
    case Tls.listen(SocketAddress.loopback(0), config, 128) {
      Result.Error(_e) -> nil
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          _reported = Process.send(:tls_echo_coordinator, port)
          state = SocketServer.init(SocketServer.options(50, 0, 5000))
          TestConcurrency.TlsServerTest.acceptor_loop(state, listener)
        }
    }
  }

  # One turn: reap dead handlers / observe shutdown, then either DRAIN or accept +
  # handshake the next connection. A SINGLE self-recursive function so the
  # compiler loopifies it into a constant-stack loop (an unbounded connection
  # lifetime never overflows the fiber stack).
  fn acceptor_loop(state :: SocketServerState, listener :: SocketListener) -> Nil {
    reaped = SocketServer.reap_signals(state)
    case SocketServer.draining?(reaped) {
      true ->
        {
          _closed = SocketListener.close(listener)
          _drained = SocketServer.drain(reaped)
          Process.exit_with(:normal)
        }
      false ->
        case Tls.accept(listener, reaped.options.accept_poll_ms) {
          # A TLS connection arrived AND completed its handshake: hand the TLS
          # `Socket` to a fresh handler by MOVE (the session travels with it).
          Result.Ok(conn) ->
            {
              handler = Process.spawn_link(&TestConcurrency.TlsServerTest.handler_entry/0)
              _moved = Process.send_move((Pid.of(handler) :: Pid(Socket)), conn)
              TestConcurrency.TlsServerTest.acceptor_loop(SocketServer.admitted(reaped, handler), listener)
            }
          # `:etimedout` on a quiet poll (the common case), or a handshake failure
          # from a hostile/aborted client — just loop, re-reaping.
          Result.Error(_e) -> TestConcurrency.TlsServerTest.acceptor_loop(reaped, listener)
        }
    }
  }

  # ---- the per-connection handler (adopts a MOVED TLS Socket) ---------------

  # ADOPTS the moved TLS `Socket` (`receive Socket`), then echoes over it. Every
  # `Socket.recv`/`Socket.send` here transparently decrypts/encrypts — the handler
  # never touches ciphertext, proving the TLS session survived the send_move and
  # recv/sends correctly under its NEW owner.
  pub fn handler_entry() -> Nil {
    conn = receive Socket {
      s -> s
    }
    TestConcurrency.TlsServerTest.echo_serve(conn)
  }

  fn echo_serve(conn :: Socket) -> Nil {
    case Socket.recv(conn, 0, 5000) {
      SocketRecv.Chunk(bytes) ->
        {
          _sent = Socket.send(conn, bytes)
          TestConcurrency.TlsServerTest.echo_serve(conn)
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

  # ---- clients (separate processes, connect CONCURRENTLY over TLS) ----------

  pub fn client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = TestConcurrency.TlsServerTest.client_run(port)
    nil
  }

  fn client_run(port :: i64) -> Atom {
    payload = "tls-echo-" <> Integer.to_string(Process.self())
    case Tls.connect_host_insecure("localhost", port, 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:tls_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) -> TestConcurrency.TlsServerTest.client_exchange(client, payload)
    }
  }

  fn client_exchange(client :: Socket, payload :: String) -> Atom {
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
    _closed = Socket.close(client)
    _reported = Process.send(:tls_echo_coordinator, verdict)
    :done
  }

  # A client that round-trips THREE distinct messages over ONE TLS connection —
  # proving the moved server session keeps decrypting/encrypting record after
  # record (not just a single handshake-then-one-message flow).
  pub fn multi_client_entry() -> Nil {
    port = receive i64 {
      p -> p
    }
    _result = TestConcurrency.TlsServerTest.multi_client_run(port)
    nil
  }

  fn multi_client_run(port :: i64) -> Atom {
    case Tls.connect_host_insecure("localhost", port, 5000) {
      Result.Error(_e) ->
        {
          _r = Process.send(:tls_echo_coordinator, (0 :: i64))
          :connect_failed
        }
      Result.Ok(client) ->
        {
          ok = TestConcurrency.TlsServerTest.echo_n(client, 3, 0)
          _closed = Socket.close(client)
          _reported = Process.send(:tls_echo_coordinator, ok)
          :done
        }
    }
  }

  # Send+verify `remaining` distinct messages in sequence; returns 1 iff every one
  # echoed back byte-exact.
  fn echo_n(client :: Socket, remaining :: i64, index :: i64) -> i64 {
    case remaining <= 0 {
      true -> (1 :: i64)
      false ->
        {
          payload = "msg-" <> Integer.to_string(index)
          _sent = Socket.send(client, payload)
          case Socket.recv(client, String.length(payload), 5000) {
            SocketRecv.Chunk(bytes) ->
              case bytes == payload {
                true -> TestConcurrency.TlsServerTest.echo_n(client, remaining - 1, index + 1)
                false -> (0 :: i64)
              }
            SocketRecv.TimedOut(_p) -> (0 :: i64)
            SocketRecv.Closed -> (0 :: i64)
            SocketRecv.Failed(_e) -> (0 :: i64)
          }
        }
    }
  }

  # ---- coordinator helpers -------------------------------------------------

  fn spawn_clients(remaining :: i64, port :: i64) -> Nil {
    case remaining <= 0 {
      true -> nil
      false ->
        {
          client = Process.spawn(&TestConcurrency.TlsServerTest.client_entry/0)
          _sent = Process.send((Pid.of(client) :: Pid(i64)), port)
          TestConcurrency.TlsServerTest.spawn_clients(remaining - 1, port)
        }
    }
  }

  fn collect_verdicts(remaining :: i64, acc :: i64) -> i64 {
    case remaining <= 0 {
      true -> acc
      false ->
        {
          verdict = receive i64 {
            v -> v
            after 20000 -> (-1 :: i64)
          }
          case verdict < 0 {
            true -> acc
            false -> TestConcurrency.TlsServerTest.collect_verdicts(remaining - 1, acc + verdict)
          }
        }
    }
  }

  fn await_live_count(target :: i64, deadline_ms :: i64) -> Bool {
    case Socket.live_count() == target {
      true -> true
      false ->
        case Process.monotonic_millis() >= deadline_ms {
          true -> false
          false ->
            {
              _napped = :zig.ProcessRuntime.await_signal_timeout(5)
              TestConcurrency.TlsServerTest.await_live_count(target, deadline_ms)
            }
        }
    }
  }

  # ---- the exit-gate tests -------------------------------------------------

  describe("Hermetic Zap TLS client <-> Zap TLS server loopback (Phase S5d)") {
    test("N clients each complete a TLS 1.3 handshake and round-trip a distinct payload through a send_move'd handler; leak-exact") {
      _named = Process.register(:tls_echo_coordinator)
      base = Socket.live_count()
      acceptor = Process.spawn(&TestConcurrency.TlsServerTest.acceptor_entry/0)
      _mon = Process.monitor(acceptor)
      port = receive i64 {
        p -> p
      }
      # The TLS listener is now the one live socket above baseline.
      assert(TestConcurrency.TlsServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      client_count = 4
      _spawned = TestConcurrency.TlsServerTest.spawn_clients(client_count, port)
      total = TestConcurrency.TlsServerTest.collect_verdicts(client_count, 0)
      # Every one of the concurrent TLS connections handshook + echoed its payload.
      assert(total == client_count)

      # All TLS connection fds reclaimed; only the listener remains.
      assert(TestConcurrency.TlsServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      # Graceful teardown: the acceptor sees `:shutdown`, closes the listener
      # (scrubbing + freeing the stored private key), drains, and exits.
      _shutdown = Process.exit_signal(acceptor, :shutdown)
      _down = Process.await_signal()
      assert(TestConcurrency.TlsServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:tls_echo_coordinator)
    }

    test("one TLS connection round-trips MULTIPLE messages through its send_move'd handler (the moved session keeps decrypting record after record); leak-exact") {
      _named = Process.register(:tls_echo_coordinator)
      base = Socket.live_count()
      acceptor = Process.spawn(&TestConcurrency.TlsServerTest.acceptor_entry/0)
      _mon = Process.monitor(acceptor)
      port = receive i64 {
        p -> p
      }
      assert(TestConcurrency.TlsServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))

      client = Process.spawn(&TestConcurrency.TlsServerTest.multi_client_entry/0)
      _sent = Process.send((Pid.of(client) :: Pid(i64)), port)
      total = TestConcurrency.TlsServerTest.collect_verdicts(1, 0)
      assert(total == 1)

      assert(TestConcurrency.TlsServerTest.await_live_count(base + 1, Process.monotonic_millis() + 5000))
      _shutdown = Process.exit_signal(acceptor, :shutdown)
      _down = Process.await_signal()
      assert(TestConcurrency.TlsServerTest.await_live_count(base, Process.monotonic_millis() + 5000))
      assert(Socket.live_count() == base)
      _unreg = Process.unregister(:tls_echo_coordinator)
    }
  }

  # ---- the self-signed P-256 ECDSA fixture (test/fixtures/tls/*.pem) --------

  fn cert_pem() -> String {
    """
    -----BEGIN CERTIFICATE-----
    MIIBmjCCAT+gAwIBAgIUMMaoyKUPtk7DddXMceDO4Ct8JHkwCgYIKoZIzj0EAwIw
    FDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MDcxODE5Mjc0MFoXDTM2MDcxNTE5
    Mjc0MFowFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0D
    AQcDQgAEB2lsyvra4RAWZq/DqY2o0mxFVhRTYqCNHQepl87hKcH+FvAKtYvMBaeT
    vEdS1EHOoOmcVGvIPFV3JIf4K4+gTqNvMG0wHQYDVR0OBBYEFLyBFnPNF3GlffBT
    AixjsBkC5VSvMB8GA1UdIwQYMBaAFLyBFnPNF3GlffBTAixjsBkC5VSvMA8GA1Ud
    EwEB/wQFMAMBAf8wGgYDVR0RBBMwEYIJbG9jYWxob3N0hwR/AAABMAoGCCqGSM49
    BAMCA0kAMEYCIQDQKSD7MMuxS+Vr1sRd0xlrZR8QSNSEne+zFc+MVdALoAIhAJQN
    kxKtmLXPi6qM6KTlgO9hDglv/Qhl4YFCte+fZJAM
    -----END CERTIFICATE-----
    """
  }

  fn key_pem() -> String {
    """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEILFOeSNPKzUGGtZB1xBhwiKdj5ofWZ8eqpouy+3I/h60oAoGCCqGSM49
    AwEHoUQDQgAEB2lsyvra4RAWZq/DqY2o0mxFVhRTYqCNHQepl87hKcH+FvAKtYvM
    BaeTvEdS1EHOoOmcVGvIPFV3JIf4K4+gTg==
    -----END EC PRIVATE KEY-----
    """
  }

}
