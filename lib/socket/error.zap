@doc = """
  `Socket.Error` — the typed, matchable failure of every socket operation.

  A socket op returns `Result(t, Socket.Error)`, so failures compose through
  `?`, `with`, `~>`, and `rescue`, and `zap explain Z1101` documents the
  family. The `reason` field is an **open** set of POSIX/`getaddrinfo`-modeled
  atoms an exhaustive `case` can match:

  * `:econnrefused` — nothing is listening at the destination.
  * `:etimedout` — the operation exceeded its deadline.
  * `:econnreset` — the peer reset the connection.
  * `:ehostunreach` / `:enetunreach` — no route to host / network.
  * `:eaddrinuse` — the address/port is already bound.
  * `:eaddrnotavail` — the requested local address is not available.
  * `:emfile` — the process (or system) fd limit was reached.
  * `:eacces` — permission denied (e.g. a firewall rule).
  * `:enetdown` — the local network interface is down.
  * `:enomem` — the runtime could not allocate for the socket.
  * `:nxdomain` — the host name could not be resolved to any address.
  * `:einval` — the supplied host name is syntactically invalid (RFC 1123).
  * `:tls_cert_invalid` — TLS server-certificate verification FAILED (Phase
    S4): a hostname mismatch, an expired / not-yet-valid certificate, an
    untrusted issuer, or a bad certificate signature. A DISTINCT, typed reason
    so a verification failure is never silently folded into a generic transport
    error — the caller can surface "the peer's certificate is not trusted"
    precisely and refuse the connection.
  * `:tls_handshake_failed` — the TLS handshake failed for a NON-certificate
    reason (Phase S4): a fatal alert, an unexpected/mal-formed handshake
    message, a record-layer decrypt failure, insufficient entropy, or the
    underlying transport failing mid-handshake.
  * `:tls_no_matching_cert` — a TLS SERVER handshake (Phase S5) could not
    present a usable certificate for the client's request: the client advertised
    no signature scheme the configured leaf key can produce (or, once per-SNI
    cert selection lands, no configured certificate matched the client's SNI). A
    distinct reason so a server operator can tell "no matching certificate for
    this client" from a generic protocol failure.
  * `:tls_config_invalid` — a TLS SERVER's own certificate/key configuration is
    unusable (Phase S5), surfaced at `Tls.listen` / `Tls.upgrade_server` time
    BEFORE any client connects: an empty/malformed certificate chain, an
    unparseable or unsupported private key, or a private key that does not match
    the leaf certificate's public key. A mis-configured server fails loudly at
    bind time rather than mysteriously at handshake time.
  * `:closed` — a config op (`set_options`) ran against a socket this program
    no longer owns (a closed or foreign handle): the ownership gate, surfaced
    as a recoverable error rather than a panic. It comes from that gate, NOT
    from a numeric runtime code (`reason_from_code` has no `:closed` arm).
  * `:unknown` — an unmapped failure (the open-set escape hatch).

  `bytes_sent` reports how much of a payload committed before a `send`
  failure (the Erlang `\#{timeout, RestData}` lesson, adapted) — `0` for
  every non-send failure. It is present from S0 for the stable shape; the
  send path that populates it lands in S1.

  Only available on targets with the `:network` capability; `wasm32-wasi`
  rejects socket code at compile time with the `:network` diagnostic.
  """

@code Z1101
@available_on(:network)

pub error Socket.Error {
  reason :: Atom = :unknown
  bytes_sent :: i64 = 0

  @doc = """
    Maps a runtime failure reason code to its matchable `Socket.Error` reason
    atom (the open POSIX/`getaddrinfo`-modeled set). Shared by `from_code` and
    the `send` path (which also carries `bytes_sent`).

    The runtime-code → typed-error mapping lives HERE, on the error it
    produces (not on `Socket`), so both `Socket` and the distinct
    `Socket.Listener` build typed failures from a runtime reason code WITHOUT
    either op-surface having to call into the other (a `Socket ↔ Socket.Listener`
    mutual dependency the codegen cannot yet resolve). Kept in Zap so the code →
    atom mapping is testable and the matchable reason set lives with the
    language. As an ordinary member of the network-gated `Socket.Error` error,
    it is covered by the declaration's `@available_on(:network)` gate.

    ## Coupling to the runtime `socket_io.Reason` enum (ABI contract)

    Each numeric arm below is the `@intFromEnum` value of the matching
    `socket_io.Reason` variant (`src/runtime/concurrency/socket_io.zig`):
    `runtime.zig` passes those integers across the C-ABI UNCHANGED, so this
    table is the sole code → atom decoder and the two must agree POSITIONALLY.
    There is no cross-language source of truth, so a Zig-side test pins every
    `Reason` integer value (`test "socket_io: Reason integer values are the
    pinned ABI contract …"`): renumbering the enum breaks that test, forcing
    this table to move in lockstep. `:closed` is NOT in this table — it is
    surfaced directly by `Socket.set_options` on a stale/foreign handle (the
    ownership gate), never by a numeric code.

    The Phase S4 TLS arms (`14 -> :tls_cert_invalid`, `15 ->
    :tls_handshake_failed`) decode the two `socket_io.Reason` values
    `mapTlsInitError` produces: a certificate-verification failure maps to
    `:tls_cert_invalid` (always distinct, never folded into a generic error),
    every other handshake failure to `:tls_handshake_failed`. A transport
    failure DURING the handshake (a deadline or a reset) still decodes through
    its own POSIX arm (e.g. `2 -> :etimedout`), because `tlsHandshake` prefers
    the stashed transport reason over the generic TLS code.

    The Phase S5 TLS SERVER arms (`16 -> :tls_no_matching_cert`, `17 ->
    :tls_config_invalid`) decode the two `socket_io.Reason` values the server
    path produces: `mapTlsServerInitError` maps "no usable cert/signature scheme
    for this client" to `:tls_no_matching_cert`, and `tlsServerConfigCreate` (at
    `Tls.listen`) plus a bad-config handshake map an unusable cert/key
    configuration to `:tls_config_invalid`.

    ## Examples

        Socket.Error.reason_from_code(1)    # => :econnrefused
        Socket.Error.reason_from_code(14)   # => :tls_cert_invalid
        Socket.Error.reason_from_code(15)   # => :tls_handshake_failed
        Socket.Error.reason_from_code(16)   # => :tls_no_matching_cert
        Socket.Error.reason_from_code(17)   # => :tls_config_invalid
    """

  pub fn reason_from_code(code :: i64) -> Atom {
    case code {
      1 -> :econnrefused
      2 -> :etimedout
      3 -> :ehostunreach
      4 -> :enetunreach
      5 -> :econnreset
      6 -> :eaddrinuse
      7 -> :eaddrnotavail
      8 -> :emfile
      9 -> :eacces
      10 -> :enetdown
      11 -> :enomem
      12 -> :nxdomain
      13 -> :einval
      14 -> :tls_cert_invalid
      15 -> :tls_handshake_failed
      16 -> :tls_no_matching_cert
      17 -> :tls_config_invalid
      _ -> :unknown
    }
  }

  @doc = """
    Maps a runtime failure reason code to a typed `Socket.Error`.

    ## Examples

        Socket.Error.from_code(1)   # => %Socket.Error{reason: :econnrefused}
    """

  pub fn from_code(code :: i64) -> Socket.Error {
    %Socket.Error{reason: Socket.Error.reason_from_code(code)}
  }
}
