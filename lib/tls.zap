@doc = """
  `TlsServerConfig` — a TLS server's certificate material (Phase S5): the PEM
  certificate chain, the PEM leaf private key, and the ALPN protocol preference
  list a `Tls.listen` listener (or a `Tls.upgrade_server` STARTTLS upgrade)
  presents to every connecting client.

  - `cert_pem` — the server certificate chain as PEM, LEAF FIRST (one or more
    `-----BEGIN CERTIFICATE-----` blocks). Only the leaf is used for
    authentication in this phase; the whole chain is sent in the Certificate
    message.
  - `key_pem` — the leaf's private key as PEM: SEC1 (`EC PRIVATE KEY`), PKCS#8
    (`PRIVATE KEY`), or PKCS#1 (`RSA PRIVATE KEY`). ECDSA (P-256/P-384),
    Ed25519, and RSA (RSASSA-PSS) leaf keys are supported. The key is parsed and
    validated against the leaf certificate ONCE at `Tls.listen` time — a
    mismatched or unparseable key fails with `:tls_config_invalid` at bind time,
    never mysteriously mid-handshake. The private key lives ONLY in the runtime's
    per-listener store; it is NEVER copied into a per-connection session (a
    session holds only the ephemeral/derived traffic secrets), and it is scrubbed
    from memory when the listener closes.
  - `alpn` — the server's ALPN protocol IDs (e.g. `["h2", "http/1.1"]`) in
    PREFERENCE order; the server selects the first entry the client also offers
    and echoes it. An empty list negotiates no ALPN. Read the negotiated protocol
    off the accepted `Socket` once per-connection ALPN read-back lands.

  ## Single-certificate scope (S5d)

  This phase serves the ONE configured certificate to every client regardless of
  the client's SNI (server_name) — SNI-based multi-certificate selection needs a
  fork cert-selection hook and is a planned follow-up. A single default cert
  covers the common single-domain server.

  ## Examples

      %TlsServerConfig{cert_pem: cert, key_pem: key, alpn: ["http/1.1"]}
  """

@available_on(:network)

pub struct TlsServerConfig {
  cert_pem :: String
  key_pem :: String
  alpn :: List(String)
}

