pub struct TestConcurrency.CrossModelSendTest {
  use Zest.Case

  # P3-J4 acceptance proof: cross-MODEL message copy. A process running one
  # reclamation model sends a rich List/Map/String payload to a process running
  # a DIFFERENT model, in the same binary. The sender serializes MODEL-AGNOSTIC
  # bytes (reads the source graph only, touches no refcount — the neutral blob
  # carries zero live refcounts, so the sacred scheduler-local-refcount
  # invariant holds by construction); the receiver reconstructs an INDEPENDENT
  # copy into ITS OWN heap under ITS OWN reclamation model, routed by the
  # per-process manager dispatch (docs/memory-manager-abi.md §10.5). Cross-model
  # traffic is ALWAYS a copy, never an O(1) move (move is same-model only).
  #
  # The `:test_concurrency` manifest selects Memory.ARC (the default); the
  # Arena processes are spawned with an explicit per-spawn Memory.Arena, so this
  # binary links BOTH backends and runs BOTH models at once. The receiver-model
  # reconstruction is chosen by the RECEIVER: an Arena receiver's copy is
  # reclaimed WHOLESALE at its teardown (no per-drop free — bulk_or_never); an
  # ARC receiver's copy is reclaimed per-drop / at arcDeinit. Either way the
  # original in the sending process is never touched.

  pub struct Payload {
    count :: i64
    label :: String
    numbers :: [i64]
    lookup :: %{Atom => i64}
  }

  describe("cross-model rich-payload send/receive") {
    test("an ARC parent sends a List/Map/String struct to an Arena child — independent arena-owned copy") {
      # The Arena child reconstructs the payload into ITS OWN Arena heap (no
      # cell is shared across the process boundary; the String bytes are adopted
      # into the Arena, reclaimed wholesale at the child's teardown) and reports
      # a checksum over EVERY field, proving fidelity of the cross-model copy.
      # If reconstruction routed cells to the wrong heap or corrupted a field,
      # the checksum would differ or the child would crash.
      child = Process.pid(u64, Process.spawn(&TestConcurrency.CrossModelSendTest.arena_payload_reporter/0, Memory.Arena))
      _channel = Process.send(child, Process.self())
      payload = %Payload{
        count: 3,
        label: "hi world",
        numbers: [10, 20, 30],
        lookup: %{alpha: 100, beta: 200}
      }
      _sent = Process.send((Pid.of(child.raw) :: Pid(Payload)), payload)
      checksum = receive i64 {
        n -> n
      }
      # count(3) + numbers(10+20+30=60) + map values(100+200=300) + label
      # length("hi world"=8) = 371.
      assert(checksum == 371)

      # The ARC parent's ORIGINAL is untouched — send BORROWS, never moves, and
      # the receiver only READ the neutral blob (the scheduler-local invariant).
      # Reading the original here would be a use-after-free had send consumed it.
      assert(payload.count == 3)
      assert(List.length(payload.numbers) == 3)
      assert(List.get(payload.numbers, 2) == 30)
      assert(String.length(payload.label) == 8)
    }

    test("an Arena child sends a List/Map/String struct back to the ARC parent — independent ARC-owned copy") {
      # The reverse direction proves the reconstruction model is chosen by the
      # RECEIVER, not the sender: an Arena PRODUCER builds a rich payload in its
      # own Arena heap and sends it to the ARC parent, which reconstructs the
      # graph as rc=1 cells in ITS ARC heap.
      producer = Process.pid(u64, Process.spawn(&TestConcurrency.CrossModelSendTest.arena_payload_producer/0, Memory.Arena))
      _channel = Process.send(producer, Process.self())
      got = receive Payload {
        p -> p
      }
      assert(got.count == 7)
      assert(List.length(got.numbers) == 3)
      assert(List.get(got.numbers, 0) == 1)
      assert(List.get(got.numbers, 1) == 2)
      assert(List.get(got.numbers, 2) == 4)
      assert(Map.get(got.lookup, :seven, 0) == 70)
      assert(got.label == "from arena")
    }

    test("same-model ARC→ARC rich send still round-trips (cross-model-work regression)") {
      # The same-model path (both processes manifest ARC) is unchanged by the
      # cross-model work: a List reconstructs faithfully in the ARC child.
      child = Process.pid(u64, Process.spawn(&TestConcurrency.CrossModelSendTest.arc_list_reporter/0))
      _channel = Process.send(child, Process.self())
      _sent = Process.send((Pid.of(child.raw) :: Pid([i64])), [5, 15, 25])
      total = receive i64 {
        n -> n
      }
      assert(total == 45)
    }
  }

  # -- child process entries (zero-parameter; each first receives the parent's
  # -- raw pid bits as its reply channel) -----------------------------------

  # Arena child: receive the parent reply channel, then a rich Payload;
  # reconstruct it into THIS process's Arena heap (bulk_or_never model) and
  # report a checksum over every field back over the scalar reply channel.
  pub fn arena_payload_reporter() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    got = receive Payload {
      p -> p
    }
    numbers_sum = List.get(got.numbers, 0) + List.get(got.numbers, 1) + List.get(got.numbers, 2)
    map_sum = Map.get(got.lookup, :alpha, 0) + Map.get(got.lookup, :beta, 0)
    checksum = got.count + numbers_sum + map_sum + String.length(got.label)
    _sent = Process.send(parent, checksum)
    nil
  }

  # Arena producer: build a rich Payload in the Arena heap and send it to the
  # ARC parent — the Arena→ARC cross-model copy direction.
  pub fn arena_payload_producer() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    payload = %Payload{
      count: 7,
      label: "from arena",
      numbers: [1, 2, 4],
      lookup: %{seven: 70}
    }
    _sent = Process.send((Pid.of(parent.raw) :: Pid(Payload)), payload)
    nil
  }

  # ARC child (same-model regression): receive a List and report its sum.
  pub fn arc_list_reporter() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    values = receive [i64] {
      got -> got
    }
    total = List.get(values, 0) + List.get(values, 1) + List.get(values, 2)
    _sent = Process.send(parent, total)
    nil
  }
}
