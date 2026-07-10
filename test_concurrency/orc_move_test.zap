pub struct TestConcurrency.OrcMoveTest {
  use Zest.Case

  # P6-J1 (plan item 6.1a follow-on): the same-model O(1) region-move send for
  # ORC processes. ORC's REFCOUNT_V1 v1.2 relocate slots are wired through its
  # production SlabHeap large path (`src/memory/orc/manager.zig`), and ORC
  # declares the refcounted model byte-identically to ARC, so a large flat
  # container moves between ANY two refcounted processes — ORC→ARC, ARC→ORC,
  # and ORC→ORC — over the shared cross-manager `LargeHeader` ABI. These are
  # the language-surface proofs for all three directions; the manager-level
  # mechanics (detach/adopt/leak-exactness, the collector-state guard) are
  # proven in the ORC manager's own unit tests.

  describe("ORC processes participate in the O(1) region-move send") {
    test("ORC→ARC: an ORC producer move-sends a LARGE flat Map to the ARC parent — every lookup works") {
      # The ORC child builds a 400-entry flat map on ITS OWN ORC SlabHeap
      # (~16 KB cell → the page-backed large path), DETACHES it through ORC's
      # relocate slot, and the ARC parent ADOPTS it — exhaustive lookups prove
      # the cell crossed intact with no rebuild.
      producer = Process.pid(u64, Process.spawn(&TestConcurrency.OrcMoveTest.orc_map_producer/0, Memory.ORC))
      _channel = Process.send(producer, Process.self())
      received = receive %{i64 => i64} {
        got -> got
      }
      assert(Map.size(received) == 400)
      assert(TestConcurrency.OrcMoveTest.verify_map(received, 400))
    }

    test("ARC→ORC: the ARC parent move-sends a LARGE flat Map to an ORC receiver — verified exhaustively") {
      # The reverse direction: ARC detach, ORC adopt (the block joins the ORC
      # child's SlabHeap large list, so the child's release reclaims it on its
      # own heap). The child verifies all 400 entries and reports the verdict.
      child = Process.pid(u64, Process.spawn(&TestConcurrency.OrcMoveTest.orc_map_verifier/0, Memory.ORC))
      _channel = Process.send(child, Process.self())
      big = TestConcurrency.OrcMoveTest.build_map(%{}, 400)
      _sent = Process.send_move((Pid.of(child.raw) :: Pid(%{i64 => i64})), big)
      verified = receive Bool {
        ok -> ok
      }
      assert(verified)
    }

    test("ORC→ORC: a LARGE flat List moves between two ORC processes") {
      # Both heaps are ORC SlabHeaps: ORC detach + ORC adopt. The receiver is
      # spawned first and acknowledges readiness BEFORE the producer exists,
      # so its typed receives can never interleave with the moved payload.
      receiver = Process.pid(u64, Process.spawn(&TestConcurrency.OrcMoveTest.orc_list_receiver/0, Memory.ORC))
      _channel = Process.send(receiver, Process.self())
      ready = receive Bool {
        ok -> ok
      }
      assert(ready)
      producer = Process.pid(u64, Process.spawn(&TestConcurrency.OrcMoveTest.orc_list_producer/0, Memory.ORC))
      _target = Process.send(producer, receiver.raw)
      total = receive i64 {
        n -> n
      }
      # 1200 elements of 5 → 6000.
      assert(total == 6000)
    }
  }

  # -- helpers ----------------------------------------------------------------

  @doc = """
    Build a flat `%{i64 => i64}` map with entries `n => n * 3` for
    `n = 1..count` (tail-recursive; the Zap loop idiom).
    """

  pub fn build_map(acc :: %{i64 => i64}, 0 :: i64) -> %{i64 => i64} {
    acc
  }

  pub fn build_map(acc :: %{i64 => i64}, count :: i64) -> %{i64 => i64} {
    TestConcurrency.OrcMoveTest.build_map(Map.put(acc, count, count * 3), count - 1)
  }

  @doc = """
    Verify EVERY entry `n => n * 3` for `n = 1..count` — the exhaustive
    post-move lookup probe.
    """

  pub fn verify_map(map :: %{i64 => i64}, 0 :: i64) -> Bool {
    true
  }

  pub fn verify_map(map :: %{i64 => i64}, count :: i64) -> Bool {
    Map.get(map, count, -1) == count * 3 and TestConcurrency.OrcMoveTest.verify_map(map, count - 1)
  }

  @doc = """
    Sum a `[i64]` list tail-recursively (index counts down from length to 1).
    """

  pub fn sum_list(list :: [i64], 0 :: i64, acc :: i64) -> i64 {
    acc
  }

  pub fn sum_list(list :: [i64], index :: i64, acc :: i64) -> i64 {
    TestConcurrency.OrcMoveTest.sum_list(list, index - 1, acc + List.get(list, index - 1))
  }

  @doc = """
    ORC producer (ORC→ARC direction): builds a LARGE flat map on its own ORC
    heap and move-sends it to the parent.
    """

  pub fn orc_map_producer() -> Nil {
    parent = Process.pid(u64, Process.receive_raw(u64))
    data = TestConcurrency.OrcMoveTest.build_map(%{}, 400)
    _sent = Process.send_move((Pid.of(parent.raw) :: Pid(%{i64 => i64})), data)
    nil
  }

  @doc = """
    ORC receiver (ARC→ORC direction): adopts a moved LARGE flat map into its
    ORC heap, verifies it exhaustively, and reports the verdict.
    """

  pub fn orc_map_verifier() -> Nil {
    parent = Process.pid(u64, Process.receive_raw(u64))
    got = receive %{i64 => i64} {
      m -> m
    }
    ok = Map.size(got) == 400 and TestConcurrency.OrcMoveTest.verify_map(got, 400)
    _sent = Process.send((Pid.of(parent.raw) :: Pid(Bool)), ok)
    nil
  }

  @doc = """
    ORC list receiver (ORC→ORC direction): acknowledges readiness to the
    parent, adopts the moved list, and reports its element sum to the parent.
    """

  pub fn orc_list_receiver() -> Nil {
    parent = Process.pid(u64, Process.receive_raw(u64))
    _ready = Process.send((Pid.of(parent.raw) :: Pid(Bool)), true)
    values = receive [i64] {
      got -> got
    }
    total = TestConcurrency.OrcMoveTest.sum_list(values, List.length(values), 0)
    _sent = Process.send((Pid.of(parent.raw) :: Pid(i64)), total)
    nil
  }

  @doc = """
    ORC list producer (ORC→ORC direction): receives the TARGET pid, builds a
    LARGE flat list on its own ORC heap, and move-sends it to the target.
    """

  pub fn orc_list_producer() -> Nil {
    target = Process.pid(u64, Process.receive_raw(u64))
    data = List.new_filled(1200, 5 :: i64)
    _sent = Process.send_move((Pid.of(target.raw) :: Pid([i64])), data)
    nil
  }
}
