pub struct TestConcurrency.ProcessTest {
  use Zest.Case

  describe("Process.self") {
    test("returns a live nonzero pid that is stable across calls") {
      first_bits = Process.self()
      second_bits = Process.self()
      assert(first_bits != 0)
      assert(first_bits == second_bits)
    }
  }

  describe("Process.spawn") {
    test("runs a named zero-parameter function to completion") {
      completion_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.completion_entry/0))
      _delivered = Process.send(completion_child, Process.self())
      completion_value = Process.receive_raw(i64)
      assert(completion_value == 7777)
    }

    test("spawned process observes its own pid as the one spawn returned") {
      child_bits = Process.spawn(&TestConcurrency.ProcessTest.self_reporting_entry/0)
      identity_child = Process.pid(u64, child_bits)
      _delivered = Process.send(identity_child, Process.self())
      reported_bits = Process.receive_raw(u64)
      assert(reported_bits == child_bits)
      assert(reported_bits != Process.self())
    }
  }

  describe("Process.send and Process.receive_raw") {
    test("i64 ping-pong round-trips values between two processes") {
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.echo_i64_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(i64, echo_child.raw), 41)
      echoed = Process.receive_raw(i64)
      assert(echoed == 42)
    }

    test("f64 payloads round-trip") {
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.echo_f64_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(f64, echo_child.raw), 1.5)
      echoed = Process.receive_raw(f64)
      assert(echoed == 3.0)
    }

    test("Bool payloads round-trip") {
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.negate_bool_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(Bool, echo_child.raw), true)
      echoed = Process.receive_raw(Bool)
      assert(echoed == false)
    }

    test("Atom payloads round-trip") {
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.echo_atom_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      _sent = Process.send(Process.pid(Atom, echo_child.raw), :ping)
      echoed = Process.receive_raw(Atom)
      assert(echoed == :ping)
    }

    test("pairwise message ordering is FIFO") {
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.echo_three_i64_entry/0))
      _delivered = Process.send(echo_child, Process.self())
      typed_child = Process.pid(i64, echo_child.raw)
      _first = Process.send(typed_child, 1)
      _second = Process.send(typed_child, 2)
      _third = Process.send(typed_child, 3)
      first_echo = Process.receive_raw(i64)
      second_echo = Process.receive_raw(i64)
      third_echo = Process.receive_raw(i64)
      assert(first_echo == 101)
      assert(second_echo == 102)
      assert(third_echo == 103)
    }

    test("send returns true for a live target") {
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.echo_i64_entry/0))
      delivered = Process.send(echo_child, Process.self())
      assert(delivered == true)
      _sent = Process.send(Process.pid(i64, echo_child.raw), 0)
      _echoed = Process.receive_raw(i64)
    }

    test("send to a never-issued pid dead-letters and returns false") {
      forged = Process.pid_of_i64(0)
      delivered = Process.send(forged, 99)
      assert(delivered == false)
    }
  }

  describe("Process.exit") {
    test("a child that exits explicitly still delivers messages sent before the exit") {
      exiting_child = Process.pid(u64, Process.spawn(&TestConcurrency.ProcessTest.exit_after_reply_entry/0))
      _delivered = Process.send(exiting_child, Process.self())
      reply = Process.receive_raw(i64)
      assert(reply == 55)
    }
  }

  describe("typed pid constructors") {
    test("Process.pid tokens produce handles carrying the raw bits unchanged") {
      self_bits = Process.self()
      typed_i64 = Process.pid(i64, self_bits)
      typed_u64 = Process.pid(u64, self_bits)
      typed_f64 = Process.pid(f64, self_bits)
      typed_bool = Process.pid(Bool, self_bits)
      typed_atom = Process.pid(Atom, self_bits)
      assert(typed_i64.raw == self_bits)
      assert(typed_u64.raw == self_bits)
      assert(typed_f64.raw == self_bits)
      assert(typed_bool.raw == self_bits)
      assert(typed_atom.raw == self_bits)
    }
  }

  # -- child process entries (zero-parameter; each first receives the
  # -- parent's raw pid bits as its reply channel) ------------------------

  pub fn completion_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 7777)
    nil
  }

  pub fn self_reporting_entry() -> Nil {
    parent = Process.pid(u64, Process.receive_raw(u64))
    _sent = Process.send(parent, Process.self())
    nil
  }

  pub fn echo_i64_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    value = Process.receive_raw(i64)
    _sent = Process.send(parent, value + 1)
    nil
  }

  pub fn echo_f64_entry() -> Nil {
    parent = Process.pid(f64, Process.receive_raw(u64))
    value = Process.receive_raw(f64)
    _sent = Process.send(parent, value * 2.0)
    nil
  }

  pub fn negate_bool_entry() -> Nil {
    parent = Process.pid(Bool, Process.receive_raw(u64))
    value = Process.receive_raw(Bool)
    _sent = Process.send(parent, Bool.negate(value))
    nil
  }

  pub fn echo_atom_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    value = Process.receive_raw(Atom)
    _sent = Process.send(parent, value)
    nil
  }

  pub fn echo_three_i64_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    first_value = Process.receive_raw(i64)
    _first = Process.send(parent, first_value + 100)
    second_value = Process.receive_raw(i64)
    _second = Process.send(parent, second_value + 100)
    third_value = Process.receive_raw(i64)
    _third = Process.send(parent, third_value + 100)
    nil
  }

  pub fn exit_after_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 55)
    Process.exit()
  }
}
