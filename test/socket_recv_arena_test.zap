pub struct SocketRecvArenaTest {
  use Zest.Case

  # Gate-OFF recv-arena reset soundness (HIGH-4 memory-exhaustion DoS fix).
  #
  # Gate-OFF, every `Socket.recv` chunk lands in the dedicated, RESETTABLE
  # `gate_off_recv_arena` (NOT the program-lifetime `runtime_arena`), and the
  # loopify back-edge gate resets it to O(chunk) UNLESS a live loop-carried
  # value aliases it. This pins BOTH halves of the soundness contract on the
  # single OS thread (Decision D), using a self-contained loopback pair whose
  # sender half-closes so the peer's fold reaches EOF without a second thread:
  #
  #   * reset FIRES (discarding scalar accumulator): a `Socket.fold` that keeps
  #     only a running byte count must reset the arena every iteration yet still
  #     total every byte exactly — the DoS-closed path (bounded RSS).
  #   * reset SUPPRESSED (retained tuple accumulator): a `Socket.fold` that
  #     stashes the FIRST chunk in a `{Atom, String}` tuple aliases the arena, so
  #     the reset MUST be suppressed for the whole fold; the retained chunk's
  #     marker prefix must survive BYTE-EXACT to the end (a wrongful reset would
  #     let a later recv clobber it — a use-after-free this comparison detects).
  #
  # The payload is 48 KiB, deliberately larger than the 16 KiB next-available
  # recv chunk, so the fold iterates several times (>= 2 back-edge resets after
  # the first chunk) — the multi-recv pressure a wrongful reset needs to corrupt
  # the retained chunk. The heavier aliasing matrix (raw-chunk / List / concat
  # shapes, and the RSS-flat vs control-grows DoS measurement) runs as the
  # standalone gate-OFF exes under the socket campaign's measurement harness.

  fn marker() -> String { "RECVARENA_MARKER" }

  # 16 (marker) + 16 * 3071 = 49152 bytes = exactly 3 * 16 KiB.
  fn payload() -> String { SocketRecvArenaTest.marker() <> String.repeat("0123456789ABCDEF", 3071) }

  fn payload_len() -> i64 { 49152 }

  # ---- reset FIRES: discarding scalar fold totals every byte ----------------

  fn discard_total() -> i64 {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> SocketRecvArenaTest.discard_after_listen(listener)
    }
  }

  fn discard_after_listen(listener :: SocketListener) -> i64 {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(client) -> SocketRecvArenaTest.discard_after_connect(listener, client)
    }
  }

  fn discard_after_connect(listener :: SocketListener, client :: Socket) -> i64 {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          -1
        }
      Result.Ok(server) -> SocketRecvArenaTest.discard_exchange(listener, client, server)
    }
  }

  fn discard_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> i64 {
    _sent = Socket.send(server, SocketRecvArenaTest.payload())
    _shut = Socket.shutdown(server, :write)
    outcome = Socket.fold(client, 0, 5000, &SocketRecvArenaTest.count_bytes/2)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    case outcome {
      Result.Ok(total) -> total
      Result.Error(_e) -> -1
    }
  }

  fn count_bytes(acc :: i64, bytes :: String) -> {Atom, i64} {
    {:cont, acc + String.length(bytes)}
  }

  # ---- reset SUPPRESSED: retained tuple keeps the first chunk byte-exact -----

  fn retained_first_chunk() -> Atom {
    case Socket.listen(SocketAddress.loopback(0), 8) {
      Result.Error(_e) -> :listen_failed
      Result.Ok(listener) -> SocketRecvArenaTest.retained_after_listen(listener)
    }
  }

  fn retained_after_listen(listener :: SocketListener) -> Atom {
    port = SocketListener.local_port(listener)
    case Socket.connect(SocketAddress.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = SocketListener.close(listener)
          :connect_failed
        }
      Result.Ok(client) -> SocketRecvArenaTest.retained_after_connect(listener, client)
    }
  }

  fn retained_after_connect(listener :: SocketListener, client :: Socket) -> Atom {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = SocketListener.close(listener)
          :accept_failed
        }
      Result.Ok(server) -> SocketRecvArenaTest.retained_exchange(listener, client, server)
    }
  }

  fn retained_exchange(listener :: SocketListener, client :: Socket, server :: Socket) -> Atom {
    _sent = Socket.send(server, SocketRecvArenaTest.payload())
    _shut = Socket.shutdown(server, :write)
    outcome = Socket.fold(client, {:pending, ""}, 5000, &SocketRecvArenaTest.keep_first/2)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = SocketListener.close(listener)
    case outcome {
      Result.Ok(pair) -> SocketRecvArenaTest.verify_first(pair)
      Result.Error(_e) -> :fold_error
    }
  }

  # Stash the FIRST chunk and hold it unchanged for every later iteration — the
  # retained String aliases the recv arena across the whole fold, so the reset
  # must stay suppressed the entire time.
  fn keep_first(acc :: {Atom, String}, bytes :: String) -> {Atom, {Atom, String}} {
    case acc {
      {:got, saved} -> {:cont, {:got, saved}}
      {_tag, _e} -> {:cont, {:got, bytes}}
    }
  }

  # The retained first chunk must still start with the marker. Had a wrongful
  # reset fired while it was live, a later recv would have overwritten the marker
  # prefix — so an intact marker is the use-after-free proof.
  fn verify_first(pair :: {Atom, String}) -> Atom {
    case pair {
      {:got, saved} -> SocketRecvArenaTest.marker_verdict(String.starts_with?(saved, SocketRecvArenaTest.marker()))
      {_t, _s} -> :fail_no_chunk
    }
  }

  fn marker_verdict(ok :: Bool) -> Atom {
    case ok {
      true -> :ok
      false -> :fail_marker_clobbered
    }
  }

  # ------------------------------------------------------------------------

  describe("Socket gate-OFF recv-arena reset soundness (HIGH-4)") {
    test("discarding scalar fold resets the recv arena yet totals every byte") {
      base = Socket.live_count()
      assert(SocketRecvArenaTest.discard_total() == SocketRecvArenaTest.payload_len())
      assert(Socket.live_count() == base)
    }

    test("retained tuple fold suppresses the reset; the first chunk stays byte-exact (no UAF)") {
      base = Socket.live_count()
      assert(SocketRecvArenaTest.retained_first_chunk() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
