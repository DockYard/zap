pub struct TlsTest {
  use Zest.Case

  # Phase S4 (TLS client) HERMETIC surface proof (gate-OFF, no network): the
  # `Tls.connect`/`connect_host`/`connect_host_insecure`/`upgrade` surface
  # COMPILES + COMPOSES over the plaintext `Socket` transport, the S4 error
  # arms decode, and every failure path closes the fd (leak-exact against
  # `Socket.live_count`). The over-the-wire POSITIVE proof (a real HTTPS 200)
  # and the wire NEGATIVE proof (a bad cert REJECTED) run via the opt-in
  # `test/tls_live_test.zap` (set `ZAP_TLS_LIVE=1`); the hermetic wrong-hostname
  # rejection is pinned in `socket_io.zig`'s Zig test suite.

  describe("SocketError decodes the S4 TLS reason codes") {
    test("14 -> :tls_cert_invalid and 15 -> :tls_handshake_failed round-trip through reason_from_code") {
      assert(SocketError.reason_from_code(14) == :tls_cert_invalid)
      assert(SocketError.reason_from_code(15) == :tls_handshake_failed)
    }

    test("the pre-existing arms and the open-set escape hatch are unchanged") {
      assert(SocketError.reason_from_code(1) == :econnrefused)
      assert(SocketError.reason_from_code(2) == :etimedout)
      assert(SocketError.reason_from_code(13) == :einval)
      assert(SocketError.reason_from_code(99) == :unknown)
      assert(SocketError.reason_from_code(1000) == :unknown)
    }

    test("from_code builds a typed %SocketError carrying the TLS reason") {
      error = SocketError.from_code(14)
      assert(error.reason == :tls_cert_invalid)
    }
  }

  describe("Tls.connect / connect_host compose over Socket and never leak (gate-OFF)") {
    test("connect_host to a refused port yields a typed SocketError (connect leg fails before TLS), leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.connect_host_refused_is_error())
      assert(Socket.live_count() == base)
    }

    test("connect (resolved endpoint) to a refused port yields a typed SocketError, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.connect_refused_is_error())
      assert(Socket.live_count() == base)
    }

    test("connect_host to a live NON-TLS peer fails the handshake and CLOSES the fd, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.connect_host_non_tls_handshake_fails())
      assert(Socket.live_count() == base)
    }

    test("connect_host_insecure (the loud opt-in) also composes and closes the fd on a failed handshake, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.connect_host_insecure_non_tls_handshake_fails())
      assert(Socket.live_count() == base)
    }
  }

  describe("Tls.upgrade consumes its plaintext Socket and never leaks (gate-OFF)") {
    test("upgrade over a live NON-TLS peer fails, closes the CONSUMED socket, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.upgrade_non_tls_fails())
      assert(Socket.live_count() == base)
    }
  }

  # ---- helpers ----

  # Bind an ephemeral loopback port, read it, then close the listener so nothing
  # listens there — a deterministic "connection refused" target.
  fn dead_port() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 1) {
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          _closed = SocketListener.close(listener)
          port
        }
      Result.Error(_e) -> 0
    }
  }

  # Tls.connect_host to a dead port: the TCP connect leg fails (:econnrefused)
  # before any TLS, so no socket is ever created — a typed SocketError, no crash.
  fn connect_host_refused_is_error() -> Bool {
    case Tls.connect_host("localhost", TlsTest.dead_port(), 1000) {
      Result.Error(_e) -> true
      Result.Ok(socket) ->
        {
          _c = Socket.close(socket)
          false
        }
    }
  }

  fn connect_refused_is_error() -> Bool {
    case Tls.connect(SocketAddress.loopback(TlsTest.dead_port()), "example.com", 1000) {
      Result.Error(_e) -> true
      Result.Ok(socket) ->
        {
          _c = Socket.close(socket)
          false
        }
    }
  }

  # A live loopback listener that never speaks TLS: the TCP connect SUCCEEDS,
  # then the verified handshake writes a ClientHello and waits for a ServerHello
  # that never comes, so it TIMES OUT on the short deadline. Tls.connect_host
  # must return a typed Error AND close the underlying fd (leak-exact).
  fn connect_host_non_tls_handshake_fails() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          outcome = case Tls.connect_host("localhost", port, 300) {
            Result.Error(_e2) -> true
            Result.Ok(socket) ->
              {
                _c = Socket.close(socket)
                false
              }
          }
          _closed = SocketListener.close(listener)
          outcome
        }
    }
  }

  fn connect_host_insecure_non_tls_handshake_fails() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          outcome = case Tls.connect_host_insecure("localhost", port, 300) {
            Result.Error(_e2) -> true
            Result.Ok(socket) ->
              {
                _c = Socket.close(socket)
                false
              }
          }
          _closed = SocketListener.close(listener)
          outcome
        }
    }
  }

  # STARTTLS over a live NON-TLS peer: connect a plaintext client, then upgrade
  # (consuming it). The handshake times out; Tls.upgrade closes the consumed
  # socket, so no fd leaks. `client` is never used after the upgrade (it was
  # moved) — the move-only consume contract.
  fn upgrade_non_tls_fails() -> Bool {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = SocketListener.local_port(listener)
          outcome = TlsTest.upgrade_client(port)
          _closed = SocketListener.close(listener)
          outcome
        }
    }
  }

  fn upgrade_client(port :: i64) -> Bool {
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) -> false
      Result.Ok(client) ->
        case Tls.upgrade(client, "example.com", 300) {
          Result.Error(_e2) -> true
          Result.Ok(secure) ->
            {
              _c = Socket.close(secure)
              false
            }
        }
    }
  }

}
