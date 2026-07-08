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
      _sent = Process.send_move(self_pid, data)
      received = receive [i64] {
        got -> got
      }
      assert(List.length(received) == 1000)
      assert(List.get(received, 0) == 42)
      assert(List.get(received, 999) == 42)
    }

    test("a SMALL List send_move transparently degrades to copy and still delivers") {
      # A 3-element list is slab-backed (interleaved in a shared slab), so it is
      # NOT relocatable per-cell: send_move falls back to the deep-copy send. The
      # result is identical — the receiver gets the value — only the cost differs.
      small = [1, 2, 3]
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _sent = Process.send_move(self_pid, small)
      received = receive [i64] {
        got -> got
      }
      assert(List.length(received) == 3)
      assert(List.get(received, 1) == 2)
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
}
