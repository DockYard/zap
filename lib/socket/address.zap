@doc = """
  `SocketAddress` — a sendable value naming a socket endpoint.

  It carries the address `family` and the endpoint's `port`. For an `:ip4`
  endpoint the four octets `a`/`b`/`c`/`d` are meaningful; for an `:ip6`
  endpoint the eight hextets `h0`..`h7` (each a 16-bit group, `0..65535`) and the
  IPv6 zone `scope_id` are meaningful. `:unavailable` names an
  unbound/unconnected endpoint. Being a plain struct of sendable scalars it can
  travel in a message like any other value.

  A `:ip6` endpoint arises when a `Socket.connect_host` Happy-Eyeballs race
  (§7.2, RFC 8305) wins over IPv6: `Socket.peer_address`/`local_address` then
  return a real `:ip6` `SocketAddress` (the runtime carries the v6 bytes
  honestly and reconstructs them across the ABI as four 32-bit words — a single
  i64 cannot hold a 16-byte address). Explicit dialing (`Socket.connect`/
  `connect_to`/`listen`) is IPv4 in this phase.

  DNS resolution lives *inside* `Socket.connect_host(host, port, timeout_ms)`
  (§7.2 — RFC 8305 Happy Eyeballs racing over the resolved addresses); a
  `SocketAddress` produced by `ip4`/`ip6`/`loopback` is always an explicit,
  already-resolved endpoint.

  Only available on targets with the `:network` capability.

  ## Examples

      SocketAddress.loopback(8080)
      SocketAddress.ip4(127, 0, 0, 1, 8080)
      SocketAddress.ip6_loopback(8080)
      SocketAddress.format(SocketAddress.ip6_loopback(8080))   # => "[::1]:8080"
  """

@available_on(:network)

pub struct SocketAddress {
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
    Builds an IPv6 address from its eight hextets (`h0`..`h7`, each a 16-bit
    group in `0..65535`, most-significant first), an IPv6 zone `scope_id` (`0` =
    none), and a `port`.

    ## Examples

        # 2001:db8::1 on port 443
        SocketAddress.ip6(8193, 3512, 0, 0, 0, 0, 0, 1, 0, 443)
    """

  @available_on(:network)

  pub fn ip6(h0 :: i64, h1 :: i64, h2 :: i64, h3 :: i64, h4 :: i64, h5 :: i64, h6 :: i64, h7 :: i64, scope_id :: i64, port :: i64) -> SocketAddress {
    %SocketAddress{family: :ip6, h0: h0, h1: h1, h2: h2, h3: h3, h4: h4, h5: h5, h6: h6, h7: h7, scope_id: scope_id, port: port}
  }

  @doc = """
    Builds the IPv6 loopback address (`::1`) on `port`.

    ## Examples

        SocketAddress.format(SocketAddress.ip6_loopback(80))   # => "[::1]:80"
    """

  @available_on(:network)

  pub fn ip6_loopback(port :: i64) -> SocketAddress {
    SocketAddress.ip6(0, 0, 0, 0, 0, 0, 0, 1, 0, port)
  }

  @doc = """
    Unpacks a runtime v4 endpoint code
    (`((((a*256+b)*256+c)*256+d)*65536)+port`, or `-1` when unavailable) into a
    `SocketAddress` (Phase S1). Integer division only — Zap has no bitwise ops
    and needs none here. An unavailable endpoint yields
    `%SocketAddress{family: :unavailable}`. This is the IPv4 decode; a v6
    endpoint (which cannot fit one i64) is reconstructed by `ip6_from_words`.
    Lives here (with the address it produces) so both `Socket.local_address`/
    `peer_address` and `SocketListener.local_address` reuse it without a
    `Socket ↔ SocketListener` cross-call.

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

  @doc = """
    Reconstructs an `:ip6` `SocketAddress` from the runtime's four 32-bit
    big-endian address words (`w0`..`w3`, each `0..2^32-1`, network order), the
    IPv6 `scope_id`, and the `port` — the values the
    `:zig.SocketRuntime.endpoint_v6_word`/`endpoint_scope`/`endpoint_port`
    accessors return for a v6 connection. Each word splits into its two hextets
    with plain integer division/remainder (Zap has no bitwise ops); a 16-byte v6
    address cannot fit the single packed i64 `from_packed` decodes, which is why
    it is surfaced as words rather than one code.

    ## Examples

        # ::1 (words 0, 0, 0, 1) on port 8080
        SocketAddress.format(SocketAddress.ip6_from_words(0, 0, 0, 1, 0, 8080))   # => "[::1]:8080"
    """

  @available_on(:network)

