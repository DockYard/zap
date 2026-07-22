pub struct Concurrency.ReceiveTest {
  use Zest.Case

  describe("receive pattern dispatch") {
    test("matches the arm for a sent i64 and binds the value") {
      echo_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.echo_receive_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(i64, echo_child.raw), 41)
      result = receive i64 {
        42 -> "matched forty-two"
        other -> "other #{other}"
      }
      assert(result == "matched forty-two")
    }

    test("binds a non-literal message through a bare pattern") {
      value_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.send_seven_entry/0))
      _delivered = Process.send(value_child, Process.self())
      doubled = receive i64 {
        n -> n + n
      }
      assert(doubled == 14)
    }

    test("dispatches an Atom message to the matching arm") {
      atom_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.send_ready_atom_entry/0))
      _delivered = Process.send(atom_child, Process.self())
      label = receive Atom {
        :ready -> "is ready"
        _ -> "unknown"
      }
      assert(label == "is ready")
    }
  }

  describe("receive ping-pong (replacing receive_raw)") {
    test("round-trips a value between two processes via receive") {
      echo_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.echo_receive_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(i64, echo_child.raw), 41)
      echoed = receive i64 {
        n -> n
      }
      assert(echoed == 42)
    }
  }

  describe("receive at nested call depth") {
    test("a receive two calls deep suspends the whole fiber stack") {
      sender_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.send_twenty_one_entry/0))
      _delivered = Process.send(sender_child, Process.self())
      result = nested_receiver()
      assert(result == 42)
    }
  }

  describe("after timeout arm") {
    test("after T fires when no message arrives") {
      result = receive i64 {
        n -> n
      after
        5 -> -1
      }
      assert(result == -1)
    }

    test("after 0 polls an empty mailbox without blocking") {
      result = receive i64 {
        n -> n
      after
        0 -> -1
      }
      assert(result == -1)
    }

    test("after 0 sees an already-delivered message as a match") {
      _self_sent = Process.send(Process.pid(i64, Process.self()), 7)
      result = receive i64 {
        n -> n
      after
        0 -> -1
      }
      assert(result == 7)
    }

    test("a message that arrives before the deadline wins over the timeout") {
      echo_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.echo_receive_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(i64, echo_child.raw), 41)
      result = receive i64 {
        n -> n
      after
        1000 -> -1
      }
      assert(result == 42)
    }
  }

  describe("unexpected message dead-letter") {
    test("an unmatched message routes to the dead-letter path without crashing the program") {
      # This child's receive only matches 99, so a 7 matches no arm and is
      # dead-lettered (the child terminates cleanly). The program stays
      # alive, which we prove with a normal round-trip afterward.
      unmatched_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.only_matches_99_entry/0))
      _sent = Process.send(Process.pid(i64, unmatched_child.raw), 7)

      echo_child = Process.pid(u64, Process.spawn(&Concurrency.ReceiveTest.echo_receive_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _ping = Process.send(Process.pid(i64, echo_child.raw), 41)
      still_alive = receive i64 {
        n -> n
      }
      assert(still_alive == 42)
    }
  }

  # -- helpers exercising receive at a nested call depth ---------------------

  fn nested_receiver() -> i64 {
    helper_receive()
  }

  fn helper_receive() -> i64 {
    receive i64 {
      n -> n + n
    }
  }

  # -- child process entries (each first receives the parent's raw pid
  # -- bits as its reply channel) -------------------------------------------

  pub fn echo_receive_entry() -> Nil {
    parent_bits = receive u64 {
      bits -> bits
    }
    parent = Process.pid(i64, parent_bits)
    value = receive i64 {
      n -> n
    }
    _sent = Process.send(parent, value + 1)
    nil
  }

  pub fn send_seven_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 7)
    nil
  }

  pub fn send_twenty_one_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 21)
    nil
  }

  pub fn send_ready_atom_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _sent = Process.send(parent, :ready)
    nil
  }

  pub fn only_matches_99_entry() -> Nil {
    _matched = receive i64 {
      99 -> 99
    }
    nil
  }
}
