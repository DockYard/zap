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
  * `:closed` — the socket was closed under the operation.
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

    ## Examples

        SocketError.reason_from_code(1)   # => :econnrefused
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
