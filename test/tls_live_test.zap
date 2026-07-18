pub struct TlsLiveTest {
  use Zest.Case

  # Phase S4 (TLS client) OPT-IN live HTTPS exit gate — REAL network, so it is
  # NOT part of the default automated suite. Every test self-skips unless
  # `ZAP_TLS_LIVE=1` is set in the environment, so an ordinary `zap test` run
  # (or a network-less CI) passes trivially. Run it deliberately with:
  #
  #     ZAP_TLS_LIVE=1 zig-out/bin/zap test test/tls_live_test.zap
  #
  # POSITIVE proof: a real verified handshake against example.com:443 succeeds
  # over a good cert and a real HTTP/1.1 GET returns a 200 through the DECRYPTED
  # stream. NEGATIVE proof: verified connects to known-bad-cert hosts
  # (expired / wrong-host / self-signed badssl.com) are REJECTED with
  # `:tls_cert_invalid` — a real bad cert refused over the wire.

  describe("Tls live HTTPS (opt-in: ZAP_TLS_LIVE=1)") {
    test("POSITIVE — connect_host verifies example.com's good cert and a real GET returns HTTP 200") {
      case TlsLiveTest.live_enabled?() {
        true -> assert(TlsLiveTest.https_get_returns_200?())
        false -> assert(true)
      }
    }

    test("NEGATIVE — an EXPIRED cert (expired.badssl.com) is REJECTED with :tls_cert_invalid") {
      case TlsLiveTest.live_enabled?() {
        true -> assert(TlsLiveTest.bad_cert_reason("expired.badssl.com") == :tls_cert_invalid)
        false -> assert(true)
      }
    }

    test("NEGATIVE — a WRONG-HOSTNAME cert (wrong.host.badssl.com) is REJECTED with :tls_cert_invalid") {
      case TlsLiveTest.live_enabled?() {
        true -> assert(TlsLiveTest.bad_cert_reason("wrong.host.badssl.com") == :tls_cert_invalid)
        false -> assert(true)
      }
    }

    test("NEGATIVE — a SELF-SIGNED cert (self-signed.badssl.com) is REJECTED with :tls_cert_invalid") {
      case TlsLiveTest.live_enabled?() {
        true -> assert(TlsLiveTest.bad_cert_reason("self-signed.badssl.com") == :tls_cert_invalid)
        false -> assert(true)
      }
    }

    test("POSITIVE (insecure) — connect_host_insecure to a bad-cert host SUCCEEDS (proves the loud opt-in bypasses verification over the wire)") {
      case TlsLiveTest.live_enabled?() {
        true -> assert(TlsLiveTest.insecure_connects_to_bad_cert?("self-signed.badssl.com"))
        false -> assert(true)
      }
    }
  }

  # ---- helpers ----

  fn live_enabled?() -> Bool {
    System.get_env("ZAP_TLS_LIVE") == "1"
  }

  # A verified HTTPS GET against example.com: the handshake must verify the good
  # cert, and the DECRYPTED response must be a real HTTP/1.1 200. `Connection:
  # close` makes the server close after the response, so `Socket.fold` reads to
  # EOF and returns the whole body.
  fn https_get_returns_200?() -> Bool {
    case Tls.connect_host("example.com", 443, 15000) {
      Result.Error(_e) -> false
      Result.Ok(socket) ->
        {
          _sent = Socket.send(socket, "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")
          response = case Socket.fold(socket, "", 15000, fn(acc :: String, bytes :: String) -> {Atom, String} { {:cont, acc <> bytes} }) {
            Result.Ok(body) -> body
            Result.Error(_e2) -> ""
          }
          _c = Socket.close(socket)
          String.contains?(response, "HTTP/") and String.contains?(response, "200")
        }
    }
  }

  # A verified connect to a known-bad-cert host must FAIL — returns the typed
  # reason atom (expected :tls_cert_invalid), or :unexpected_ok if it wrongly
  # succeeded (a catastrophic verification bypass).
  fn bad_cert_reason(host :: String) -> Atom {
    case Tls.connect_host(host, 443, 15000) {
      Result.Ok(socket) ->
        {
          _c = Socket.close(socket)
          :unexpected_ok
        }
      Result.Error(error) -> error.reason
    }
  }

  # The insecure opt-in over the wire: the SAME bad-cert host the verified path
  # rejects must be ACCEPTED with verification disabled — proving the loud
  # `connect_host_insecure` escape hatch is a real, functioning bypass.
  fn insecure_connects_to_bad_cert?(host :: String) -> Bool {
    case Tls.connect_host_insecure(host, 443, 15000) {
      Result.Ok(socket) ->
        {
          _c = Socket.close(socket)
          true
        }
      Result.Error(_e) -> false
    }
  }

}
