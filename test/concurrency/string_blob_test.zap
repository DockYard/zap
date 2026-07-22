pub struct TestConcurrency.StringBlobTest {
  use Zest.Case

  # P6-J3 acceptance proof: Blob-backed large Strings (plan item 6.3,
  # zap-concurrency-research.md §5.4) — large strings ride the Blob share
  # tier so a cross-process string send is a zero-copy handle share.
  # What these tests pin, end to end at the Zap surface:
  #
  #   * a SMALL string send never touches the blob domain (the measured
  #     promotion threshold gates the tier), and locally-constructed
  #     strings — however large — never touch it either (no
  #     construction-time promotion: the local-only string paths are
  #     untouched);
  #   * a LARGE string send promotes EXACTLY ONE blob (one copy — the
  #     last of its cross-process life) and the receiver's string IS the
  #     blob payload (`String.identity` equality across the boundary);
  #     forwarding a received large string creates NO new blob and
  #     preserves identity — the zero-copy send proof;
  #   * the sender dies, the receiver's string survives byte-identical
  #     (the share tier's point), and every blob returns to the domain
  #     baseline when its holders die — leak-exact via `Blob.live_count`;
  #   * slices COPY OUT at every process boundary (a sub-view never
  #     shares its parent's blob): a small slice of a huge received
  #     string never pins the huge payload — the Erlang sub-binary /
  #     pre-7u6 Java substring pin pathology, defeated by construction;
  #   * `<>` over a received (blob-backed) string appends IN PLACE while
  #     the blob is unshared (rc==1 — identity preserved, no new blob)
  #     and COPIES once shared (the receiver's frozen view is untouched
  #     by the sender's later appends);
  #   * the share is model-independent (an Arena child reads an ARC
  #     parent's promoted string zero-copy, and forwards it onward).
  #
  # Kernel-level twins (promotion/adoption ABI, ownership gates, frontier
  # rules) live in `src/runtime/concurrency/abi.zig`; the cross-thread
  # TSan stress of the append/probe paths lives in
  # `src/runtime/concurrency/blob.zig`. Sizes: the promotion threshold is
  # 65536 bytes (`string_blob_promotion_threshold`, measured — ledger
  # § "P6-J3 string-blob crossover"); "large" here is 131072 bytes.

  describe("threshold gating and local-only strings") {
    test("a small string send stays off the blob tier entirely") {
      base = Blob.live_count()
      child = Process.spawn(&TestConcurrency.StringBlobTest.echo_length_entry/0)
      _monitor_ref = Process.monitor(child)
      _channel = Process.send(Process.pid(u64, child), Process.self())

      _sent = Process.send((Pid.of(child) :: Pid(String)), "small payload")
      assert(Blob.live_count() == base)

      echoed_length = Process.receive_raw(i64)
      assert(echoed_length == 13)
      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }

    test("locally-constructed large strings never touch the blob domain") {
      base = Blob.live_count()
      # 64 KiB + 64 KiB, well past the 65536-byte promotion threshold —
      # but never sent, so the blob domain must stay untouched (no
      # construction-time promotion: local string cost is unchanged).
      left = String.repeat("x", 65536)
      combined = left <> String.repeat("y", 65536)
      assert(Blob.live_count() == base)
      assert(String.length(combined) == 131072)
      assert(String.byte_at(combined, 0) == "x")
      assert(String.byte_at(combined, 131071) == "y")
    }
  }

  describe("zero-copy large-string sends") {
    test("a large string send promotes exactly one blob and adopts zero-copy") {
      base = Blob.live_count()
      child = Process.spawn(&TestConcurrency.StringBlobTest.reader_entry/0)
      _monitor_ref = Process.monitor(child)
      _channel = Process.send(Process.pid(u64, child), Process.self())

      payload = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(child) :: Pid(String)), payload)

      child_length = Process.receive_raw(i64)
      child_identity = Process.receive_raw(u64)
      child_live = Process.receive_raw(i64)
      assert(child_length == 131072)
      # The child's string is the BLOB payload, not our arena buffer.
      assert(child_identity != String.identity(payload))
      # Promotion copied the bytes ONCE into exactly one fresh blob — the
      # CHILD observes the count while provably holding the payload (the
      # runner's own read would race the child's teardown drain).
      assert(child_live == base + 1)

      # Our original stays ours and readable (send borrows, never moves).
      assert(String.length(payload) == 131072)

      # The child's death drains its ledger: the blob is freed.
      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }

    test("forwarding a received large string is a zero-copy share — same identity, no new blob") {
      base = Blob.live_count()
      final_reader = Process.spawn(&TestConcurrency.StringBlobTest.identity_check_entry/0)
      _final_monitor = Process.monitor(final_reader)
      forwarder = Process.spawn(&TestConcurrency.StringBlobTest.forwarder_entry/0)
      _forwarder_monitor = Process.monitor(forwarder)

      _reply_channel = Process.send(Process.pid(u64, forwarder), Process.self())
      _target_channel = Process.send(Process.pid(u64, forwarder), final_reader)
      _check_channel = Process.send(Process.pid(u64, final_reader), Process.self())

      payload = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(forwarder) :: Pid(String)), payload)

      # The forwarder reports the identity it held; the final reader
      # reports whether ITS received string has that same identity and
      # the live count it observed while holding it.
      forwarder_identity = Process.receive_raw(u64)
      identity_matched = Process.receive_raw(i64)
      reader_live = Process.receive_raw(i64)
      reader_length = Process.receive_raw(i64)
      assert(forwarder_identity != 0)
      assert(identity_matched == 1)
      # ONE blob total across two large sends: the forward shared, never
      # copied.
      assert(reader_live == base + 1)
      assert(reader_length == 131072)

      _down_one = Process.await_signal()
      _down_two = Process.await_signal()
      assert(Blob.live_count() == base)
    }

    test("cross-model: an Arena child reads the promoted string zero-copy and forwards it onward") {
      base = Blob.live_count()
      final_reader = Process.spawn(&TestConcurrency.StringBlobTest.identity_check_entry/0)
      _final_monitor = Process.monitor(final_reader)
      # The forwarder runs under an explicit per-spawn Memory.Arena — the
      # blob payload lives in its OWN domain, so the share is
      # model-independent (no copy stub, no walker, no adoption
      # discipline), ARC → Arena → ARC.
      forwarder = Process.spawn(&TestConcurrency.StringBlobTest.forwarder_entry/0, Memory.Arena)
      _forwarder_monitor = Process.monitor(forwarder)

      _reply_channel = Process.send(Process.pid(u64, forwarder), Process.self())
      _target_channel = Process.send(Process.pid(u64, forwarder), final_reader)
      _check_channel = Process.send(Process.pid(u64, final_reader), Process.self())

      payload = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(forwarder) :: Pid(String)), payload)

      forwarder_identity = Process.receive_raw(u64)
      identity_matched = Process.receive_raw(i64)
      reader_live = Process.receive_raw(i64)
      reader_length = Process.receive_raw(i64)
      assert(forwarder_identity != 0)
      assert(identity_matched == 1)
      assert(reader_live == base + 1)
      assert(reader_length == 131072)

      _down_one = Process.await_signal()
      _down_two = Process.await_signal()
      assert(Blob.live_count() == base)
    }
  }

  describe("lifetime across process death") {
    test("the sender dies; the receiver's large string survives byte-identical") {
      base = Blob.live_count()
      consumer = Process.spawn(&TestConcurrency.StringBlobTest.survivor_consumer_entry/0)
      _consumer_monitor = Process.monitor(consumer)
      producer = Process.spawn(&TestConcurrency.StringBlobTest.producer_entry/0)

      _consumer_channel = Process.send(Process.pid(u64, consumer), Process.self())
      _producer_pid = Process.send(Process.pid(u64, consumer), producer)
      _target_channel = Process.send(Process.pid(u64, producer), consumer)

      # The consumer waits for the producer's DOWN before it reads the
      # queued string, so the bytes it verifies provably outlive their
      # sender.
      survived_ok = Process.receive_raw(i64)
      assert(survived_ok == 1)

      _consumer_down = Process.await_signal()
      assert(Blob.live_count() == base)
    }
  }

  describe("slices copy out — the pin pathology defeated") {
    test("a small slice of a huge received string never pins the huge payload") {
      base = Blob.live_count()
      slicer = Process.spawn(&TestConcurrency.StringBlobTest.slicer_entry/0)
      _slicer_monitor = Process.monitor(slicer)
      _channel = Process.send(Process.pid(u64, slicer), Process.self())

      huge = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(slicer) :: Pid(String)), huge)

      # The slicer sends back a 16-byte slice (below the threshold → a
      # plain byte-copy, no blob adoption on our side) plus the live count
      # it observed WHILE holding the huge blob, then dies.
      slice = receive String {
        s -> s
      }
      slicer_live = Process.receive_raw(i64)
      assert(slicer_live == base + 1)
      _slicer_down = Process.await_signal()

      # THE pin-avoidance proof: the slicer is dead, its huge blob is
      # freed (live count back to baseline) — the slice we still hold
      # pins NOTHING and stays fully readable.
      assert(Blob.live_count() == base)
      assert(String.length(slice) == 16)
      assert(slice == "abcdefghabcdefgh")
    }

    test("a large sub-slice crossing the boundary is a fresh copy, never the parent's buffer") {
      base = Blob.live_count()
      final_reader = Process.spawn(&TestConcurrency.StringBlobTest.identity_check_entry/0)
      _final_monitor = Process.monitor(final_reader)
      slicer = Process.spawn(&TestConcurrency.StringBlobTest.large_slice_forwarder_entry/0)
      _slicer_monitor = Process.monitor(slicer)

      _reply_channel = Process.send(Process.pid(u64, slicer), Process.self())
      _target_channel = Process.send(Process.pid(u64, slicer), final_reader)
      _check_channel = Process.send(Process.pid(u64, final_reader), Process.self())

      huge = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(slicer) :: Pid(String)), huge)

      # The slicer forwards a LARGE sub-slice (still above the threshold,
      # but not the whole view): the boundary copies it out into a fresh
      # blob — identity must NOT match the parent payload's.
      slicer_identity = Process.receive_raw(u64)
      identity_matched = Process.receive_raw(i64)
      reader_live = Process.receive_raw(i64)
      reader_length = Process.receive_raw(i64)
      assert(slicer_identity != 0)
      assert(identity_matched == 0)
      # Two blobs while both live: the parent's + the slice's fresh copy.
      # Deterministic because the slicer HOLDS the parent blob until our
      # ack below — it cannot drain its ledger before the reader observed.
      assert(reader_live == base + 2)
      assert(reader_length == 65536)

      _ack = Process.send(Process.pid(i64, slicer), 1)
      _down_one = Process.await_signal()
      _down_two = Process.await_signal()
      assert(Blob.live_count() == base)
    }
  }

  describe("rc==1 in-place append vs copy-on-shared") {
    test("appending to an unshared received string extends in place — same buffer, no new blob") {
      base = Blob.live_count()
      appender = Process.spawn(&TestConcurrency.StringBlobTest.appender_entry/0)
      _appender_monitor = Process.monitor(appender)
      _channel = Process.send(Process.pid(u64, appender), Process.self())

      payload = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(appender) :: Pid(String)), payload)

      appended_in_place = Process.receive_raw(i64)
      appended_length = Process.receive_raw(i64)
      tail_ok = Process.receive_raw(i64)
      live_after_append = Process.receive_raw(i64)
      # rc==1 (the receiver is the sole holder) → the append reused the
      # blob buffer: identity preserved, length grown, no new blob.
      assert(appended_in_place == 1)
      assert(appended_length == 131072 + 5)
      assert(tail_ok == 1)
      assert(live_after_append == base + 1)

      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }

    test("appending to a shared string copies — the other holder's view stays frozen") {
      base = Blob.live_count()
      frozen_reader = Process.spawn(&TestConcurrency.StringBlobTest.frozen_view_entry/0)
      _reader_monitor = Process.monitor(frozen_reader)
      sharer = Process.spawn(&TestConcurrency.StringBlobTest.share_then_append_entry/0)
      _sharer_monitor = Process.monitor(sharer)

      _reply_channel = Process.send(Process.pid(u64, sharer), Process.self())
      _target_channel = Process.send(Process.pid(u64, sharer), frozen_reader)
      _check_channel = Process.send(Process.pid(u64, frozen_reader), Process.self())

      payload = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(sharer) :: Pid(String)), payload)

      # The sharer forwarded its string, THEN appended: the append must
      # have copied (identity changed) because the blob was shared.
      append_copied = Process.receive_raw(i64)
      appended_length = Process.receive_raw(i64)
      # The reader verified its view AFTER the sharer's append: length
      # and bytes are the ORIGINAL's — the shared payload is frozen.
      frozen_length = Process.receive_raw(i64)
      frozen_bytes_ok = Process.receive_raw(i64)
      assert(append_copied == 1)
      assert(appended_length == 131072 + 5)
      assert(frozen_length == 131072)
      assert(frozen_bytes_ok == 1)

      _down_one = Process.await_signal()
      _down_two = Process.await_signal()
      assert(Blob.live_count() == base)
    }

    test("an append loop over a received string grows amortized — in-place runs, then geometric re-promotion") {
      base = Blob.live_count()
      grower = Process.spawn(&TestConcurrency.StringBlobTest.growth_loop_entry/0)
      _grower_monitor = Process.monitor(grower)
      _channel = Process.send(Process.pid(u64, grower), Process.self())

      payload = TestConcurrency.StringBlobTest.large_payload()
      _sent = Process.send((Pid.of(grower) :: Pid(String)), payload)

      in_place_count = Process.receive_raw(i64)
      promoted_count = Process.receive_raw(i64)
      final_length = Process.receive_raw(i64)
      final_tail_ok = Process.receive_raw(i64)
      # 40 × 1024-byte appends over a 128 KiB base: the page slack absorbs
      # some in place, growth re-promotes the rest — both legs must run
      # (whatever the page size), and the content must come out exact.
      assert(in_place_count >= 1)
      assert(promoted_count >= 1)
      assert(in_place_count + promoted_count == 40)
      assert(final_length == 131072 + (40 * 1024))
      assert(final_tail_ok == 1)

      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }
  }

  describe("large-string send storm leak-exactness") {
    test("50 large-string sends to a consuming child return the domain to baseline") {
      base = Blob.live_count()
      consumer = Process.spawn(&TestConcurrency.StringBlobTest.storm_consumer_entry/0)
      _consumer_monitor = Process.monitor(consumer)
      _channel = Process.send(Process.pid(u64, consumer), Process.self())
      _count = Process.send(Process.pid(i64, consumer), 50)

      _sent = TestConcurrency.StringBlobTest.send_storm(consumer, 50)

      total = Process.receive_raw(i64)
      assert(total == 50 * 131072)
      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }
  }

  # -- payload builders ------------------------------------------------------

  @doc = """
    The canonical 131072-byte large payload (16384 × "abcdefgh") — twice
    the 65536-byte promotion threshold, arena-backed at construction.
    """

  pub fn large_payload() -> String {
    String.repeat("abcdefgh", 16384)
  }

  @doc = """
    Converts a Bool check into a reportable scalar: 1 for true, 0 for
    false (children report their observations as i64 messages).
    """

  pub fn flag(true) -> i64 {
    1
  }

  pub fn flag(false) -> i64 {
    0
  }

  # -- child process bodies --------------------------------------------------

  @doc = """
    Echo child for the small-string test: receives the reply channel and
    one string, and reports the string's length back as a scalar.
    """

  pub fn echo_length_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    _reported = Process.send(Process.pid(i64, parent), String.length(message))
    nil
  }

  @doc = """
    Reader child for the zero-copy promotion proof: receives the reply
    channel and one large string, and reports the string's length, its
    buffer identity, and the blob live count it observed while holding
    the adopted payload. Exits without any explicit release — its
    teardown drains the adopted blob reference.
    """

  pub fn reader_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    _length_sent = Process.send(Process.pid(i64, parent), String.length(message))
    _identity_sent = Process.send(Process.pid(u64, parent), String.identity(message))
    _live_sent = Process.send(Process.pid(i64, parent), Blob.live_count())
    nil
  }

  @doc = """
    Forwarder child for the zero-copy forward proofs: receives the reply
    channel, the forward target, and one large string; reports the
    string's identity to the parent, forwards the string itself to the
    target (a share, not a copy), then sends the target its own identity
    token so the target can compare.
    """

  pub fn forwarder_entry() -> Nil {
    parent = Process.receive_raw(u64)
    target = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    _identity_reported = Process.send(Process.pid(u64, parent), String.identity(message))
    _forwarded = Process.send((Pid.of(target) :: Pid(String)), message)
    _identity_sent = Process.send(Process.pid(u64, target), String.identity(message))
    nil
  }

  @doc = """
    Terminal reader for the forward proofs: receives the parent's reply
    channel, one large string, and the upstream holder's identity token;
    reports whether its own string has that same identity (1 = the
    zero-copy witness), the blob live count it observed, and its
    string's length.
    """

  pub fn identity_check_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    upstream_identity = Process.receive_raw(u64)
    matched = TestConcurrency.StringBlobTest.flag(String.identity(message) == upstream_identity)
    _match_sent = Process.send(Process.pid(i64, parent), matched)
    _live_sent = Process.send(Process.pid(i64, parent), Blob.live_count())
    _length_sent = Process.send(Process.pid(i64, parent), String.length(message))
    nil
  }

  @doc = """
    Producer child for the sender-dies proof: receives its target, builds
    a large string LOCALLY, sends it (the send promotes it into the blob
    domain), and dies immediately — nothing of the string tethers to
    this process afterwards.
    """

  pub fn producer_entry() -> Nil {
    target = Process.receive_raw(u64)
    payload = TestConcurrency.StringBlobTest.large_payload()
    _sent = Process.send((Pid.of(target) :: Pid(String)), payload)
    nil
  }

  @doc = """
    Consumer child for the sender-dies proof: receives the reply channel
    and the producer's pid, monitors the producer and waits for it to be
    FULLY dead, THEN reads the queued string and verifies it
    byte-by-byte at the edges — reporting 1 when the dead sender's bytes
    are intact.
    """

  pub fn survivor_consumer_entry() -> Nil {
    parent = Process.receive_raw(u64)
    producer = Process.receive_raw(u64)
    _monitor_ref = Process.monitor(producer)
    _producer_down = Process.await_signal()
    message = receive String {
      s -> s
    }
    length_ok = String.length(message) == 131072
    first_ok = String.byte_at(message, 0) == "a"
    last_ok = String.byte_at(message, 131071) == "h"
    survived = TestConcurrency.StringBlobTest.flag(length_ok and first_ok and last_ok)
    _reported = Process.send(Process.pid(i64, parent), survived)
    nil
  }

  @doc = """
    Slicer child for the pin-avoidance proof: receives the reply channel
    and a huge string, sends back a 16-byte slice (a plain copy at the
    boundary — below the promotion threshold) plus the blob live count it
    observed while holding the huge payload, and dies, taking the huge
    blob with it.
    """

  pub fn slicer_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    small_slice = String.slice(message, 0, 16)
    _sent = Process.send((Pid.of(parent) :: Pid(String)), small_slice)
    _live_sent = Process.send(Process.pid(i64, parent), Blob.live_count())
    nil
  }

  @doc = """
    Slicer child for the copy-out-at-the-boundary proof: receives the
    reply channel, the forward target, and a huge string; reports the
    huge string's identity, forwards a LARGE sub-slice (65536 bytes — at
    the threshold, but not the whole view, so the boundary must copy it
    out into a fresh buffer), then sends the target the PARENT string's
    identity for the must-NOT-match comparison.
    """

  pub fn large_slice_forwarder_entry() -> Nil {
    parent = Process.receive_raw(u64)
    target = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    _identity_reported = Process.send(Process.pid(u64, parent), String.identity(message))
    large_slice = String.slice(message, 0, 65536)
    _forwarded = Process.send((Pid.of(target) :: Pid(String)), large_slice)
    _identity_sent = Process.send(Process.pid(u64, target), String.identity(message))
    # Hold the parent blob until the runner acks (the reader's base+2
    # observation needs both blobs provably live), then die.
    _ack = Process.receive_raw(i64)
    nil
  }

  @doc = """
    Appender child for the rc==1 in-place proof: receives the reply
    channel and a large string (sole holder — rc==1), appends a 5-byte
    tail with `<>`, and reports whether the buffer identity survived the
    append (1 = extended in place), the new length, whether the tail
    bytes landed correctly, and the blob live count after the append
    (unchanged when in place).
    """

  pub fn appender_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    identity_before = String.identity(message)
    appended = message <> "-tail"
    in_place = TestConcurrency.StringBlobTest.flag(String.identity(appended) == identity_before)
    tail = String.slice(appended, String.length(appended) - 5, String.length(appended))
    tail_ok = TestConcurrency.StringBlobTest.flag(tail == "-tail")
    _in_place_sent = Process.send(Process.pid(i64, parent), in_place)
    _length_sent = Process.send(Process.pid(i64, parent), String.length(appended))
    _tail_sent = Process.send(Process.pid(i64, parent), tail_ok)
    _live_sent = Process.send(Process.pid(i64, parent), Blob.live_count())
    nil
  }

  @doc = """
    Sharer child for the copy-on-shared proof: receives the reply
    channel, the frozen-reader target, and a large string; FORWARDS the
    string (the blob is now shared — frozen), then appends to its own
    copy of the view and reports whether the append copied (1 = identity
    changed, as it must once shared) and the appended length; finally
    signals the reader (which verifies its view only after the append
    happened) with a go token.
    """

  pub fn share_then_append_entry() -> Nil {
    parent = Process.receive_raw(u64)
    target = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    _forwarded = Process.send((Pid.of(target) :: Pid(String)), message)
    identity_before = String.identity(message)
    appended = message <> "-mine"
    copied = TestConcurrency.StringBlobTest.flag(String.identity(appended) != identity_before)
    _copied_sent = Process.send(Process.pid(i64, parent), copied)
    _length_sent = Process.send(Process.pid(i64, parent), String.length(appended))
    _go_sent = Process.send(Process.pid(i64, target), 1)
    nil
  }

  @doc = """
    Frozen-view child for the copy-on-shared proof: receives the parent's
    reply channel and a large string, then WAITS for the sharer's go
    token (sent only after the sharer appended), and only then verifies
    its view: the length and edge bytes must be the ORIGINAL's — the
    sharer's append never touched the shared payload.
    """

  pub fn frozen_view_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    _go = Process.receive_raw(i64)
    frozen_length = String.length(message)
    edges_intact = String.byte_at(message, 0) == "a" and String.byte_at(message, 131071) == "h"
    bytes_ok = TestConcurrency.StringBlobTest.flag(edges_intact)
    _length_sent = Process.send(Process.pid(i64, parent), frozen_length)
    _bytes_sent = Process.send(Process.pid(i64, parent), bytes_ok)
    nil
  }

  @doc = """
    Growth-loop child for the amortized-append proof: receives the reply
    channel and a large string, appends a 1024-byte chunk 40 times with
    `<>`, counting how many appends kept the buffer identity (in place)
    versus changed it (geometric re-promotion), and reports both counts,
    the final length, and whether the final tail bytes are correct.
    """

  pub fn growth_loop_entry() -> Nil {
    parent = Process.receive_raw(u64)
    message = receive String {
      s -> s
    }
    chunk = String.repeat("k", 1024)
    _reported = TestConcurrency.StringBlobTest.append_loop(parent, message, chunk, 40, 0, 0)
    nil
  }

  @doc = """
    The appender's loop: appends `chunk` `remaining` times onto `acc`,
    classifying each step by buffer identity (in place vs promoted), and
    reporting the tallies, the final length, and a tail-byte check to
    `parent` in the base case.
    """

  pub fn append_loop(parent :: u64, acc :: String, _chunk :: String, 0 :: i64, in_place :: i64, promoted :: i64) -> Bool {
    _in_place_sent = Process.send(Process.pid(i64, parent), in_place)
    _promoted_sent = Process.send(Process.pid(i64, parent), promoted)
    _length_sent = Process.send(Process.pid(i64, parent), String.length(acc))
    tail_ok = TestConcurrency.StringBlobTest.flag(String.byte_at(acc, String.length(acc) - 1) == "k")
    _tail_sent = Process.send(Process.pid(i64, parent), tail_ok)
    true
  }

  pub fn append_loop(parent :: u64, acc :: String, chunk :: String, remaining :: i64, in_place :: i64, promoted :: i64) -> Bool {
    identity_before = String.identity(acc)
    extended = acc <> chunk
    case String.identity(extended) == identity_before {
      true -> TestConcurrency.StringBlobTest.append_loop(parent, extended, chunk, remaining - 1, in_place + 1, promoted)
      false -> TestConcurrency.StringBlobTest.append_loop(parent, extended, chunk, remaining - 1, in_place, promoted + 1)
    }
  }

  @doc = """
    The storm sender's loop: builds and sends a fresh large string
    `remaining` times (each send promotes one blob whose only long-lived
    holder is the consumer, or the consumer's teardown).
    """

  pub fn send_storm(_target :: u64, 0 :: i64) -> Bool {
    true
  }

  pub fn send_storm(target :: u64, remaining :: i64) -> Bool {
    payload = TestConcurrency.StringBlobTest.large_payload()
    _sent = Process.send((Pid.of(target) :: Pid(String)), payload)
    TestConcurrency.StringBlobTest.send_storm(target, remaining - 1)
  }

  @doc = """
    The storm consumer: receives its reply channel and string budget,
    then receives and length-sums every large string, reporting the
    total. Its teardown drains all fifty adopted blob references.
    """

  pub fn storm_consumer_entry() -> Nil {
    parent = Process.receive_raw(u64)
    expected = Process.receive_raw(i64)
    total = TestConcurrency.StringBlobTest.consume_storm(expected, 0)
    _reported = Process.send(Process.pid(i64, parent), total)
    nil
  }

  @doc = """
    The consumer's receive/measure loop, accumulating string lengths.
    """

  pub fn consume_storm(0 :: i64, total :: i64) -> i64 {
    total
  }

  pub fn consume_storm(remaining :: i64, total :: i64) -> i64 {
    message = receive String {
      s -> s
    }
    TestConcurrency.StringBlobTest.consume_storm(remaining - 1, total + String.length(message))
  }
}
