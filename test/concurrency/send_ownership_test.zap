pub struct Concurrency.SendOwnershipTest {
  use Zest.Case

  # P2-J7 (plan item 2.6): positive coverage for the send-boundary
  # concurrency verifier (`src/concurrency_verifier.zig`). Every send
  # below is SOUND under the Phase-2 deep-COPY send, so the verifier's
  # enforced copy-path invariant (C1) must ACCEPT it — the whole file
  # compiling and round-tripping IS the assertion that C1 has no false
  # positives on shipping IR. The cases span the ownership shapes the
  # verifier reasons over: freshly-owned values, values reused after a
  # send, and — the case a naive "reject borrowed at send" rule would
  # wrongly reject — a BORROWED value forwarded into a send.

  describe("copy-send accepts every sound ownership shape") {
    test("a freshly-constructed owned List sends and round-trips") {
      # `[1, 2, 3]` is a fresh, owned value. The copy-send reads it to
      # serialize; the sender's own end-of-scope release frees it.
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _sent = Process.send(self_pid, [1, 2, 3])
      received = receive [i64] {
        got -> got
      }
      assert(List.length(received) == 3)
      assert(List.get(received, 1) == 2)
    }

    test("a value stays usable after being sent — copy borrows, never moves") {
      # The verifier accepts this because the send does not consume its
      # argument; the runtime confirms the original survives the send.
      original = [10, 20, 30, 40]
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _sent = Process.send(self_pid, original)
      _received = receive [i64] {
        got -> got
      }
      # Reusing `original` after the send would be a use-after-free had
      # the send moved it. It still yields four elements: send borrowed.
      assert(List.length(original) == 4)
      assert(List.get(original, 3) == 40)
    }

    test("the same value sent twice is read independently by the receiver") {
      original = [7, 8]
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _first = Process.send(self_pid, original)
      _second = Process.send(self_pid, original)
      first_copy = receive [i64] {
        got -> got
      }
      second_copy = receive [i64] {
        got -> got
      }
      assert(List.length(first_copy) == 2)
      assert(List.length(second_copy) == 2)
      assert(List.get(first_copy, 0) == 7)
      assert(List.get(second_copy, 1) == 8)
    }

    test("a BORROWED parameter forwarded into a send is accepted and stays valid") {
      # `forward_and_measure` receives `values` as a borrowed parameter
      # (caller-retained) and sends it. Under the Phase-2 copy-send this
      # is SOUND — reading a borrow to deep-copy it is exactly what a
      # borrow permits, and the receiver gets an independent copy. A
      # naive "no borrowed value reaches a send" rule would reject this;
      # the verifier correctly accepts it (borrowed-at-send is a
      # Phase-3 MOVE-send concern, not a copy-send one).
      caller_owned = [100, 200, 300]
      measured = Concurrency.SendOwnershipTest.forward_and_measure(caller_owned)
      assert(measured == 3)
      # The caller still owns `caller_owned` after lending it to the
      # helper that sent it.
      assert(List.length(caller_owned) == 3)
      assert(List.get(caller_owned, 2) == 300)
    }
  }

  # Receives `values` as a BORROWED parameter, sends it to itself (the
  # send reads the borrow to deep-copy it), drains the mailbox, and
  # returns the borrow's length — proving the borrow is still live after
  # the send. This is the send-boundary shape P2-J7's Phase-2 analysis
  # concludes is sound under copy semantics.
  pub fn forward_and_measure(values :: [i64]) -> i64 {
    self_pid = (Pid.of(Process.self()) :: Pid([i64]))
    _sent = Process.send(self_pid, values)
    _drained = receive [i64] {
      got -> got
    }
    List.length(values)
  }
}
