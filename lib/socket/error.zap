@doc = """
  `SocketError` — the typed, matchable failure of every socket operation.

  A socket op returns `Result(t, SocketError)`, so failures compose through
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

pub error SocketError {
  reason :: Atom = :unknown
  bytes_sent :: i64 = 0

  @doc = """
    Maps a runtime failure reason code to its matchable `SocketError` reason
    atom (the open POSIX/`getaddrinfo`-modeled set). Shared by `from_code` and
    the `send` path (which also carries `bytes_sent`).

    The runtime-code → typed-error mapping lives HERE, on the error it
    produces (not on `Socket`), so both `Socket` and the distinct
    `SocketListener` build typed failures from a runtime reason code WITHOUT
    either op-surface having to call into the other (a `Socket ↔ SocketListener`
    mutual dependency the codegen cannot yet resolve). Kept in Zap so the code →
    atom mapping is testable and the matchable reason set lives with the
    language. As an ordinary member of the network-gated `SocketError` error,
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

    ## Examples

        SocketError.reason_from_code(1)    # => :econnrefused
        SocketError.reason_from_code(14)   # => :tls_cert_invalid
        SocketError.reason_from_code(15)   # => :tls_handshake_failed
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
      _ -> :unknown
    }
  }

  @doc = """
    Maps a runtime failure reason code to a typed `SocketError`.

    ## Examples

        SocketError.from_code(1)   # => %SocketError{reason: :econnrefused}
    """

  pub fn from_code(code :: i64) -> SocketError {
    %SocketError{reason: SocketError.reason_from_code(code)}
  }
}
