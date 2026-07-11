pub struct TestConcurrency.MoveSendTest {
  use Zest.Case

  # P3-J5 (plan item 6.1): the same-model O(1) region-move send
  # (`Process.send_move`). These are the POSITIVE end-to-end assertions that
  # the move path delivers correctly and that the copy fallback is transparent.
  # `send_move` CONSUMES its message (the value is transferred to the receiver),
  # so no test reuses a moved binding — that is a use-after-move compile error
  # (pinned in `src/zir_integration_tests.zig`).

  describe("send_move delivers, with move O(1) for large payloads and copy for the rest") {
    test("a LARGE uniquely-owned List move-sends and the receiver gets the whole value") {
      # 1000 i64s (~8 KB) is above the 4 KiB slab ceiling, so the backing is a
      # standalone page-allocator block — the shape the O(1) region-move
      # re-parents WITHOUT copying (the sender detaches the cell, the receiver
      # adopts it in place, no reconstruct). Same-model receiver (self, ARC).
      data = List.new_filled(1000, 42 :: i64)
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      moves_before = RuntimeInfo.region_move_send_count()
      _sent = Process.send_move(self_pid, data)
      received = receive [i64] {
        got -> got
      }
      assert(List.length(received) == 1000)
      assert(List.get(received, 0) == 42)
      assert(List.get(received, 999) == 42)
      # The MOVE path actually ran — a silent copy fallback bumps neither
      # region-move counter, so value-delivery asserts alone cannot tell the
      # two apart.
      assert(RuntimeInfo.region_move_send_count() == moves_before + 1)
    }

    test("a SMALL List send_move transparently degrades to copy and still delivers") {
      # A 3-element list is slab-backed (interleaved in a shared slab), so it is
      # NOT relocatable per-cell: send_move falls back to the deep-copy send. The
      # result is identical — the receiver gets the value — only the cost differs.
      small = [1, 2, 3]
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      moves_before = RuntimeInfo.region_move_send_count()
      _sent = Process.send_move(self_pid, small)
      received = receive [i64] {
        got -> got
      }
      assert(List.length(received) == 3)
      assert(List.get(received, 1) == 2)
      # The copy fallback bumps NO region-move counter — the discriminator's
      # negative half.
      assert(RuntimeInfo.region_move_send_count() == moves_before)
    }

    test("a moved List is a fresh, independent value the receiver solely owns") {
      # After the move the receiver owns the value outright (rc == 1) and can
      # mutate/read it freely; the sender no longer references it (consumed).
      payload = List.new_filled(800, 7 :: i64)
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _sent = Process.send_move(self_pid, payload)
      owned = receive [i64] {
        got -> got
      }
      assert(List.length(owned) == 800)
      assert(List.get(owned, 400) == 7)
    }
  }

  describe("send_move moves flat Maps O(1) — the E6 map-catastrophe fix (P6-J1, plan 6.1a)") {
    test("a LARGE uniquely-owned flat Map move-sends and EVERY lookup works on the receiver — no rebuild") {
      # 400 entries force a 512-slot table (~16 KB cell), above the 4 KiB slab
      # ceiling — a standalone page-backed block the O(1) region-move
      # re-parents whole. The receiver's map is usable IMMEDIATELY: the cell
      # layout is position-independent (buckets reference entries by INDEX,
      # the hash seed travels inside the cell), so there is NO hash-table
      # rebuild — the 2.19 ms/MB reconstruct E6 measured is gone. Lookups are
      # verified EXHAUSTIVELY (all 400 keys), the correctness crux: a moved
      # map whose buckets/hashes went stale would fail these probes.
      data = TestConcurrency.MoveSendTest.build_map(%{}, 400)
      self_pid = (Pid.of(Process.self()) :: Pid(%{i64 => i64}))
      moves_before = RuntimeInfo.region_move_send_count()
      _sent = Process.send_move(self_pid, data)
      received = receive %{i64 => i64} {
        got -> got
      }
      assert(Map.size(received) == 400)
      assert(TestConcurrency.MoveSendTest.verify_map(received, 400))
      # The Map rode the MOVE path (not the 2.19 ms/MB copy rebuild): the
      # region-move send counter incremented across this send.
      assert(RuntimeInfo.region_move_send_count() == moves_before + 1)
    }

    test("a SMALL flat Map send_move transparently degrades to copy and still delivers") {
      # A 3-entry map is slab-backed (interleaved in a shared slab), so it is
      # NOT relocatable per-cell: send_move falls back to the deep-copy send.
      small = %{1 => 10, 2 => 20, 3 => 30}
      self_pid = (Pid.of(Process.self()) :: Pid(%{i64 => i64}))
      _sent = Process.send_move(self_pid, small)
      received = receive %{i64 => i64} {
        got -> got
      }
      assert(Map.size(received) == 3)
      assert(Map.get(received, 2, -1) == 20)
    }

    test("a NON-FLAT Map (String values) send_move falls back to copy — interior cells cannot re-parent") {
      # String values live in SEPARATE cells; re-parenting only the map root
      # would strand them in the sender's heap, so the move predicate rejects
      # the shape at compile time and the send deep-copies the whole graph.
      labeled = %{1 => "one", 2 => "two"}
      self_pid = (Pid.of(Process.self()) :: Pid(%{i64 => String}))
      _sent = Process.send_move(self_pid, labeled)
      received = receive %{i64 => String} {
        got -> got
      }
      assert(Map.size(received) == 2)
      assert(Map.get(received, 1, "") == "one")
      assert(Map.get(received, 2, "") == "two")
    }

    test("a moved Map is a fresh value the receiver solely owns — rc == 1, in-place mutation works") {
      # The receiver owns the moved cell outright (the sender was consumed),
      # so a put takes the rc-1 in-place fast path and the map stays coherent.
      payload = TestConcurrency.MoveSendTest.build_map(%{}, 300)
      self_pid = (Pid.of(Process.self()) :: Pid(%{i64 => i64}))
      _sent = Process.send_move(self_pid, payload)
      owned = receive %{i64 => i64} {
        got -> got
      }
      updated = Map.put(owned, 9999, 42)
      assert(Map.size(updated) == 301)
      assert(Map.get(updated, 9999, -1) == 42)
      assert(Map.get(updated, 150, -1) == 450)
    }

    test("a cross-model Map send_move still copies — the move is same-model only") {
      # An Arena receiver runs a DIFFERENT reclamation model, so the same-model
      # gate declines the move BEFORE detaching and the send degrades to the
      # cross-model deep copy (P3-J4): the Arena child reconstructs the map
      # into its own bulk heap and reports an exhaustive verdict.
      child = Process.pid(u64, Process.spawn(&TestConcurrency.MoveSendTest.arena_map_reporter/0, Memory.Arena))
      _channel = Process.send(child, Process.self())
      big = TestConcurrency.MoveSendTest.build_map(%{}, 400)
      _sent = Process.send_move((Pid.of(child.raw) :: Pid(%{i64 => i64})), big)
      verified = receive Bool {
        ok -> ok
      }
      assert(verified)
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
    TestConcurrency.MoveSendTest.build_map(Map.put(acc, count, count * 3), count - 1)
  }

  @doc = """
    Verify EVERY entry `n => n * 3` for `n = 1..count` is present and correct —
    the exhaustive post-move lookup probe.
    """

  pub fn verify_map(map :: %{i64 => i64}, 0 :: i64) -> Bool {
    true
  }

  pub fn verify_map(map :: %{i64 => i64}, count :: i64) -> Bool {
    Map.get(map, count, -1) == count * 3 and TestConcurrency.MoveSendTest.verify_map(map, count - 1)
  }

  @doc = """
    Arena child for the cross-model fallback case: receives the reply channel,
    then a `%{i64 => i64}` map (reconstructed into the Arena heap by the copy
    path), verifies it exhaustively, and reports the verdict.
    """

  pub fn arena_map_reporter() -> Nil {
    parent = Process.pid(u64, Process.receive_raw(u64))
    got = receive %{i64 => i64} {
      m -> m
    }
    ok = Map.size(got) == 400 and TestConcurrency.MoveSendTest.verify_map(got, 400)
    _sent = Process.send((Pid.of(parent.raw) :: Pid(Bool)), ok)
    nil
  }
}
