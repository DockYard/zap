pub struct SocketXfoldUafTest {
  use Zest.Case

  # ------------------------------------------------------------------------
  # CROSS-FOLD recv-chunk ESCAPE probe (loop-entry WATERMARK reset).
  #
  # A recv chunk that ESCAPES its producing `Socket.fold` (returned in the
  # accumulator, or a bare `Socket.recv` held in an enclosing frame) is NOT a
  # loop-carried slot of a LATER `Socket.fold`. If the later fold's back-edge
  # reset of the SHARED per-process recv arena fires — which it does for a scalar
  # accumulator — a reset-to-empty (`.retain_capacity`) frees/reallocs the oldest
  # backing node and clobbers the escaped chunk => use-after-free. The watermark
  # reset (`resetToMark` back to the LATER fold's loop-entry high-water) keeps the
  # escaped chunk (below the mark) byte-stable, so it survives.
  #
  # The bare-recv shape clobbers deterministically PRE-fix with NO env var (direct
  # offset reuse); the fold-escape shape is a realloc-move that MallocScribble=1
  # makes observable. POST-fix both survive byte-exact under both gates.
  # ------------------------------------------------------------------------

  fn marker_a() -> String { "AAAA_FOLDA_CHUNK" }

  # 48 KiB; first 16 bytes are marker_a.
  fn payload_a() -> String { SocketXfoldUafTest.marker_a() <> String.repeat("aaaaaaaaaaaaaaaa", 3071) }

  # 48 KiB of 'B' — different first bytes from marker_a (a clobber is visible),
  # large enough to force fold B to reset several times.
  fn payload_b() -> String { String.repeat("BBBBBBBBBBBBBBBB", 3072) }

  # ---- Phase 1: fold A retains + RETURNS its FIRST chunk (escapes) ----

  fn escaped_from_a() -> {Atom, String} {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> {:err_listen, ""}
      Result.Ok(listener) -> SocketXfoldUafTest.a_after_listen(listener)
    }
  }

  fn a_after_listen(listener :: Socket.Listener) -> {Atom, String} {
    port = Socket.Listener.local_port(listener)
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = Socket.Listener.close(listener)
          {:err_connect, ""}
        }
      Result.Ok(client) -> SocketXfoldUafTest.a_after_connect(listener, client)
    }
  }

  fn a_after_connect(listener :: Socket.Listener, client :: Socket) -> {Atom, String} {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          {:err_accept, ""}
        }
      Result.Ok(server) -> SocketXfoldUafTest.a_exchange(listener, client, server)
    }
  }

  fn a_exchange(listener :: Socket.Listener, client :: Socket, server :: Socket) -> {Atom, String} {
    _sent = Socket.send(server, SocketXfoldUafTest.payload_a())
    _shut = Socket.shutdown(server, :write)
    outcome = Socket.fold(client, {:pending, ""}, 5000, &SocketXfoldUafTest.keep_first/2)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = Socket.Listener.close(listener)
    case outcome {
      Result.Ok(pair) -> pair
      Result.Error(_e) -> {:err_fold, ""}
    }
  }

  fn keep_first(acc :: {Atom, String}, bytes :: String) -> {Atom, {Atom, String}} {
    case acc {
      {:got, saved} -> {:cont, {:got, saved}}
      {_tag, _e} -> {:cont, {:got, bytes}}
    }
  }

  # ---- Phase 2: fold B scalar over a FRESH socket forces the shared arena reset ----

  fn scalar_fold_b() -> i64 {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> -1
      Result.Ok(listener) -> SocketXfoldUafTest.b_after_listen(listener)
    }
  }

  fn b_after_listen(listener :: Socket.Listener) -> i64 {
    port = Socket.Listener.local_port(listener)
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = Socket.Listener.close(listener)
          -1
        }
      Result.Ok(client) -> SocketXfoldUafTest.b_after_connect(listener, client)
    }
  }

  fn b_after_connect(listener :: Socket.Listener, client :: Socket) -> i64 {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          -1
        }
      Result.Ok(server) -> SocketXfoldUafTest.b_exchange(listener, client, server)
    }
  }

  fn b_exchange(listener :: Socket.Listener, client :: Socket, server :: Socket) -> i64 {
    _sent = Socket.send(server, SocketXfoldUafTest.payload_b())
    _shut = Socket.shutdown(server, :write)
    outcome = Socket.fold(client, 0, 5000, &SocketXfoldUafTest.count_bytes/2)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = Socket.Listener.close(listener)
    case outcome {
      Result.Ok(total) -> total
      Result.Error(_e) -> -1
    }
  }

  fn count_bytes(acc :: i64, bytes :: String) -> {Atom, i64} {
    {:cont, acc + String.length(bytes)}
  }

  # ---- Cross-fold check: x from A must survive B ----

  fn cross_fold_check() -> Atom {
    case SocketXfoldUafTest.escaped_from_a() {
      {:got, x} -> SocketXfoldUafTest.after_escape(x)
      {_t, _s} -> :fail_setup_a
    }
  }

  fn after_escape(x :: String) -> Atom {
    _total = SocketXfoldUafTest.scalar_fold_b()
    case String.starts_with?(x, SocketXfoldUafTest.marker_a()) {
      true -> :ok
      false -> :fail_clobbered
    }
  }

  # ==== Bare-recv escape variant: a single Socket.recv chunk held across a fold ====

  fn escaped_bare_recv() -> {Atom, String} {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> {:err_listen, ""}
      Result.Ok(listener) -> SocketXfoldUafTest.br_after_listen(listener)
    }
  }

  fn br_after_listen(listener :: Socket.Listener) -> {Atom, String} {
    port = Socket.Listener.local_port(listener)
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = Socket.Listener.close(listener)
          {:err_connect, ""}
        }
      Result.Ok(client) -> SocketXfoldUafTest.br_after_connect(listener, client)
    }
  }

  fn br_after_connect(listener :: Socket.Listener, client :: Socket) -> {Atom, String} {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          {:err_accept, ""}
        }
      Result.Ok(server) -> SocketXfoldUafTest.br_exchange(listener, client, server)
    }
  }

  fn br_exchange(listener :: Socket.Listener, client :: Socket, server :: Socket) -> {Atom, String} {
    _sent = Socket.send(server, SocketXfoldUafTest.payload_a())
    _shut = Socket.shutdown(server, :write)
    got = SocketXfoldUafTest.first_chunk_of(client)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = Socket.Listener.close(listener)
    got
  }

  # A SINGLE recv — the chunk escapes into the enclosing frame with no fold loop
  # to probe it at all.
  fn first_chunk_of(client :: Socket) -> {Atom, String} {
    case Socket.recv(client, 0, 5000) {
      Socket.Recv.Chunk(bytes) -> {:got, bytes}
      Socket.Recv.Closed -> {:err_closed, ""}
      Socket.Recv.TimedOut(_p) -> {:err_timeout, ""}
      Socket.Recv.Failed(_e) -> {:err_failed, ""}
    }
  }

  fn bare_recv_check() -> Atom {
    case SocketXfoldUafTest.escaped_bare_recv() {
      {:got, c} -> SocketXfoldUafTest.after_bare(c)
      {_t, _s} -> :fail_setup_br
    }
  }

  fn after_bare(c :: String) -> Atom {
    _total = SocketXfoldUafTest.scalar_fold_b()
    case String.starts_with?(c, SocketXfoldUafTest.marker_a()) {
      true -> :ok
      false -> :fail_clobbered
    }
  }

  # ==== NESTED-fold retention: an outer fold retains A's first chunk WHILE an
  # inner scalar fold over a fresh socket B runs (and resets the shared arena to
  # the INNER loop-entry watermark several times). The inner watermark sits ABOVE
  # A's first chunk, so `resetToMark(inner_mark)` must leave it byte-stable. This
  # locks the nesting property: inner marks nest monotonically above outer chunks,
  # so an inner reset cannot free an enclosing loop's live chunk. ================

  # Runs the whole inner fold over a fresh B on the FIRST outer chunk (so the
  # inner loop resets the shared arena repeatedly while `bytes` is held live),
  # then RETAINS the outer chunk. Later outer chunks just keep the saved value.
  fn nested_cb(acc :: {Atom, String}, bytes :: String) -> {Atom, {Atom, String}} {
    case acc {
      {:got, saved} -> {:cont, {:got, saved}}
      {_tag, _e} ->
        {
          _inner = SocketXfoldUafTest.scalar_fold_b()
          {:cont, {:got, bytes}}
        }
    }
  }

  fn nested_from_a() -> {Atom, String} {
    case Socket.listen(Socket.Address.loopback(0), 8) {
      Result.Error(_e) -> {:err_listen, ""}
      Result.Ok(listener) -> SocketXfoldUafTest.nested_after_listen(listener)
    }
  }

  fn nested_after_listen(listener :: Socket.Listener) -> {Atom, String} {
    port = Socket.Listener.local_port(listener)
    case Socket.connect(Socket.Address.loopback(port), 5000) {
      Result.Error(_e) ->
        {
          _l = Socket.Listener.close(listener)
          {:err_connect, ""}
        }
      Result.Ok(client) -> SocketXfoldUafTest.nested_after_connect(listener, client)
    }
  }

  fn nested_after_connect(listener :: Socket.Listener, client :: Socket) -> {Atom, String} {
    case Socket.accept(listener) {
      Result.Error(_e) ->
        {
          _c = Socket.close(client)
          _l = Socket.Listener.close(listener)
          {:err_accept, ""}
        }
      Result.Ok(server) -> SocketXfoldUafTest.nested_exchange(listener, client, server)
    }
  }

  fn nested_exchange(listener :: Socket.Listener, client :: Socket, server :: Socket) -> {Atom, String} {
    _sent = Socket.send(server, SocketXfoldUafTest.payload_a())
    _shut = Socket.shutdown(server, :write)
    outcome = Socket.fold(client, {:pending, ""}, 5000, &SocketXfoldUafTest.nested_cb/2)
    _c1 = Socket.close(server)
    _c2 = Socket.close(client)
    _c3 = Socket.Listener.close(listener)
    case outcome {
      Result.Ok(pair) -> pair
      Result.Error(_e) -> {:err_fold, ""}
    }
  }

  fn nested_check() -> Atom {
    case SocketXfoldUafTest.nested_from_a() {
      {:got, x} ->
        case String.starts_with?(x, SocketXfoldUafTest.marker_a()) {
          true -> :ok
          false -> :fail_clobbered
        }
      {_t, _s} -> :fail_setup_nested
    }
  }

  describe("Socket cross-fold recv-chunk escape (loop-entry watermark reset)") {
    test("a recv chunk escaping fold A survives a later scalar fold B (no cross-fold UAF)") {
      base = Socket.live_count()
      assert(SocketXfoldUafTest.cross_fold_check() == :ok)
      assert(Socket.live_count() == base)
    }

    test("a bare Socket.recv chunk survives a later scalar fold B (no cross-fold UAF)") {
      base = Socket.live_count()
      assert(SocketXfoldUafTest.bare_recv_check() == :ok)
      assert(Socket.live_count() == base)
    }

    test("an outer fold's retained chunk survives an inner fold's watermark resets (nesting)") {
      base = Socket.live_count()
      assert(SocketXfoldUafTest.nested_check() == :ok)
      assert(Socket.live_count() == base)
    }
  }
}
