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

  ## Opt-in semantics (the defaults are not silently auto-applied)

  These defaults describe the posture `set_options` **applies when you call
  it** — they are NOT flipped onto every socket automatically. A bare
  `Socket.connect(_, _)` keeps the OS-default behavior (Nagle ON); the
  latency-first `nodelay = true` takes effect the moment a program opts in
  with `Socket.set_options(socket, SocketOptions.default())` (or a customized
  struct). So `nodelay = true` is a deliberate, applied-on-request default,
  never a misleading no-op: `set_options` reaches `setsockopt` (via the
  `runtime_os` socket seam, R3) and the option is verifiable with
  `Socket.get_option`. The pre-bind options `reuse_address` / `reuse_port`
  are additionally honored by `Socket.listen(address, backlog, options)`,
  which applies them BEFORE `bind` (the only point the OS respects them).

  `backlog` and `connect_timeout_ms` are NOT `setsockopt` options — `backlog`
  is a `listen` argument and `connect_timeout_ms` a `connect` argument — so
  `set_options` carries them for the caller but does not push them to the
  socket. Only available on `:network` targets.

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

  @doc = """
    Applies every `setsockopt`-relevant field of `options` to the raw socket
    `handle_bits` via the runtime bridge (`:zig.SocketRuntime.set_option`),
    short-circuiting on the FIRST failure. Returns `0` when every option
    applied, a positive runtime `Reason` code on a `setsockopt` failure, or
    `-1` when `handle_bits` is not a live socket this program owns (the
    ownership gate — `Socket.set_options` turns that into a typed
    `SocketError`, never a panic).

    The option CODES are a stable ABI contract with the runtime's
    `socket_io.SocketOption` enum (`0` nodelay, `1` keepalive, `2` recv_buffer,
    `3` send_buffer, `4` reuse_address, `5` reuse_port, `6` ip6_only, `7`
    linger). Fields left at their "unset" sentinel are skipped: a buffer size
    of `0` means "leave the OS default", `linger_ms` of `-1` means "no
    `SO_LINGER` override", and `ip6_only` is applied only when `true` (a
    `false` on an IPv4 socket would be rejected as `ENOPROTOOPT`; `false` is
    already the natural IPv4 state). `backlog` / `connect_timeout_ms` are not
    socket options and are intentionally not pushed here.

    Takes a raw `handle_bits` (not a `Socket`) so `SocketOptions` holds NO
    dependency on `Socket` — the one-directional `Socket -> SocketOptions`
    edge the codegen requires.

    ## Examples

        SocketOptions.apply_to_handle(SocketOptions.default(), handle)   # => 0
    """

  @available_on(:network)

  pub fn apply_to_handle(options :: SocketOptions, handle_bits :: u64) -> i64 {
    after_nodelay = SocketOptions.apply_flag(handle_bits, 0, options.nodelay, true, 0)
    after_keepalive = SocketOptions.apply_flag(handle_bits, 1, options.keepalive, true, after_nodelay)
    after_reuse_address = SocketOptions.apply_flag(handle_bits, 4, options.reuse_address, true, after_keepalive)
    after_reuse_port = SocketOptions.apply_flag(handle_bits, 5, options.reuse_port, true, after_reuse_address)
    after_ip6_only = SocketOptions.apply_flag(handle_bits, 6, options.ip6_only, options.ip6_only, after_reuse_port)
    after_recv_buffer = SocketOptions.apply_int(handle_bits, 2, options.recv_buffer, options.recv_buffer > 0, after_ip6_only)
    after_send_buffer = SocketOptions.apply_int(handle_bits, 3, options.send_buffer, options.send_buffer > 0, after_recv_buffer)
    SocketOptions.apply_int(handle_bits, 7, options.linger_ms, options.linger_ms >= 0, after_send_buffer)
  }

  fn apply_flag(handle_bits :: u64, code :: i64, flag :: Bool, should_apply :: Bool, prior :: i64) -> i64 {
    should_set = prior == 0 and should_apply
    case should_set {
      true -> :zig.SocketRuntime.set_option_flag(handle_bits, code, flag)
      false -> prior
    }
  }

  fn apply_int(handle_bits :: u64, code :: i64, value :: i64, should_apply :: Bool, prior :: i64) -> i64 {
    should_set = prior == 0 and should_apply
    case should_set {
      true -> :zig.SocketRuntime.set_option(handle_bits, code, value)
      false -> prior
    }
  }
}
