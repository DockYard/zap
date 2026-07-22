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

  describe("Socket.Error decodes the S4 TLS reason codes") {
    test("14 -> :tls_cert_invalid and 15 -> :tls_handshake_failed round-trip through reason_from_code") {
      assert(Socket.Error.reason_from_code(14) == :tls_cert_invalid)
      assert(Socket.Error.reason_from_code(15) == :tls_handshake_failed)
    }

    test("the pre-existing arms and the open-set escape hatch are unchanged") {
      assert(Socket.Error.reason_from_code(1) == :econnrefused)
      assert(Socket.Error.reason_from_code(2) == :etimedout)
      assert(Socket.Error.reason_from_code(13) == :einval)
      assert(Socket.Error.reason_from_code(99) == :unknown)
      assert(Socket.Error.reason_from_code(1000) == :unknown)
    }

    test("from_code builds a typed %Socket.Error carrying the TLS reason") {
      error = Socket.Error.from_code(14)
      assert(error.reason == :tls_cert_invalid)
    }

    test("16 -> :tls_no_matching_cert and 17 -> :tls_config_invalid (the S5 server arms) round-trip") {
      assert(Socket.Error.reason_from_code(16) == :tls_no_matching_cert)
      assert(Socket.Error.reason_from_code(17) == :tls_config_invalid)
    }
  }

  describe("Tls.listen validates its TlsServerConfig at bind time (gate-OFF, no network)") {
    test("a valid ECDSA cert+key binds a TLS listener; closing it frees the config, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.listen_valid_binds_and_closes())
      assert(Socket.live_count() == base)
    }

    test("a malformed certificate PEM fails Tls.listen with :tls_config_invalid, no listener, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.listen_reason(%TlsServerConfig{cert_pem: "not a cert", key_pem: TlsTest.key_pem(), alpn: ([] :: List(String))}) == :tls_config_invalid)
      assert(Socket.live_count() == base)
    }

    test("a private key that does not match the leaf certificate fails with :tls_config_invalid, leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.listen_reason(%TlsServerConfig{cert_pem: TlsTest.cert_pem(), key_pem: TlsTest.other_key_pem(), alpn: ([] :: List(String))}) == :tls_config_invalid)
      assert(Socket.live_count() == base)
    }
  }

  describe("Tls.connect / connect_host compose over Socket and never leak (gate-OFF)") {
    test("connect_host to a refused port yields a typed Socket.Error (connect leg fails before TLS), leak-exact") {
      base = Socket.live_count()
      assert(TlsTest.connect_host_refused_is_error())
      assert(Socket.live_count() == base)
    }

    test("connect (resolved endpoint) to a refused port yields a typed Socket.Error, leak-exact") {
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
    case Socket.listen(Socket.Address.loopback(0), 1) {
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          _closed = Socket.Listener.close(listener)
          port
        }
      Result.Error(_e) -> 0
    }
  }

  # Tls.connect_host to a dead port: the TCP connect leg fails (:econnrefused)
  # before any TLS, so no socket is ever created — a typed Socket.Error, no crash.
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
    case Tls.connect(Socket.Address.loopback(TlsTest.dead_port()), "example.com", 1000) {
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
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          outcome = case Tls.connect_host("localhost", port, 300) {
            Result.Error(_e2) -> true
            Result.Ok(socket) ->
              {
                _c = Socket.close(socket)
                false
              }
          }
          _closed = Socket.Listener.close(listener)
          outcome
        }
    }
  }

  fn connect_host_insecure_non_tls_handshake_fails() -> Bool {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          outcome = case Tls.connect_host_insecure("localhost", port, 300) {
            Result.Error(_e2) -> true
            Result.Ok(socket) ->
              {
                _c = Socket.close(socket)
                false
              }
          }
          _closed = Socket.Listener.close(listener)
          outcome
        }
    }
  }

  # STARTTLS over a live NON-TLS peer: connect a plaintext client, then upgrade
  # (consuming it). The handshake times out; Tls.upgrade closes the consumed
  # socket, so no fd leaks. `client` is never used after the upgrade (it was
  # moved) — the move-only consume contract.
  fn upgrade_non_tls_fails() -> Bool {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          port = Socket.Listener.local_port(listener)
          outcome = TlsTest.upgrade_client(port)
          _closed = Socket.Listener.close(listener)
          outcome
        }
    }
  }

  fn upgrade_client(port :: i64) -> Bool {
    case Socket.connect(Socket.Address.loopback(port), 5000) {
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

  # ---- S5 (TLS server) helpers + fixtures ----

  # A valid config binds a TLS listener (a real loopback socket + the parsed
  # config), which we then close — proving the config-attach + close-frees-config
  # lifecycle end to end WITHOUT a handshake (a handshake needs a concurrent
  # client, exercised by the gate-ON `test_concurrency/tls_server_test.zap`).
  fn listen_valid_binds_and_closes() -> Bool {
    config = %TlsServerConfig{cert_pem: TlsTest.cert_pem(), key_pem: TlsTest.key_pem(), alpn: ["http/1.1"]}
    case Tls.listen(Socket.Address.loopback(0), config, 16) {
      Result.Error(_e) -> false
      Result.Ok(listener) ->
        {
          _closed = Socket.Listener.close(listener)
          true
        }
    }
  }

  # The reason atom Tls.listen fails with for a given (bad) config — or
  # :unexpected_ok if it wrongly bound a listener.
  fn listen_reason(config :: TlsServerConfig) -> Atom {
    case Tls.listen(Socket.Address.loopback(0), config, 16) {
      Result.Ok(listener) ->
        {
          _closed = Socket.Listener.close(listener)
          :unexpected_ok
        }
      Result.Error(error) -> error.reason
    }
  }

  # The self-signed P-256 ECDSA leaf for localhost (SAN DNS:localhost,
  # IP:127.0.0.1) + its SEC1 key, and a SECOND unrelated EC key that does NOT
  # match the cert. The base64 decoder ignores heredoc indentation whitespace, so
  # these embed the fixtures directly (`test/fixtures/tls/*.pem`).
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

  fn other_key_pem() -> String {
    """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIP5hU4QR/m6RPjPegL1e87Te38LT+GSOvoPcwhhLD/DuoAoGCCqGSM49
    AwEHoUQDQgAEvgTzXp1tN6aYf29oz9lGCjsojHy5pBnWctWDyAPOvOTpuXDMTaZw
    rOgtpYZ3KbQJH9OlhFYdB/7C2V8vl2OCBQ==
    -----END EC PRIVATE KEY-----
    """
  }

}
