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
}
