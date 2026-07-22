@doc = """
  `Socket.Address` — a sendable value naming a socket endpoint.

  It carries the address `family` and the endpoint's `port`. For an `:ip4`
  endpoint the four octets `a`/`b`/`c`/`d` are meaningful; for an `:ip6`
  endpoint the eight hextets `h0`..`h7` (each a 16-bit group, `0..65535`) and the
  IPv6 zone `scope_id` are meaningful; for a `:unix` (Unix-domain, Phase S2)
  endpoint the `path` is meaningful (a filesystem path, or a `@`-prefixed Linux
  abstract-namespace name). `:unavailable` names an unbound/unconnected
  endpoint. Being a plain struct of sendable scalars plus a `String` path it can
  travel in a message like any other value.

  A `:ip6` endpoint arises when a `Socket.connect_host` Happy-Eyeballs race
  (§7.2, RFC 8305) wins over IPv6: `Socket.peer_address`/`local_address` then
  return a real `:ip6` `Socket.Address` (the runtime carries the v6 bytes
  honestly and reconstructs them across the ABI as four 32-bit words — a single
  i64 cannot hold a 16-byte address). Explicit dialing (`Socket.connect`/
  `connect_to`/`listen`) is IPv4 in this phase.

  DNS resolution lives *inside* `Socket.connect_host(host, port, timeout_ms)`
  (§7.2 — RFC 8305 Happy Eyeballs racing over the resolved addresses); a
  `Socket.Address` produced by `ip4`/`ip6`/`loopback` is always an explicit,
  already-resolved endpoint.

  Only available on targets with the `:network` capability.

  ## Examples

      Socket.Address.loopback(8080)
      Socket.Address.ip4(127, 0, 0, 1, 8080)
      Socket.Address.ip6_loopback(8080)
      Socket.Address.format(Socket.Address.ip6_loopback(8080))   # => "[::1]:8080"
  """

@available_on(:network)

pub struct Socket.Address {
  family :: Atom = :ip4
  a :: i64 = 0
  b :: i64 = 0
  c :: i64 = 0
  d :: i64 = 0
  port :: i64 = 0
  h0 :: i64 = 0
  h1 :: i64 = 0
  h2 :: i64 = 0
  h3 :: i64 = 0
  h4 :: i64 = 0
  h5 :: i64 = 0
  h6 :: i64 = 0
  h7 :: i64 = 0
  scope_id :: i64 = 0
  path :: String = ""

  @doc = """
    Builds an IPv4 address from its four octets and a port.

    ## Examples

        Socket.Address.ip4(93, 184, 216, 34, 80)
    """

  @available_on(:network)

  pub fn ip4(a :: i64, b :: i64, c :: i64, d :: i64, port :: i64) -> Socket.Address {
    %Socket.Address{family: :ip4, a: a, b: b, c: c, d: d, port: port}
  }

  @doc = """
    Builds the IPv4 loopback address (`127.0.0.1`) on `port` — the endpoint
    the S0 loopback exit gate connects to.

    ## Examples

        Socket.Address.loopback(0)   # an ephemeral-port loopback endpoint
    """

  @available_on(:network)

  pub fn loopback(port :: i64) -> Socket.Address {
    %Socket.Address{family: :ip4, a: 127, b: 0, c: 0, d: 1, port: port}
  }

  @doc = """
    Builds an IPv6 address from its eight hextets (`h0`..`h7`, each a 16-bit
    group in `0..65535`, most-significant first), an IPv6 zone `scope_id` (`0` =
    none), and a `port`.

    ## Examples

        # 2001:db8::1 on port 443
        Socket.Address.ip6(8193, 3512, 0, 0, 0, 0, 0, 1, 0, 443)
    """

  @available_on(:network)

  pub fn ip6(h0 :: i64, h1 :: i64, h2 :: i64, h3 :: i64, h4 :: i64, h5 :: i64, h6 :: i64, h7 :: i64, scope_id :: i64, port :: i64) -> Socket.Address {
    %Socket.Address{family: :ip6, h0: h0, h1: h1, h2: h2, h3: h3, h4: h4, h5: h5, h6: h6, h7: h7, scope_id: scope_id, port: port}
  }

  @doc = """
    Builds the IPv6 loopback address (`::1`) on `port`.

    ## Examples

        Socket.Address.format(Socket.Address.ip6_loopback(80))   # => "[::1]:80"
    """

  @available_on(:network)

