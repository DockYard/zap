pub struct TestConcurrency.RichMessageTest {
  use Zest.Case

  # A message struct spanning every sendable field kind — the "struct
  # containing these" case. Sent and received BY VALUE through the deep-copy
  # walker; its owned List/Map/String fields are reconstructed as fresh,
  # receiver-owned copies.
  pub struct Payload {
    count :: i64
    label :: String
    numbers :: [i64]
    lookup :: %{Atom => i64}
  }

  describe("rich message deep-copy send/receive") {
    test("a List(i64) round-trips by value through the mailbox") {
      original = [10, 20, 30]
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _sent = Process.send(self_pid, original)
      received = receive [i64] {
        got -> got
      }
      assert(List.length(received) == 3)
      assert(List.get(received, 0) == 10)
      assert(List.get(received, 1) == 20)
      assert(List.get(received, 2) == 30)
    }

    test("a nested List(List(i64)) round-trips every level") {
      original = [[7, 8], [9]]
      self_pid = (Pid.of(Process.self()) :: Pid([[i64]]))
      _sent = Process.send(self_pid, original)
      received = receive [[i64]] {
        got -> got
      }
      assert(List.length(received) == 2)
      inner_first = List.get(received, 0)
      assert(List.length(inner_first) == 2)
      assert(List.get(inner_first, 0) == 7)
      assert(List.get(inner_first, 1) == 8)
      inner_second = List.get(received, 1)
      assert(List.length(inner_second) == 1)
      assert(List.get(inner_second, 0) == 9)
    }

    test("a Map round-trips its entries") {
      original = %{alpha: 1, beta: 2}
      self_pid = (Pid.of(Process.self()) :: Pid(%{Atom => i64}))
      _sent = Process.send(self_pid, original)
      received = receive %{Atom => i64} {
        got -> got
      }
      assert(Map.get(received, :alpha, 0) == 1)
      assert(Map.get(received, :beta, 0) == 2)
    }

    test("a dynamically-constructed String round-trips by value") {
      # Interpolation builds a fresh arena-backed string (NOT a .rodata
      # literal) — the shape the String send-by-value soundness fix protects.
      name = "world"
      original = "hello #{name}"
      self_pid = (Pid.of(Process.self()) :: Pid(String))
      _sent = Process.send(self_pid, original)
      received = receive String {
        got -> got
      }
      assert(received == "hello world")
    }

    test("the sender keeps its original after send — send borrows, never moves") {
      original = [1, 2, 3]
      self_pid = (Pid.of(Process.self()) :: Pid([i64]))
      _sent = Process.send(self_pid, original)
      received = receive [i64] {
        got -> got
      }
      # Had send MOVED (consumed) `original`, reading it here would be a
      # use-after-free. That it still yields its three elements proves the
      # walker only READ the source: the sender retains ownership and its own
      # end-of-scope release frees it (so a rich send never leaks the original).
      assert(List.length(original) == 3)
      assert(List.get(original, 2) == 3)
      assert(List.length(received) == 3)
      assert(List.get(received, 0) == 1)
    }

    test("a struct containing a String, List, and Map round-trips by value") {
      original = %Payload{
        count: 5,
        label: "payload #{1 + 1}",
        numbers: [11, 22],
        lookup: %{seven: 70}
      }
      self_pid = (Pid.of(Process.self()) :: Pid(Payload))
      _sent = Process.send(self_pid, original)
      received = receive Payload {
        got -> got
      }
      assert(received.count == 5)
      assert(received.label == "payload 2")
      assert(List.length(received.numbers) == 2)
      assert(List.get(received.numbers, 0) == 11)
      assert(List.get(received.numbers, 1) == 22)
      assert(Map.get(received.lookup, :seven, 0) == 70)
    }
  }

  describe("rich message independence across processes") {
    test("a List sent to a child arrives as a complete independent copy") {
      # The list is serialized on the parent and reconstructed as a fresh copy
      # in the CHILD's own heap — no cell is shared across the process
      # boundary. The child confirms it received every element by reporting the
      # copy's length back over a scalar reply channel.
      child = Process.pid(u64, Process.spawn(&TestConcurrency.RichMessageTest.list_length_reporter/0))
      _channel = Process.send(child, Process.self())
      _payload = Process.send((Pid.of(child.raw) :: Pid([i64])), [100, 200, 300, 400])
      reported_length = receive i64 {
        n -> n
      }
      assert(reported_length == 4)
    }
  }

  # -- child process entry: receives the parent's reply channel, then a list,
  # -- and reports the received copy's length back. -------------------------
  pub fn list_length_reporter() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    values = receive [i64] {
      got -> got
    }
    _sent = Process.send(parent, List.length(values))
    nil
  }
}