@doc = """
  `Tls` — the value-threaded TLS client AND server surface: a mandatory-
  verification TLS client handshake (Phase S4) and a TLS 1.3 server (Phase S5)
  layered over the `Socket` transport, so an outbound HTTPS connection or an
  inbound TLS accept is one call and every subsequent `Socket.recv` /
  `Socket.send` transparently decrypts / encrypts.

  ## The server surface (Phase S5)

  `Tls.listen(address, config, backlog)` binds a TLS listener carrying a
  `TlsServerConfig` (cert chain + private key + ALPN), and `Tls.accept(listener,
  timeout_ms)` accepts the next connection AND completes its TLS 1.3 server
  handshake, yielding a TLS `Socket` over which `Socket.recv`/`send`/`chunks`/
  `fold` transparently decrypt/encrypt via the SAME record layer the client uses.
  The accepted TLS `Socket` is an ordinary single-owner `Socket`: it composes
  with the `Socket.Server` acceptor/handler pattern (`Process.send_move` a TLS
  `Socket` to a per-connection handler exactly like a plaintext one — the session
  travels with the handle). `Tls.upgrade_server(socket, config, timeout_ms)` is
  the server-side STARTTLS. A bad cert/key fails `Tls.listen` at bind time with
  `:tls_config_invalid`; a client with no usable cert/signature scheme fails the
  handshake with `:tls_no_matching_cert`. The server is TLS 1.3-only (no 1.2
  fallback, no renegotiation).

  ## A TLS socket IS a `Socket`

  Every `Tls` entry point returns the SAME `%Socket{}` handle the plaintext
  layer returns — a TLS connection is a `Socket` DISTINGUISHED by its kind, not
  a new type. The whole `Socket` surface works over it UNCHANGED:
  `Socket.recv`/`recv_exact`/`recv_blob`, `Socket.send`/`send_all`/`send_some`,
  `Socket.chunks`/`fold`, `Socket.shutdown`, `Socket.close`, and the
  `local_address`/`peer_address` accessors. `recv` returns DECRYPTED application
  bytes and `send` ENCRYPTS before it hits the wire — the record layer lives in
  the runtime, so the Zap caller never touches ciphertext. There is no separate
  `Tls.recv`/`Tls.send`; use `Socket`.

  ## Mandatory verification (the default, no opt-out on the default path)

  `connect`/`connect_host`/`upgrade` verify the server certificate against BOTH
  the requested `host` (SNI + hostname match) AND the host OS trust store
  (chain-of-trust). A certificate that is expired, not-yet-valid, issued for the
  wrong host, or signed by an untrusted issuer is REJECTED — the call returns
  `Result.Error(%Socket.Error{reason: :tls_cert_invalid})` and the connection is
  torn down. A non-certificate handshake failure (a fatal alert, a malformed
  message, a record-layer decrypt failure, or the transport failing
  mid-handshake) returns `:tls_handshake_failed`; a transport timeout during the
  handshake surfaces its own `:etimedout`. Verification is NEVER silently
  downgraded, and there is NO renegotiation.

  The ONE escape hatch is the loudly-named, DANGEROUS `connect_host_insecure/3`,
  which disables verification entirely — for testing against self-signed / local
  endpoints ONLY. It is a physically separate code path (its own runtime bridge
  and abi export) that shares nothing with the verified path, so it cannot
  weaken the default.

  ## Timeout / deadline semantics

  `timeout_ms` (`0` = no deadline) bounds each leg of a fresh connect as its own
  poll-quantum-bounded, kill-responsive deadline: first the TCP connect (or the
  DNS + Happy-Eyeballs race for `connect_host`), then — as a fresh deadline —
  the TLS handshake. The handshake itself runs under ONE absolute deadline
  across all of its round trips, so a slowloris handshake times out and stays
  killable (it can never pin a blocking-pool thread). Neither leg uses
  `SO_*TIMEO` (Decision E, §6.1).

  ## Ownership, consume, and dead-letter rules

  A `Tls` `Socket` is single-owner and move-only exactly like a plaintext
  `Socket` (Decision B). `upgrade/3` CONSUMES its plaintext `Socket` argument:
  on success the runtime bumps the handle's generation in place (the STARTTLS
  gen-bump), so the caller's old plaintext handle is STALE everywhere and only
  the returned TLS `Socket` is valid — using the pre-upgrade handle afterward is
  a compile error (move) or a stale-handle panic (a copy that escaped). On
  handshake FAILURE every entry point closes the underlying fd before returning
  the error, so a failed TLS connect never leaks a socket. Move a TLS `Socket`
  to another process with `Process.send_move` (`controlling_process`) just like
  a plaintext one — the session travels with it.

  ## Availability

  Every `Tls` declaration requires the `:network` target capability;
  `wasm32-wasi` rejects socket/TLS code at COMPILE time with the `:network`
  diagnostic. TLS-over-sockets is posix-first.

  ## Examples

      # A minimal HTTPS request over a verified connection:
      case Tls.connect_host("example.com", 443, 5000) {
        Result.Ok(socket) -> {
          _ = Socket.send(socket, "GET / HTTP/1.1\\r\\nHost: example.com\\r\\nConnection: close\\r\\n\\r\\n")
          reply = Socket.fold(socket, "", 5000, fn(acc, bytes) { {:cont, acc <> bytes} })
          _ = Socket.close(socket)
          reply
        }
        Result.Error(%Socket.Error{reason: :tls_cert_invalid}) -> :peer_not_trusted
        Result.Error(_error) -> :unreachable
      }
  """

@available_on(:network)

pub struct Tls {

  @doc = """
    Connects a stream socket to `address` (an already-resolved endpoint) and
    performs a MANDATORY-verification TLS handshake using `host` as BOTH the SNI
    server name and the certificate verification target, waiting at most
    `timeout_ms` milliseconds per leg (`0` = no deadline). Returns
    `Result.Ok(socket)` — a TLS `Socket` over which `Socket.recv`/`send`
    transparently decrypt/encrypt — or `Result.Error(%Socket.Error{...})`:
    `:tls_cert_invalid` when the server certificate fails verification,
    `:tls_handshake_failed` for a non-certificate handshake failure, or a
    transport reason (`:econnrefused`, `:etimedout`, …) from the connect leg.

    `address` is a single explicit endpoint (nothing is raced); connect by NAME
    with DNS + Happy Eyeballs is `Tls.connect_host/3`. On ANY failure the
    underlying fd is closed before returning — a failed TLS connect leaks no
    socket.

    ## Examples

        Tls.connect(Socket.Address.ip4(93, 184, 216, 34, 443), "example.com", 5000)
    """