  pub fn ip6_loopback(port :: i64) -> Socket.Address {
    Socket.Address.ip6(0, 0, 0, 0, 0, 0, 0, 1, 0, port)
  }

  @doc = """
    Builds a Unix-domain (`:unix`) address from a socket `path` (Phase S2) — the
    endpoint a `Socket.Datagram.bind`/`send_to` or a `Socket.connect`/`listen`
    over the Unix-domain names. A plain path is a FILESYSTEM socket (the caller
    manages the socket file — unlink it before re-binding); a `@`-prefixed path
    is a Linux ABSTRACT-namespace name (no filesystem entry, auto-cleaned when
    the last handle closes — ideal for hermetic tests, Linux-only). The portable
    path cap is 104 bytes; a longer path is rejected by the runtime as `:einval`.

    ## Examples

        Socket.Address.unix("/tmp/app.sock")
        Socket.Address.unix("@app-abstract")   # Linux abstract namespace
    """

  @available_on(:network)

  pub fn unix(path :: String) -> Socket.Address {
    %Socket.Address{family: :unix, path: path}
  }

  @doc = """
    Reconstructs a `:unix` `Socket.Address` from a `path` — the decoder companion
    to `unix/1` (identical result), named for symmetry with `from_packed`/
    `ip6_from_words`. Kept distinct so a future path-bearing peer readback has a
    single decode point to route through.

    ## Examples

        Socket.Address.unix_from_path("/tmp/app.sock")
    """

  @available_on(:network)

  pub fn unix_from_path(path :: String) -> Socket.Address {
    %Socket.Address{family: :unix, path: path}
  }

  @doc = """
    Unpacks a runtime v4 endpoint code
    (`((((a*256+b)*256+c)*256+d)*65536)+port`, or `-1` when unavailable) into a
    `Socket.Address` (Phase S1). Integer division only — Zap has no bitwise ops
    and needs none here. An unavailable endpoint yields
    `%Socket.Address{family: :unavailable}`. This is the IPv4 decode; a v6
    endpoint (which cannot fit one i64) is reconstructed by `ip6_from_words`.
    Lives here (with the address it produces) so both `Socket.local_address`/
    `peer_address` and `Socket.Listener.local_address` reuse it without a
    `Socket ↔ Socket.Listener` cross-call.

    ## Examples

        Socket.Address.from_packed(-1)   # => %Socket.Address{family: :unavailable}
    """

  @available_on(:network)

  pub fn from_packed(packed :: i64) -> Socket.Address {
    case packed < 0 {
      true -> %Socket.Address{family: :unavailable}
      false ->
        {
          port = Integer.remainder(packed, 65536)
          host = packed / 65536
          d = Integer.remainder(host, 256)
          c = Integer.remainder(host / 256, 256)
          b = Integer.remainder(host / 65536, 256)
          a = host / 16777216
          %Socket.Address{family: :ip4, a: a, b: b, c: c, d: d, port: port}
        }
    }
  }

  @doc = """
    Reconstructs an `:ip6` `Socket.Address` from the runtime's four 32-bit
    big-endian address words (`w0`..`w3`, each `0..2^32-1`, network order), the
    IPv6 `scope_id`, and the `port` — the values the
    `:zig.SocketRuntime.endpoint_v6_word`/`endpoint_scope`/`endpoint_port`
    accessors return for a v6 connection. Each word splits into its two hextets
    with plain integer division/remainder (Zap has no bitwise ops); a 16-byte v6
    address cannot fit the single packed i64 `from_packed` decodes, which is why
    it is surfaced as words rather than one code.

    ## Examples

        # ::1 (words 0, 0, 0, 1) on port 8080
        Socket.Address.format(Socket.Address.ip6_from_words(0, 0, 0, 1, 0, 8080))   # => "[::1]:8080"
    """

  @available_on(:network)

  pub fn ip6_from_words(w0 :: i64, w1 :: i64, w2 :: i64, w3 :: i64, scope_id :: i64, port :: i64) -> Socket.Address {
    h0 = w0 / 65536
    h1 = Integer.remainder(w0, 65536)
    h2 = w1 / 65536
    h3 = Integer.remainder(w1, 65536)
    h4 = w2 / 65536
    h5 = Integer.remainder(w2, 65536)
    h6 = w3 / 65536
    h7 = Integer.remainder(w3, 65536)
    Socket.Address.ip6(h0, h1, h2, h3, h4, h5, h6, h7, scope_id, port)
  }

