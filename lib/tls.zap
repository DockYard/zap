@doc = """
  `Tls` — the value-threaded TLS client surface (Phase S4): a mandatory-
  verification TLS handshake layered over the `Socket` transport, so an
  outbound HTTPS connection is one call and every subsequent `Socket.recv` /
  `Socket.send` transparently decrypts / encrypts.

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
  `Result.Error(%SocketError{reason: :tls_cert_invalid})` and the connection is
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
        Result.Error(%SocketError{reason: :tls_cert_invalid}) -> :peer_not_trusted
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
    transparently decrypt/encrypt — or `Result.Error(%SocketError{...})`:
    `:tls_cert_invalid` when the server certificate fails verification,
    `:tls_handshake_failed` for a non-certificate handshake failure, or a
    transport reason (`:econnrefused`, `:etimedout`, …) from the connect leg.

    `address` is a single explicit endpoint (nothing is raced); connect by NAME
    with DNS + Happy Eyeballs is `Tls.connect_host/3`. On ANY failure the
    underlying fd is closed before returning — a failed TLS connect leaks no
    socket.

    ## Examples

        Tls.connect(SocketAddress.ip4(93, 184, 216, 34, 443), "example.com", 5000)
    """

  @available_on(:network)

  pub fn connect(address :: SocketAddress, host :: String, timeout_ms :: i64) -> Result(Socket, SocketError) {
    case Socket.connect(address, timeout_ms) {
      Result.Ok(socket) ->
        case :zig.SocketRuntime.tls_handshake(socket.zap_socket_handle, host, timeout_ms) {
          0 -> Result(Socket, SocketError).Ok(socket)
          reason -> {
            _closed = Socket.close(socket)
            Result(Socket, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(reason)})
          }
        }
      Result.Error(error) -> Result(Socket, SocketError).Error(error)
    }
  }

  @doc = """
    Connects to `host:port` by NAME — DNS resolution + RFC 8305 Happy Eyeballs
    (the same racing `Socket.connect_host/3` performs) — then performs a
    MANDATORY-verification TLS handshake using `host` as BOTH the SNI server name
    and the certificate verification target, waiting at most `timeout_ms`
    milliseconds per leg (`0` = no deadline). Returns `Result.Ok(socket)` (a TLS
    `Socket`) or `Result.Error(%SocketError{...})`: `:tls_cert_invalid` on a
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

  pub fn connect_host(host :: String, port :: i64, timeout_ms :: i64) -> Result(Socket, SocketError) {
    case Socket.connect_host(host, port, timeout_ms) {
      Result.Ok(socket) ->
        case :zig.SocketRuntime.tls_handshake(socket.zap_socket_handle, host, timeout_ms) {
          0 -> Result(Socket, SocketError).Ok(socket)
          reason -> {
            _closed = Socket.close(socket)
            Result(Socket, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(reason)})
          }
        }
      Result.Error(error) -> Result(Socket, SocketError).Error(error)
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

  pub fn connect_host_insecure(host :: String, port :: i64, timeout_ms :: i64) -> Result(Socket, SocketError) {
    case Socket.connect_host(host, port, timeout_ms) {
      Result.Ok(socket) ->
        case :zig.SocketRuntime.tls_handshake_insecure(socket.zap_socket_handle, host, timeout_ms) {
          0 -> Result(Socket, SocketError).Ok(socket)
          reason -> {
            _closed = Socket.close(socket)
            Result(Socket, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(reason)})
          }
        }
      Result.Error(error) -> Result(Socket, SocketError).Error(error)
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
    `Result.Ok(tls_socket)` on success, or `Result.Error(%SocketError{...})` —
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

  pub fn upgrade(socket :: Socket, host :: String, timeout_ms :: i64) -> Result(Socket, SocketError) {
    case :zig.SocketRuntime.tls_upgrade(socket.zap_socket_handle, host, timeout_ms) {
      0 -> {
        _closed = Socket.close(socket)
        Result(Socket, SocketError).Error(%SocketError{reason: SocketError.reason_from_code(:zig.SocketRuntime.last_error())})
      }
      successor_bits -> Result(Socket, SocketError).Ok(%Socket{zap_socket_handle: successor_bits})
    }
  }

}
