@doc = """
  `SocketAddress` — a sendable value naming a socket endpoint.

  It carries the address `family` (`:ip4` in S0; `:ip6`/`:unix` arrive with
  their transports in S1/S2), the four IPv4 octets, and the `port`. Being a
  plain struct of sendable scalars it can travel in a message like any other
  value.

  DNS resolution (`resolve/2`) lives *inside* `Socket.connect(host, port)` by
  default and is deferred to S1 (§7.2); S0 connects to explicit IPv4
  addresses (the loopback exit gate).

  Only available on targets with the `:network` capability.

  ## Examples

      SocketAddress.loopback(8080)
      SocketAddress.ip4(127, 0, 0, 1, 8080)
  """

@available_on(:network)

pub struct SocketAddress {
  family :: Atom = :ip4
  a :: i64 = 0
  b :: i64 = 0
  c :: i64 = 0
  d :: i64 = 0
  port :: i64 = 0

  @doc = """
    Builds an IPv4 address from its four octets and a port.

    ## Examples

        SocketAddress.ip4(93, 184, 216, 34, 80)
    """

  @available_on(:network)

  pub fn ip4(a :: i64, b :: i64, c :: i64, d :: i64, port :: i64) -> SocketAddress {
    %SocketAddress{family: :ip4, a: a, b: b, c: c, d: d, port: port}
  }

  @doc = """
    Builds the IPv4 loopback address (`127.0.0.1`) on `port` — the endpoint
    the S0 loopback exit gate connects to.

    ## Examples

        SocketAddress.loopback(0)   # an ephemeral-port loopback endpoint
    """

  @available_on(:network)

  pub fn loopback(port :: i64) -> SocketAddress {
    %SocketAddress{family: :ip4, a: 127, b: 0, c: 0, d: 1, port: port}
  }

  @doc = """
    Unpacks a runtime endpoint code
    (`((((a*256+b)*256+c)*256+d)*65536)+port`, or `-1` when unavailable) into a
    `SocketAddress` (Phase S1). Integer division only — Zap has no bitwise ops
    and needs none here. An unavailable endpoint yields
    `%SocketAddress{family: :unavailable}`. Lives here (with the address it
    produces) so both `Socket.local_address`/`peer_address` and
    `SocketListener.local_address` reuse it without a `Socket ↔ SocketListener`
    cross-call.

    ## Examples

        SocketAddress.from_packed(-1)   # => %SocketAddress{family: :unavailable}
    """

  @available_on(:network)

  pub fn from_packed(packed :: i64) -> SocketAddress {
    case packed < 0 {
      true -> %SocketAddress{family: :unavailable}
      false ->
        {
          port = Integer.remainder(packed, 65536)
          host = packed / 65536
          d = Integer.remainder(host, 256)
          c = Integer.remainder(host / 256, 256)
          b = Integer.remainder(host / 65536, 256)
          a = host / 16777216
          %SocketAddress{family: :ip4, a: a, b: b, c: c, d: d, port: port}
        }
    }
  }
}
