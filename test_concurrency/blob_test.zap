pub struct TestConcurrency.BlobTest {
  use Zest.Case

  # P6-J2 acceptance proof: `Blob` — THE one sanctioned share tier of the
  # isolation model (research.md §6.4 regime 2) — plus the persistent-term
  # global registry. What these tests pin, end to end at the Zap surface:
  #
  #   * create copies IN once; reads (size/at/to_string) see the bytes;
  #     slices COPY OUT (never alias — the anti-pin rule);
  #   * a send shares the payload BY POINTER: the receiver observes the
  #     SAME identity token (zero bytes copied) and the atomic share count
  #     reflects both holders — same-model AND cross-model (the blob is
  #     the model-independent payload);
  #   * the sender's death leaves the receiver's blob intact (THE point of
  #     the tier), and the last holder's death frees it — leak-exact,
  #     asserted through `Blob.live_count` baselines in every test;
  #   * the global registry survives process churn, replaces safely under
  #     concurrent lock-free readers, and grants counted references;
  #   * a blob-heavy send storm returns the domain to its baseline.
  #
  # Kernel-level twins (surgical lifecycle control: teardown-drain of a
  # queued blob envelope, dead-letter flight undo) live in
  # `src/runtime/concurrency/abi.zig`; the atomic tier's cross-thread
  # TSan stress lives in `src/runtime/concurrency/blob.zig`.

  describe("Blob create and read") {
    test("new copies bytes in; size/at/to_string read them back; release is leak-exact") {
      base = Blob.live_count()
      blob = Blob.new("hello blob")
      assert(Blob.live_count() == base + 1)

      assert(Blob.size(blob) == 10)
      assert(Blob.at(blob, 0) == 104)   # 'h'
      assert(Blob.at(blob, 9) == 98)    # 'b'
      assert(Blob.to_string(blob) == "hello blob")
      assert(Blob.ref_count(blob) == 1)

      _released = Blob.release(blob)
      assert(Blob.live_count() == base)
    }

    test("the empty blob is legal") {
      base = Blob.live_count()
      blob = Blob.new("")
      assert(Blob.size(blob) == 0)
      assert(Blob.to_string(blob) == "")
      _released = Blob.release(blob)
      assert(Blob.live_count() == base)
    }

    test("to_string copies out — the string outlives the released blob") {
      base = Blob.live_count()
      blob = Blob.new("independent copy")
      materialized = Blob.to_string(blob)
      _released = Blob.release(blob)
      # The blob is gone; the copied-out string is untouched (its lifetime
      # is this process's, fully decoupled from the blob domain).
      assert(materialized == "independent copy")
      assert(Blob.live_count() == base)
    }
  }

  describe("Blob slice copies out (no sub-blob aliasing)") {
    test("a slice is an independent blob: distinct identity, parent-independent lifetime") {
      base = Blob.live_count()
      parent = Blob.new("hello world")
      part = Blob.slice(parent, 6, 5)
      assert(Blob.live_count() == base + 2)

      # COPY-out, never a view: the slice's backing is a different buffer.
      assert(Blob.identity(part) != Blob.identity(parent))
      assert(Blob.to_string(part) == "world")
      assert(Blob.ref_count(parent) == 1)   # slicing retained NOTHING on the parent

      # The anti-pin proof: releasing the parent frees the parent's bytes
      # (live count drops) while the slice stays fully readable — a small
      # slice can never pin a huge parent.
      _parent_released = Blob.release(parent)
      assert(Blob.live_count() == base + 1)
      assert(Blob.to_string(part) == "world")
      assert(Blob.size(part) == 5)

      _part_released = Blob.release(part)
      assert(Blob.live_count() == base)
    }

    test("a whole-range slice and an empty slice are legal") {
      base = Blob.live_count()
      parent = Blob.new("abc")
      whole = Blob.slice(parent, 0, 3)
      empty = Blob.slice(parent, 3, 0)
      assert(Blob.to_string(whole) == "abc")
      assert(Blob.size(empty) == 0)
      _w = Blob.release(whole)
      _e = Blob.release(empty)
      _p = Blob.release(parent)
      assert(Blob.live_count() == base)
    }
  }

  describe("Blob zero-copy share across processes") {
    test("a sent blob arrives with the SAME payload identity and the count reflects both holders") {
      base = Blob.live_count()
      child = Process.spawn(&TestConcurrency.BlobTest.blob_reader_entry/0)
      _monitor_ref = Process.monitor(child)
      _channel = Process.send(Process.pid(u64, child), Process.self())

      blob = Blob.new("shared, not copied")
      _sent = Process.send((Pid.of(child) :: Pid(Blob)), blob)

      # The child reports what IT observed of the received blob.
      child_identity = Process.receive_raw(u64)
      child_size = Process.receive_raw(i64)
      child_first_byte = Process.receive_raw(i64)
      child_observed_count = Process.receive_raw(i64)

      # Zero copy: the receiver read the SAME buffer this process created
      # — pointer identity across the process boundary. No new blob was
      # created anywhere (live count unchanged by the send).
      assert(child_identity == Blob.identity(blob))
      assert(child_size == 18)
      assert(child_first_byte == 115)   # 's'
      assert(Blob.live_count() == base + 1)

      # The atomic share count reflected both holders while the child
      # held its reference (creator + receiver = 2).
      assert(child_observed_count == 2)

      # The send did NOT consume our reference — the blob is still ours
      # to read after the receiver got its own.
      assert(Blob.to_string(blob) == "shared, not copied")

      # Child dies (its teardown releases its reference); ours remains.
      _down = Process.await_signal()
      assert(Blob.ref_count(blob) == 1)
      _released = Blob.release(blob)
      assert(Blob.live_count() == base)
    }

    test("cross-model share: an ARC parent's blob is readable by an Arena child, zero-copy") {
      # The blob payload lives in its OWN allocation domain — neither the
      # sender's ARC heap nor the receiver's Arena heap — so the share is
      # model-independent: no copy stub, no walker, no adoption
      # discipline. The `:test_concurrency` manifest default is ARC; the
      # child runs under an explicit per-spawn Memory.Arena.
      base = Blob.live_count()
      child = Process.spawn(&TestConcurrency.BlobTest.blob_reader_entry/0, Memory.Arena)
      _monitor_ref = Process.monitor(child)
      _channel = Process.send(Process.pid(u64, child), Process.self())

      blob = Blob.new("cross-model bytes")
      _sent = Process.send((Pid.of(child) :: Pid(Blob)), blob)

      child_identity = Process.receive_raw(u64)
      child_size = Process.receive_raw(i64)
      child_first_byte = Process.receive_raw(i64)
      child_observed_count = Process.receive_raw(i64)

      assert(child_identity == Blob.identity(blob))
      assert(child_size == 17)
      assert(child_first_byte == 99)    # 'c'
      assert(child_observed_count == 2)
      assert(Blob.live_count() == base + 1)

      _down = Process.await_signal()
      assert(Blob.ref_count(blob) == 1)
      _released = Blob.release(blob)
      assert(Blob.live_count() == base)
    }

    test("send_move shares the blob and relinquishes the sender's reference") {
      base = Blob.live_count()
      child = Process.spawn(&TestConcurrency.BlobTest.move_reader_entry/0)
      _monitor_ref = Process.monitor(child)
      _channel = Process.send(Process.pid(u64, child), Process.self())

      blob = Blob.new("moved away")
      _sent = Process.send_move((Pid.of(child) :: Pid(Blob)), blob)

      # The child (now the SOLE holder — our reference was relinquished by
      # the move) reports the count it observed, then dies; its teardown
      # frees the blob without any action from us.
      child_observed_count = Process.receive_raw(i64)
      assert(child_observed_count == 1)
      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }

    test("a send to a dead process dead-letters without leaking the flight reference") {
      base = Blob.live_count()
      victim = Process.spawn(&TestConcurrency.BlobTest.noop_entry/0)
      _monitor_ref = Process.monitor(victim)
      _down = Process.await_signal()   # the victim is fully dead

      blob = Blob.new("undeliverable")
      sent = Process.send((Pid.of(victim) :: Pid(Blob)), blob)
      assert(sent == false)            # Erlang dead-letter semantics — not an error

      # The flight reference was undone: we are the sole holder, and
      # releasing returns the domain to baseline.
      assert(Blob.ref_count(blob) == 1)
      _released = Blob.release(blob)
      assert(Blob.live_count() == base)
    }
  }

  describe("Blob lifetime across process death") {
    test("the sender dies; the receiver's blob survives, byte-identical — THE point of the tier") {
      base = Blob.live_count()
      producer = Process.spawn(&TestConcurrency.BlobTest.blob_producer_entry/0)
      _monitor_ref = Process.monitor(producer)
      _channel = Process.send(Process.pid(u64, producer), Process.self())

      blob = receive Blob {
        b -> b
      }

      # Wait for the producer to be FULLY dead: its teardown drains its
      # blob ledger (releasing the creator reference) BEFORE its exit
      # signals propagate, so after the DOWN we are provably the sole
      # holder of a blob whose creator no longer exists.
      down_reason = Process.await_signal()
      assert(down_reason == :normal)
      assert(Blob.ref_count(blob) == 1)

      # The dead producer's bytes, intact.
      assert(Blob.to_string(blob) == "outlives its creator")
      assert(Blob.size(blob) == 20)

      # Both holders gone → freed, leak-exact ("both die → blob freed").
      _released = Blob.release(blob)
      assert(Blob.live_count() == base)
    }
  }

  describe("Blob global registry (persistent_term)") {
    test("a never-put key is absent; get_global returns the caller's default as-is") {
      base = Blob.live_count()
      assert(Blob.has_global?(:blob_test_never_put_key) == false)

      fallback = Blob.new("the fallback")
      got = Blob.get_global(:blob_test_never_put_key, fallback)
      # The default came back AS-IS (same backing buffer) and no new
      # reference was granted (live count unchanged beyond the fallback).
      assert(Blob.identity(got) == Blob.identity(fallback))
      assert(Blob.live_count() == base + 1)
      _released = Blob.release(fallback)
      assert(Blob.live_count() == base)
    }

    test("put/get round-trips; the value survives the publisher's death") {
      base = Blob.live_count()
      publisher = Process.spawn(&TestConcurrency.BlobTest.registry_publisher_entry/0)
      _monitor_ref = Process.monitor(publisher)
      _down = Process.await_signal()   # the publisher is fully dead

      # The registry's own reference — not the dead publisher's — keeps
      # the value alive (persistent-term survives process churn).
      assert(Blob.live_count() == base + 1)
      assert(Blob.has_global?(:blob_test_config))
      fallback = Blob.new("fallback")
      blob = Blob.get_global(:blob_test_config, fallback)
      assert(Blob.identity(blob) != Blob.identity(fallback))
      assert(Blob.to_string(blob) == "registry v1")

      # Our get was a counted grant: registry + us.
      assert(Blob.ref_count(blob) == 2)
      _released = Blob.release(blob)
      _fallback_released = Blob.release(fallback)
      assert(Blob.live_count() == base + 1)   # the registry entry remains, by design
    }

    test("put replaces: old readers keep the old value alive; new readers see the new one") {
      base = Blob.live_count()
      first = Blob.new("replace me v1")
      _put_first = Blob.put_global(:blob_test_replace_key, first)
      _drop_first = Blob.release(first)   # the registry is now the sole owner of v1

      fallback = Blob.new("fallback")
      held = Blob.get_global(:blob_test_replace_key, fallback)
      assert(Blob.to_string(held) == "replace me v1")

      second = Blob.new("replacement v2")
      _put_second = Blob.put_global(:blob_test_replace_key, second)

      # Replacement released the registry's v1 reference — but OUR held
      # get-reference keeps v1 alive and readable (no reader is ever
      # invalidated by a put).
      assert(Blob.to_string(held) == "replace me v1")
      assert(Blob.ref_count(held) == 1)   # we are v1's sole remaining holder

      # A fresh get observes the replacement.
      refetched = Blob.get_global(:blob_test_replace_key, fallback)
      assert(Blob.to_string(refetched) == "replacement v2")

      # Drop everything we hold: v1 dies with us; v2 lives on in the
      # registry (base + 1).
      _drop_held = Blob.release(held)
      _drop_refetched = Blob.release(refetched)
      _drop_second = Blob.release(second)
      _drop_fallback = Blob.release(fallback)
      assert(Blob.live_count() == base + 1)
    }

    test("concurrent readers race replacing puts safely (lock-free get + atomic retain)") {
      base = Blob.live_count()
      seed = Blob.new("r seed value")
      _put_seed = Blob.put_global(:blob_test_storm_key, seed)
      _drop_seed = Blob.release(seed)

      # Four readers hammer get/verify/release on the M:N pool while this
      # process REPLACES the value repeatedly underneath them. Every read
      # a reader observes must be a live, coherent value (first byte 'r')
      # — a torn or dangling observation would panic or fail the check.
      reader_count = 4
      reads_per_reader = 50
      _spawned = TestConcurrency.BlobTest.spawn_registry_readers(reader_count, reads_per_reader)
      _replaced = TestConcurrency.BlobTest.replace_storm(25)
      successful_reads = TestConcurrency.BlobTest.collect_reader_totals(reader_count, 0)
      assert(successful_reads == reader_count * reads_per_reader)

      # Every superseded value died with its last reader; only the final
      # registry value remains.
      assert(Blob.live_count() == base + 1)
    }
  }

  describe("Blob send storm leak-exactness") {
    test("200 blob shares to a consuming child return the domain to baseline") {
      base = Blob.live_count()
      storm_size = 200
      consumer = Process.spawn(&TestConcurrency.BlobTest.storm_consumer_entry/0)
      _monitor_ref = Process.monitor(consumer)
      _channel = Process.send(Process.pid(u64, consumer), Process.self())
      _count = Process.send(Process.pid(i64, consumer), storm_size)

      _sent = TestConcurrency.BlobTest.send_storm(consumer, storm_size)

      # The consumer verified and released every blob; its total is the
      # sum of all sizes ("storm payload bytes" = 19 bytes each).
      total = Process.receive_raw(i64)
      assert(total == storm_size * 19)

      _down = Process.await_signal()
      assert(Blob.live_count() == base)
    }
  }

  # -- child process bodies and recursion helpers ---------------------------

  @doc = """
    Reader child for the zero-copy share proofs: receives the parent's
    reply channel, then one `Blob`, and reports the blob's identity
    token, size, first byte, and observed share count back as scalars.
    Exits without releasing — its teardown drain returns the reference.
    """

  pub fn blob_reader_entry() -> Nil {
    parent = Process.receive_raw(u64)
    blob = receive Blob {
      b -> b
    }
    _identity_sent = Process.send(Process.pid(u64, parent), Blob.identity(blob))
    _size_sent = Process.send(Process.pid(i64, parent), Blob.size(blob))
    _byte_sent = Process.send(Process.pid(i64, parent), Blob.at(blob, 0))
    _count_sent = Process.send(Process.pid(i64, parent), Blob.ref_count(blob))
    nil
  }

  @doc = """
    Reader child for the `send_move` proof: reports the share count it
    observes on the moved-in blob (1 — the mover relinquished), then
    exits; its teardown performs the final release.
    """

  pub fn move_reader_entry() -> Nil {
    parent = Process.receive_raw(u64)
    blob = receive Blob {
      b -> b
    }
    _count_sent = Process.send(Process.pid(i64, parent), Blob.ref_count(blob))
    nil
  }

  @doc = """
    Producer child for the sender-dies proof: creates a blob, shares it
    to the parent, and exits WITHOUT releasing — its teardown drain
    releases the creator reference, leaving the parent the sole holder.
    """

  pub fn blob_producer_entry() -> Nil {
    parent = Process.receive_raw(u64)
    blob = Blob.new("outlives its creator")
    _sent = Process.send((Pid.of(parent) :: Pid(Blob)), blob)
    nil
  }

  @doc = """
    Trivial child that exits immediately — the dead-letter target.
    """

  pub fn noop_entry() -> Nil {
    nil
  }

  @doc = """
    Publisher child for the registry-survives-churn proof: creates a
    blob, puts it under `:blob_test_config`, and dies. The registry's
    own reference keeps the value alive.
    """

  pub fn registry_publisher_entry() -> Nil {
    blob = Blob.new("registry v1")
    _put = Blob.put_global(:blob_test_config, blob)
    nil
  }

  @doc = """
    Reader child for the concurrent-registry stress: performs its read
    loop against `:blob_test_storm_key`, then reports its successful
    read count to the parent.
    """

  pub fn registry_reader_entry() -> Nil {
    parent = Process.receive_raw(u64)
    reads = Process.receive_raw(i64)
    sentinel = Blob.new("x sentinel")
    successes = TestConcurrency.BlobTest.read_registry_loop(reads, sentinel, 0)
    _sentinel_released = Blob.release(sentinel)
    _reported = Process.send(Process.pid(i64, parent), successes)
    nil
  }

  @doc = """
    One reader's get/verify/release loop: every observed value must be
    live and coherent (first byte 'r' — every stored value starts with
    it), whichever replacement generation the lock-free get lands on.
    The reader's own `sentinel` blob is the absent-key default; a
    returned value with the sentinel's identity means the key was
    absent (never counted as a successful read).
    """

  pub fn read_registry_loop(0 :: i64, _sentinel :: Blob, successes :: i64) -> i64 {
    successes
  }

  pub fn read_registry_loop(remaining :: i64, sentinel :: Blob, successes :: i64) -> i64 {
    got = Blob.get_global(:blob_test_storm_key, sentinel)
    step = case Blob.identity(got) == Blob.identity(sentinel) {
      true -> TestConcurrency.BlobTest.absent_read_step()
      false -> TestConcurrency.BlobTest.verify_and_release(got)
    }
    TestConcurrency.BlobTest.read_registry_loop(remaining - 1, sentinel, successes + step)
  }

  @doc = """
    Verifies one observed registry value (first byte 'r' — every stored
    value starts with it) and releases the get-granted reference.
    Returns 1 for a coherent read, 0 otherwise.
    """

  pub fn verify_and_release(blob :: Blob) -> i64 {
    first_byte = Blob.at(blob, 0)
    _released = Blob.release(blob)
    TestConcurrency.BlobTest.score_read(first_byte)
  }

  @doc = """
    Scores one observed first byte: 1 for the registry marker 'r'
    (byte 114), 0 for anything else.
    """

  pub fn score_read(114 :: i64) -> i64 {
    1
  }

  pub fn score_read(_other :: i64) -> i64 {
    0
  }

  @doc = """
    The absent-key step of the reader loop (the sentinel came back).
    """

  pub fn absent_read_step() -> i64 {
    0
  }

  @doc = """
    Spawns `count` registry readers, handing each the reply channel and
    its read budget.
    """

  pub fn spawn_registry_readers(0 :: i64, _reads :: i64) -> Bool {
    true
  }

  pub fn spawn_registry_readers(count :: i64, reads :: i64) -> Bool {
    reader = Process.spawn(&TestConcurrency.BlobTest.registry_reader_entry/0)
    _channel = Process.send(Process.pid(u64, reader), Process.self())
    _budget = Process.send(Process.pid(i64, reader), reads)
    TestConcurrency.BlobTest.spawn_registry_readers(count - 1, reads)
  }

  @doc = """
    Replaces the storm key's value `rounds` times while the readers run,
    releasing this process's own reference after each put (the registry
    reference is the value's only long-lived tether).
    """

  pub fn replace_storm(0 :: i64) -> Bool {
    true
  }

  pub fn replace_storm(rounds :: i64) -> Bool {
    replacement = Blob.new("r replacement")
    _put = Blob.put_global(:blob_test_storm_key, replacement)
    _dropped = Blob.release(replacement)
    TestConcurrency.BlobTest.replace_storm(rounds - 1)
  }

  @doc = """
    Sums the readers' reported success counts.
    """

  pub fn collect_reader_totals(0 :: i64, total :: i64) -> i64 {
    total
  }

  pub fn collect_reader_totals(remaining :: i64, total :: i64) -> i64 {
    reported = Process.receive_raw(i64)
    TestConcurrency.BlobTest.collect_reader_totals(remaining - 1, total + reported)
  }

  @doc = """
    The storm sender's loop: create → share → release, `remaining` times.
    Each iteration's blob is held only by the in-flight envelope after
    the local release — the consumer (or its teardown) is the last
    holder.
    """

  pub fn send_storm(_target :: u64, 0 :: i64) -> Bool {
    true
  }

  pub fn send_storm(target :: u64, remaining :: i64) -> Bool {
    blob = Blob.new("storm payload bytes")
    _sent = Process.send((Pid.of(target) :: Pid(Blob)), blob)
    _released = Blob.release(blob)
    TestConcurrency.BlobTest.send_storm(target, remaining - 1)
  }

  @doc = """
    The storm consumer: receives its reply channel and blob budget, then
    receives/verifies/releases every blob, reporting the summed sizes.
    """

  pub fn storm_consumer_entry() -> Nil {
    parent = Process.receive_raw(u64)
    expected = Process.receive_raw(i64)
    total = TestConcurrency.BlobTest.consume_storm(expected, 0)
    _reported = Process.send(Process.pid(i64, parent), total)
    nil
  }

  @doc = """
    The consumer's receive/verify/release loop, accumulating sizes.
    """

  pub fn consume_storm(0 :: i64, total :: i64) -> i64 {
    total
  }

  pub fn consume_storm(remaining :: i64, total :: i64) -> i64 {
    blob = receive Blob {
      b -> b
    }
    observed = Blob.size(blob)
    _released = Blob.release(blob)
    TestConcurrency.BlobTest.consume_storm(remaining - 1, total + observed)
  }
}