  @doc = """
    Resolves the endpoint (`which` `0` = local/`getsockname`, `1` = peer/
    `getpeername`) of a socket `handle_bits` into a `Socket.Address`,
    transparently across ALL address families — the SINGLE decode point every
    `local_address`/`peer_address` routes through (both the stream `Socket` and
    the `Socket.Datagram`). The v4 fast path is BYTE-IDENTICAL to the packed
    decode (`endpoint` → `from_packed`, NO extra runtime call); a non-v4 endpoint
    packs as `-1`, and the accessor path then disambiguates: a v6 endpoint
    reconstructs from the four 32-bit words (`endpoint_v6_word`, the first word
    `-1` = "not v6"), and a Unix endpoint surfaces its `sun_path`
    (`endpoint_unix_path` → a String → `unix_from_path`). An unnamed/unbound
    endpoint (no v4, no v6, empty path) is `:unavailable`. Only a non-v4 endpoint
    incurs the extra accessor reads.

    ## Examples

        Socket.Address.of_handle(handle, 0)   # the local endpoint
    """

  @available_on(:network)

  pub fn of_handle(handle_bits :: u64, which :: i64) -> Socket.Address {
    packed = :zig.SocketRuntime.endpoint(handle_bits, which)
    case packed < 0 {
      false -> Socket.Address.from_packed(packed)
      true ->
        {
          word0 = :zig.SocketRuntime.endpoint_v6_word(handle_bits, which, 0)
          case word0 < 0 {
            false ->
              {
                word1 = :zig.SocketRuntime.endpoint_v6_word(handle_bits, which, 1)
                word2 = :zig.SocketRuntime.endpoint_v6_word(handle_bits, which, 2)
                word3 = :zig.SocketRuntime.endpoint_v6_word(handle_bits, which, 3)
                scope_id = :zig.SocketRuntime.endpoint_scope(handle_bits, which)
                port = :zig.SocketRuntime.endpoint_port(handle_bits, which)
                Socket.Address.ip6_from_words(word0, word1, word2, word3, scope_id, port)
              }
            true -> Socket.Address.of_unix_handle(handle_bits, which)
          }
        }
    }
  }

  @doc = """
    Resolves a non-v4/non-v6 endpoint (`which` `0` local, `1` peer) of
    `handle_bits` to a `:unix` `Socket.Address` carrying the socket `sun_path`, or
    `:unavailable` when the endpoint has no path (an unnamed/unbound Unix socket,
    or a genuinely unavailable endpoint). The `sun_path` crosses the ABI as bytes
    → a Zap String (`endpoint_unix_path`) → `unix_from_path` — the stream/datagram
    twin of the datagram `recv_from` peer-path readback.
    """

  @available_on(:network)

  fn of_unix_handle(handle_bits :: u64, which :: i64) -> Socket.Address {
    path = :zig.SocketRuntime.endpoint_unix_path(handle_bits, which)
    case String.length(path) == 0 {
      true -> %Socket.Address{family: :unavailable}
      false -> Socket.Address.unix_from_path(path)
    }
  }

  @doc = """
    Renders a `Socket.Address` as its canonical textual form with the port:
    `"a.b.c.d:port"` for `:ip4`, the bracketed RFC 5952 form `"[address]:port"`
    for `:ip6` (lowercase hextets, no leading zeros, the longest run of zero
    hextets compressed to `::`, a non-zero zone appended as `%scope_id`),
    `"unix:<path>"` for a `:unix` endpoint, and `"unavailable"` for an
    unbound/unconnected endpoint.

    ## Examples

        Socket.Address.format(Socket.Address.ip4(127, 0, 0, 1, 8080))   # => "127.0.0.1:8080"
        Socket.Address.format(Socket.Address.ip6_loopback(8080))        # => "[::1]:8080"
    """

  @available_on(:network)

  pub fn format(address :: Socket.Address) -> String {
    case address.family {
      :ip4 ->
        Integer.to_string(address.a) <> "." <> Integer.to_string(address.b) <> "." <> Integer.to_string(address.c) <> "." <> Integer.to_string(address.d) <> ":" <> Integer.to_string(address.port)
      :ip6 ->
        {
          zone = case address.scope_id == 0 {
            true -> ""
            false -> "%" <> Integer.to_string(address.scope_id)
          }
          "[" <> Socket.Address.ip6_body(address) <> zone <> "]:" <> Integer.to_string(address.port)
        }
      :unix -> "unix:" <> address.path
      _ -> "unavailable"
    }
  }

