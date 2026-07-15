@doc = """
  `SocketOptions` — the curated, portable socket options, a struct with
  typed defaults (Tier-0 "curated portable options"). The defaults encode
  the plan's chosen posture:

  * `nodelay = true` — `TCP_NODELAY` on by default, dodging the 40 ms
    Nagle × delayed-ACK stall (Go's choice).
  * `reuse_address = true` — a just-closed listen port is immediately
    rebindable (the right default for servers and tests).
  * `keepalive = false`, `reuse_port = false`, `ip6_only = false` —
    conservative; `ip6_only` is explicit because the cross-OS default
    divergence is a known portability hazard.
  * `send_buffer` / `recv_buffer` — `0` means "leave the OS default".
  * `backlog = 128` — the listen backlog (capped by `somaxconn`).
  * `connect_timeout_ms = 0` — no connect deadline (`0` = none).
  * `linger_ms = -1` — no `SO_LINGER` override (`-1` = OS default; `0` is
    the explicit RST-close affordance).

  S0 defines the struct and its defaults (the stable shape); APPLYING the
  options to a socket (via the `runtime_os` seam over `setsockopt`, R3) lands
  with the Tier-1 op set in S1. Only available on `:network` targets.

  ## Examples

      SocketOptions.default()
      %SocketOptions{nodelay: false, backlog: 1024}
  """

@available_on(:network)

pub struct SocketOptions {
  nodelay :: Bool = true
  keepalive :: Bool = false
  reuse_address :: Bool = true
  reuse_port :: Bool = false
  ip6_only :: Bool = false
  send_buffer :: i64 = 0
  recv_buffer :: i64 = 0
  backlog :: i64 = 128
  connect_timeout_ms :: i64 = 0
  linger_ms :: i64 = -1

  @doc = """
    The default options (all fields at their documented defaults).

    ## Examples

        SocketOptions.default()
    """

  @available_on(:network)

  pub fn default() -> SocketOptions {
    %SocketOptions{}
  }
}