  @available_on(:network)

  pub fn connect(address :: Socket.Address, host :: String, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case Socket.connect(address, timeout_ms) {
      Result.Ok(socket) ->
        case :zig.SocketRuntime.tls_handshake(socket.zap_socket_handle, host, timeout_ms) {
          0 -> Result(Socket, Socket.Error).Ok(socket)
          reason -> {
            _closed = Socket.close(socket)
            Result(Socket, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(reason)})
          }
        }
      Result.Error(error) -> Result(Socket, Socket.Error).Error(error)
    }
  }

  @doc = """
    Connects to `host:port` by NAME — DNS resolution + RFC 8305 Happy Eyeballs
    (the same racing `Socket.connect_host/3` performs) — then performs a
    MANDATORY-verification TLS handshake using `host` as BOTH the SNI server name
    and the certificate verification target, waiting at most `timeout_ms`
    milliseconds per leg (`0` = no deadline). Returns `Result.Ok(socket)` (a TLS
    `Socket`) or `Result.Error(%Socket.Error{...})`: `:tls_cert_invalid` on a
    certificate-verification failure, `:tls_handshake_failed` on a non-cert
    handshake failure, `:nxdomain`/`:einval` from the resolve, or a POSIX reason
    (`:econnrefused`, `:etimedout`, …) from the race.

    This is the everyday HTTPS entry point. On ANY failure the underlying fd is
    closed before returning — no socket leak.

    ## Examples

        case Tls.connect_host("example.com", 443, 5000) {
          Result.Ok(socket)   -> socket
          Result.Error(_error) -> :unreachable
        }
    """

  @available_on(:network)

  pub fn connect_host(host :: String, port :: i64, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case Socket.connect_host(host, port, timeout_ms) {
      Result.Ok(socket) ->
        case :zig.SocketRuntime.tls_handshake(socket.zap_socket_handle, host, timeout_ms) {
          0 -> Result(Socket, Socket.Error).Ok(socket)
          reason -> {
            _closed = Socket.close(socket)
            Result(Socket, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(reason)})
          }
        }
      Result.Error(error) -> Result(Socket, Socket.Error).Error(error)
    }
  }

  @doc = """
    ⚠ DANGEROUS — verification-DISABLED HTTPS, FOR TESTING ONLY. ⚠

    Identical to `connect_host/3` but with certificate verification COMPLETELY
    DISABLED: neither the hostname NOR the CA chain-of-trust is checked, so the
    server may present ANY certificate — including a self-signed or expired one —
    and the connection still succeeds. This makes the connection trivially
    defeatable by a man-in-the-middle: the encryption provides NO authentication.
    NEVER use this against a production endpoint or with real credentials. Use it
    ONLY to talk to a local development server or a self-signed test fixture.

    It routes through a physically SEPARATE runtime bridge and abi export
    (`tls_handshake_insecure` / `zap_socket_tls_handshake_insecure`) that shares
    no code with the verified `connect_host/3`, so enabling insecure mode can
    never weaken the default verified path. `host` is still passed (it is only a
    label here — no SNI is sent when verification is off). On ANY failure the fd
    is closed before returning. The handshake is still deadline- and
    kill-bounded, so even an insecure handshake stays DoS-safe.

    ## Examples

        # Talk to a local self-signed dev server (TESTING ONLY):
        Tls.connect_host_insecure("localhost", 8443, 5000)
    """

  @available_on(:network)

  pub fn connect_host_insecure(host :: String, port :: i64, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case Socket.connect_host(host, port, timeout_ms) {
      Result.Ok(socket) ->
        case :zig.SocketRuntime.tls_handshake_insecure(socket.zap_socket_handle, host, timeout_ms) {
          0 -> Result(Socket, Socket.Error).Ok(socket)
          reason -> {
            _closed = Socket.close(socket)
            Result(Socket, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(reason)})
          }
        }
      Result.Error(error) -> Result(Socket, Socket.Error).Error(error)
    }
  }

  @doc = """
    STARTTLS — upgrades an already-connected plaintext `Socket` to TLS in place
    (the opportunistic-encryption pattern SMTP/IMAP/FTP/PostgreSQL negotiate over
    a plaintext channel). Runs a MANDATORY-verification handshake over the SAME
    fd using `host` as the SNI + verification target, waiting at most
    `timeout_ms` milliseconds (`0` = no deadline).

    CONSUMES its `socket` argument: on success the runtime bumps the handle's
    generation in place, so the passed-in plaintext handle is STALE everywhere
    and ONLY the returned TLS `Socket` is valid — using the old handle after a
    successful upgrade is a compile error (move) or a stale-handle panic. Returns
    `Result.Ok(tls_socket)` on success, or `Result.Error(%Socket.Error{...})` —
    `:tls_cert_invalid` / `:tls_handshake_failed` / a transport reason — on
    failure, in which case the underlying socket is CLOSED (the argument was
    consumed by the move, so it is torn down rather than leaked).

    Because the fd is preserved across the upgrade, a TLS `Socket` produced by
    `upgrade/3` can be handed to another process with `Process.send_move`
    (`controlling_process`) exactly like any other `Socket`.

    ## Examples

        # After the plaintext protocol negotiates STARTTLS:
        case Tls.upgrade(socket, "mail.example.com", 5000) {
          Result.Ok(secure)   -> secure
          Result.Error(_error) -> :starttls_failed
        }
    """

  @available_on(:network)

  pub fn upgrade(socket :: Socket, host :: String, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case :zig.SocketRuntime.tls_upgrade(socket.zap_socket_handle, host, timeout_ms) {
      0 -> {
        _closed = Socket.close(socket)
        Result(Socket, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(:zig.SocketRuntime.last_error())})
      }
      successor_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: successor_bits})
    }
  }

  @doc = """
    Binds a TLS SERVER LISTENER on `address` (an IPv4 endpoint; port `0` → an
    ephemeral port, discoverable via `Socket.Listener.local_port`) presenting the
    certificate material in `config`. The certificate chain, private key, and
    ALPN list are parsed and validated ONCE here — a bad, unparseable, or
    key-mismatched certificate fails IMMEDIATELY with
    `Result.Error(%Socket.Error{reason: :tls_config_invalid})`, before the socket
    binds, so a mis-configured server never silently accepts connections it
    cannot serve. Returns `Result.Ok(listener)` — a `Socket.Listener` you `accept`
    with `Tls.accept/2` — or `Result.Error(%Socket.Error{...})` with a transport
    reason (`:eaddrinuse`, `:eacces`, …) from the bind.

    The returned listener is an ordinary single-owner `Socket.Listener`: close it
    with `Socket.Listener.close` (which also scrubs + frees the stored private
    key), and drive it with the `Socket.Server` acceptor/handler pattern exactly
    like a plaintext listener — only swap `Socket.accept` for `Tls.accept`.

    ## Examples

        config = %TlsServerConfig{cert_pem: cert, key_pem: key, alpn: ["http/1.1"]}
        case Tls.listen(Socket.Address.loopback(0), config, 128) {
          Result.Ok(listener) -> Socket.Listener.local_port(listener)
          Result.Error(%Socket.Error{reason: :tls_config_invalid}) -> -1
          Result.Error(_error) -> 0
        }
    """

  @available_on(:network)

  pub fn listen(address :: Socket.Address, config :: TlsServerConfig, backlog :: i64) -> Result(Socket.Listener, Socket.Error) {
    alpn_wire = String.join(config.alpn, "\n")
    case :zig.SocketRuntime.tls_listen(address.a, address.b, address.c, address.d, address.port, backlog, config.cert_pem, config.key_pem, alpn_wire) {
      0 -> Result(Socket.Listener, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket.Listener, Socket.Error).Ok(%Socket.Listener{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    Accepts the next inbound connection on a TLS `listener` AND completes its
    TLS 1.3 SERVER handshake, BOUNDED by `timeout_ms` (`0` = infinite; the same
    bounded-accept the trapping acceptor loop needs to stay shutdown-responsive).
    Returns `Result.Ok(socket)` — a TLS `Socket` over which `Socket.recv`/`send`/
    `chunks`/`fold` transparently decrypt/encrypt (the SAME record layer the
    client uses; there is no separate `Tls.recv`/`send`) — or
    `Result.Error(%Socket.Error{...})`: `:etimedout` when no connection arrives
    within the deadline, `:tls_no_matching_cert` when the client offers no
    signature scheme the configured leaf key can produce,
    `:tls_handshake_failed` for any other handshake failure (a fatal alert, a
    malformed/truncated ClientHello, a record-layer failure, or the transport
    failing mid-handshake), or a transport reason from the accept.

    The whole handshake runs under ONE absolute deadline across its round trips,
    so a slowloris handshake times out and stays killable (it can never pin a
    blocking-pool thread). On a handshake failure the accepted fd is CLOSED
    before returning — a failed TLS accept leaks no socket. The accepted TLS
    `Socket` is single-owner and move-only: `Process.send_move` it to a
    per-connection handler (the `Socket.Server` pattern) and the session travels
    with the handle.

    ## Examples

        case Tls.accept(listener, 50) {
          Result.Ok(connection)                          -> dispatch(connection)
          Result.Error(%Socket.Error{reason: :etimedout}) -> keep_serving()
          Result.Error(_error)                           -> :accept_failed
        }
    """

  @available_on(:network)

  pub fn accept(listener :: Socket.Listener, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    case :zig.SocketRuntime.tls_accept(listener.zap_socket_handle, timeout_ms) {
      0 -> Result(Socket, Socket.Error).Error(Socket.Error.from_code(:zig.SocketRuntime.last_error()))
      handle_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: handle_bits})
    }
  }

  @doc = """
    SERVER STARTTLS — upgrades an already-accepted plaintext `Socket` to a TLS
    SERVER session in place (the server side of the opportunistic-encryption
    pattern), presenting the certificate material in `config`. Runs a TLS 1.3
    server handshake over the SAME fd, waiting at most `timeout_ms` milliseconds
    (`0` = no deadline). This is the server counterpart to the client
    `Tls.upgrade/3` (which takes a `host`); it is named distinctly because it
    plays the SERVER role and takes a `TlsServerConfig`, not a verification host.

    CONSUMES its `socket` argument: on success the runtime bumps the handle's
    generation in place, so the passed-in plaintext handle is STALE everywhere
    and ONLY the returned TLS `Socket` is valid — using the old handle after a
    successful upgrade is a compile error (move) or a stale-handle panic. Returns
    `Result.Ok(tls_socket)` on success, or `Result.Error(%Socket.Error{...})` —
    `:tls_config_invalid` for a bad cert/key, `:tls_no_matching_cert` /
    `:tls_handshake_failed` for a handshake failure, or a transport reason — on
    failure, in which case the underlying socket is CLOSED (the argument was
    consumed by the move, so it is torn down rather than leaked).

    ## Examples

        # After the plaintext protocol negotiates STARTTLS server-side:
        case Tls.upgrade_server(socket, config, 5000) {
          Result.Ok(secure)   -> secure
          Result.Error(_error) -> :starttls_failed
        }
    """

  @available_on(:network)

  pub fn upgrade_server(socket :: Socket, config :: TlsServerConfig, timeout_ms :: i64) -> Result(Socket, Socket.Error) {
    alpn_wire = String.join(config.alpn, "\n")
    case :zig.SocketRuntime.tls_server_upgrade(socket.zap_socket_handle, config.cert_pem, config.key_pem, alpn_wire, timeout_ms) {
      0 -> {
        _closed = Socket.close(socket)
        Result(Socket, Socket.Error).Error(%Socket.Error{reason: Socket.Error.reason_from_code(:zig.SocketRuntime.last_error())})
      }
      successor_bits -> Result(Socket, Socket.Error).Ok(%Socket{zap_socket_handle: successor_bits})
    }
  }

}