  @doc = """
    The bracket-less canonical IPv6 body of an `:ip6` `Socket.Address` — the eight
    hextets rendered lowercase without leading zeros, with the LEFTMOST LONGEST
    run of two-or-more consecutive zero hextets compressed to `::` (RFC 5952). A
    lone zero hextet is never compressed; an all-zero address renders `::`.
    """

  @available_on(:network)

  fn ip6_body(address :: Socket.Address) -> String {
    case Socket.Address.longest_zero_run(address, 0, 0, 0, 0, 0) {
      {start, length} ->
        case length < 2 {
          true -> Socket.Address.join_hextets(address, 0, 8)
          false ->
            Socket.Address.join_hextets(address, 0, start) <> "::" <> Socket.Address.join_hextets(address, start + length, 8)
        }
    }
  }

  @doc = """
    The hextet (`0..65535`) at position `index` (`0..7`) of an `:ip6`
    `Socket.Address` — a fixed-position accessor over the eight `h0`..`h7` fields,
    so the scan/join can walk the address by index without a heap list.
    """

  @available_on(:network)

  fn hextet_at(address :: Socket.Address, index :: i64) -> i64 {
    case index {
      0 -> address.h0
      1 -> address.h1
      2 -> address.h2
      3 -> address.h3
      4 -> address.h4
      5 -> address.h5
      6 -> address.h6
      _ -> address.h7
    }
  }

  @doc = """
    Scans the eight hextets for the leftmost longest run of consecutive zeros,
    returning `{start, length}` (a `length` of `0` or `1` means no `::`
    compression applies). Strict `>` on the length keeps the LEFTMOST run when
    two runs tie, as RFC 5952 requires. Tail-recursive over the fixed eight
    positions.
    """

  @available_on(:network)

  fn longest_zero_run(address :: Socket.Address, index :: i64, current_start :: i64, current_length :: i64, best_start :: i64, best_length :: i64) -> {i64, i64} {
    case index >= 8 {
      true -> {best_start, best_length}
      false ->
        case Socket.Address.hextet_at(address, index) == 0 {
          true ->
            {
              run_start = case current_length == 0 {
                true -> index
                false -> current_start
              }
              run_length = current_length + 1
              case run_length > best_length {
                true -> Socket.Address.longest_zero_run(address, index + 1, run_start, run_length, run_start, run_length)
                false -> Socket.Address.longest_zero_run(address, index + 1, run_start, run_length, best_start, best_length)
              }
            }
          false -> Socket.Address.longest_zero_run(address, index + 1, 0, 0, best_start, best_length)
        }
    }
  }

  @doc = """
    Joins the hextets in the half-open range `[from, to)` as lowercase
    colon-separated hex, or `""` when the range is empty (`from >= to`) — the
    segment builder either side of a `::` compression.
    """

  @available_on(:network)

  fn join_hextets(address :: Socket.Address, from :: i64, to :: i64) -> String {
    case from >= to {
      true -> ""
      false ->
        {
          head = Socket.Address.hextet_hex(Socket.Address.hextet_at(address, from))
          case from + 1 >= to {
            true -> head
            false -> head <> ":" <> Socket.Address.join_hextets(address, from + 1, to)
          }
        }
    }
  }

  @doc = """
    Renders one hextet (`0..65535`) as lowercase hex without leading zeros
    (`0` → `"0"`, `3512` → `"db8"`, `65535` → `"ffff"`). Recurses over the nibbles
    via integer division/remainder by 16.
    """

  @available_on(:network)

  fn hextet_hex(value :: i64) -> String {
    case value < 16 {
      true -> Socket.Address.hex_digit(value)
      false -> Socket.Address.hextet_hex(value / 16) <> Socket.Address.hex_digit(Integer.remainder(value, 16))
    }
  }

  @doc = """
    Maps a single nibble (`0..15`) to its lowercase hex digit string.
    """

  @available_on(:network)

  fn hex_digit(nibble :: i64) -> String {
    case nibble {
      0 -> "0"
      1 -> "1"
      2 -> "2"
      3 -> "3"
      4 -> "4"
      5 -> "5"
      6 -> "6"
      7 -> "7"
      8 -> "8"
      9 -> "9"
      10 -> "a"
      11 -> "b"
      12 -> "c"
      13 -> "d"
      14 -> "e"
      _ -> "f"
    }
  }
}
