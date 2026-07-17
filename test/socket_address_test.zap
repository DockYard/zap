pub struct SocketAddressTest {
  use Zest.Case

  # The IPv6 completeness gap (P3d): a connection that wins over IPv6 (a
  # `connect_host` Happy-Eyeballs race, §7.2) must introspect HONESTLY —
  # `peer_address`/`local_address` return a real `:ip6` `SocketAddress`, not
  # `:unavailable`. A single i64 cannot carry a 16-byte v6 address, so the
  # runtime surfaces four 32-bit words (`endpoint_v6_word`) + port + scope, and
  # `SocketAddress.ip6_from_words` reconstructs the eight hextets with integer
  # division/remainder (Zap has no bitwise ops). These pin the Zap-side decode +
  # RFC 5952 canonical formatting in isolation; the runtime accessor extraction
  # over a live ::1 connection is pinned by the `socket_io` seam tests.

  describe("SocketAddress :ip4 (unchanged)") {
    test("ip4 constructor formats as dotted-quad with port") {
      assert(SocketAddress.format(SocketAddress.ip4(127, 0, 0, 1, 8080)) == "127.0.0.1:8080")
    }

    test("loopback formats as 127.0.0.1 with port") {
      assert(SocketAddress.format(SocketAddress.loopback(9)) == "127.0.0.1:9")
    }

    test("from_packed decodes a v4 endpoint code byte-identically") {
      # packed(1.2.3.4:80) = ((((1*256+2)*256+3)*256+4)*65536)+80 = 1108152156240
      decoded = SocketAddress.from_packed(1108152156240)
      assert(decoded.family == :ip4)
      assert(decoded.a == 1)
      assert(decoded.b == 2)
      assert(decoded.c == 3)
      assert(decoded.d == 4)
      assert(decoded.port == 80)
      assert(SocketAddress.format(decoded) == "1.2.3.4:80")
    }

    test("from_packed(-1) is :unavailable and formats as \"unavailable\"") {
      unavailable = SocketAddress.from_packed(-1)
      assert(unavailable.family == :unavailable)
      assert(SocketAddress.format(unavailable) == "unavailable")
    }
  }

  describe("SocketAddress :ip6 canonical formatting (RFC 5952)") {
    test("::1 loopback compresses the leading zero run") {
      assert(SocketAddress.format(SocketAddress.ip6_loopback(8080)) == "[::1]:8080")
    }

    test("all-zero address is ::") {
      assert(SocketAddress.format(SocketAddress.ip6(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) == "[::]:0")
    }

    test("a full address with no zero run keeps every hextet (lowercase, no leading zeros)") {
      # 2001:db8:85a3:1:2:8a2e:370:7334
      full = SocketAddress.ip6(8193, 3512, 34211, 1, 2, 35374, 880, 29492, 0, 443)
      assert(SocketAddress.format(full) == "[2001:db8:85a3:1:2:8a2e:370:7334]:443")
    }

    test("a middle zero run compresses to ::") {
      # 2001:db8::1
      assert(SocketAddress.format(SocketAddress.ip6(8193, 3512, 0, 0, 0, 0, 0, 1, 0, 443)) == "[2001:db8::1]:443")
    }

    test("a trailing zero run compresses to ::") {
      # 1::
      assert(SocketAddress.format(SocketAddress.ip6(1, 0, 0, 0, 0, 0, 0, 0, 0, 0)) == "[1::]:0")
    }

    test("the LEFTMOST LONGEST run wins; a shorter earlier run stays uncompressed") {
      # 1:0:0:1:0:0:0:1 — a len-2 run (idx 1-2) and a len-3 run (idx 4-6); the
      # len-3 run is compressed, the len-2 run is written out.
      addr = SocketAddress.ip6(1, 0, 0, 1, 0, 0, 0, 1, 0, 0)
      assert(SocketAddress.format(addr) == "[1:0:0:1::1]:0")
    }

    test("a non-zero zone/scope id is appended as %scope") {
      # fe80::1%3
      addr = SocketAddress.ip6(65152, 0, 0, 0, 0, 0, 0, 1, 3, 8080)
      assert(SocketAddress.format(addr) == "[fe80::1%3]:8080")
    }
  }

  describe("SocketAddress.ip6_from_words (the runtime accessor decode)") {
    test("::1 words (0, 0, 0, 1) reconstruct the ::1 hextets + port") {
      addr = SocketAddress.ip6_from_words(0, 0, 0, 1, 0, 8080)
      assert(addr.family == :ip6)
      assert(addr.h0 == 0)
      assert(addr.h6 == 0)
      assert(addr.h7 == 1)
      assert(addr.port == 8080)
      assert(addr.scope_id == 0)
      assert(SocketAddress.format(addr) == "[::1]:8080")
    }

    test("2001:db8::1 words split each 32-bit word into two hextets") {
      # w0 = 0x2001*65536 + 0x0db8 = 536939960; w1 = 0; w2 = 0; w3 = 1
      addr = SocketAddress.ip6_from_words(536939960, 0, 0, 1, 0, 443)
      assert(addr.h0 == 8193)   # 0x2001
      assert(addr.h1 == 3512)   # 0x0db8
      assert(addr.h7 == 1)
      assert(SocketAddress.format(addr) == "[2001:db8::1]:443")
    }

    test("a word with bit 31 set stays a positive i64 (the reason for 32-bit words, not 64-bit halves)") {
      # 2001:db8:85a3:1:2:8a2e:370:7334 — w1 = 0x85a3*65536 + 0x0001 = 2242052097,
      # a value whose bit 31 is set. As a 32-bit word it stays a positive i64 and
      # decodes cleanly (a 64-bit half with its top bit set would bitcast NEGATIVE
      # and the division/remainder decode could not recover it).
      addr = SocketAddress.ip6_from_words(536939960, 2242052097, 166446, 57701172, 0, 443)
      assert(addr.h2 == 34211)  # 0x85a3
      assert(addr.h3 == 1)
      assert(SocketAddress.format(addr) == "[2001:db8:85a3:1:2:8a2e:370:7334]:443")
    }
  }
}