  pub fn ip6_from_words(w0 :: i64, w1 :: i64, w2 :: i64, w3 :: i64, scope_id :: i64, port :: i64) -> SocketAddress {
    h0 = w0 / 65536
    h1 = Integer.remainder(w0, 65536)
    h2 = w1 / 65536
    h3 = Integer.remainder(w1, 65536)
    h4 = w2 / 65536
    h5 = Integer.remainder(w2, 65536)
    h6 = w3 / 65536
    h7 = Integer.remainder(w3, 65536)
    SocketAddress.ip6(h0, h1, h2, h3, h4, h5, h6, h7, scope_id, port)
  }

  @doc = """
    Renders a `SocketAddress` as its canonical textual form with the port:
    `"a.b.c.d:port"` for `:ip4`, the bracketed RFC 5952 form `"[address]:port"`
    for `:ip6` (lowercase hextets, no leading zeros, the longest run of zero
    hextets compressed to `::`, a non-zero zone appended as `%scope_id`), and
    `"unavailable"` for an unbound/unconnected endpoint.

    ## Examples

        SocketAddress.format(SocketAddress.ip4(127, 0, 0, 1, 8080))   # => "127.0.0.1:8080"
        SocketAddress.format(SocketAddress.ip6_loopback(8080))        # => "[::1]:8080"
    """

  @available_on(:network)

  pub fn format(address :: SocketAddress) -> String {
    case address.family {
      :ip4 ->
        Integer.to_string(address.a) <> "." <> Integer.to_string(address.b) <> "." <> Integer.to_string(address.c) <> "." <> Integer.to_string(address.d) <> ":" <> Integer.to_string(address.port)
      :ip6 ->
        {
          zone = case address.scope_id == 0 {
            true -> ""
            false -> "%" <> Integer.to_string(address.scope_id)
          }
          "[" <> SocketAddress.ip6_body(address) <> zone <> "]:" <> Integer.to_string(address.port)
        }
      _ -> "unavailable"
    }
  }

  @doc = """
    The bracket-less canonical IPv6 body of an `:ip6` `SocketAddress` — the eight
    hextets rendered lowercase without leading zeros, with the LEFTMOST LONGEST
    run of two-or-more consecutive zero hextets compressed to `::` (RFC 5952). A
    lone zero hextet is never compressed; an all-zero address renders `::`.
    """

  @available_on(:network)

  fn ip6_body(address :: SocketAddress) -> String {
    case SocketAddress.longest_zero_run(address, 0, 0, 0, 0, 0) {
      {start, length} ->
        case length < 2 {
          true -> SocketAddress.join_hextets(address, 0, 8)
          false ->
            SocketAddress.join_hextets(address, 0, start) <> "::" <> SocketAddress.join_hextets(address, start + length, 8)
        }
    }
  }

  @doc = """
    The hextet (`0..65535`) at position `index` (`0..7`) of an `:ip6`
    `SocketAddress` — a fixed-position accessor over the eight `h0`..`h7` fields,
    so the scan/join can walk the address by index without a heap list.
    """

  @available_on(:network)

  fn hextet_at(address :: SocketAddress, index :: i64) -> i64 {
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

  fn longest_zero_run(address :: SocketAddress, index :: i64, current_start :: i64, current_length :: i64, best_start :: i64, best_length :: i64) -> {i64, i64} {
    case index >= 8 {
      true -> {best_start, best_length}
      false ->
        case SocketAddress.hextet_at(address, index) == 0 {
          true ->
            {
              run_start = case current_length == 0 {
                true -> index
                false -> current_start
              }
              run_length = current_length + 1
              case run_length > best_length {
                true -> SocketAddress.longest_zero_run(address, index + 1, run_start, run_length, run_start, run_length)
                false -> SocketAddress.longest_zero_run(address, index + 1, run_start, run_length, best_start, best_length)
              }
            }
          false -> SocketAddress.longest_zero_run(address, index + 1, 0, 0, best_start, best_length)
        }
    }
  }

  @doc = """
    Joins the hextets in the half-open range `[from, to)` as lowercase
    colon-separated hex, or `""` when the range is empty (`from >= to`) — the
    segment builder either side of a `::` compression.
    """

  @available_on(:network)

  fn join_hextets(address :: SocketAddress, from :: i64, to :: i64) -> String {
    case from >= to {
      true -> ""
      false ->
        {
          head = SocketAddress.hextet_hex(SocketAddress.hextet_at(address, from))
          case from + 1 >= to {
            true -> head
            false -> head <> ":" <> SocketAddress.join_hextets(address, from + 1, to)
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
      true -> SocketAddress.hex_digit(value)
      false -> SocketAddress.hextet_hex(value / 16) <> SocketAddress.hex_digit(Integer.remainder(value, 16))
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
