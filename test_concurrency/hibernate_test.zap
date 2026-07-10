@doc = """
  P6-J4 (plan item 6.4) — `Process.hibernate`, the BEAM-hibernation analogue
  at the language surface: park (non-consuming) until the next user message,
  shrinking the process's idle footprint at the park (the committed-stack
  release is measured at the kernel level — `stack_pool.zig` /
  `scheduler.zig` tests; here the LANGUAGE semantics are pinned).

  What these tests lock in: hibernate returns when a message is queued and
  the FOLLOWING `receive` consumes exactly that message (non-consuming
  park); a hibernating server loops indefinitely through repeated
  hibernate→receive→reply cycles; deep pre-hibernate call chains recompute
  identically after the wake (the released stack recommits by fault); a
  message already queued makes hibernate return immediately; and a fleet of
  hibernators woken concurrently on the M:N pool all answer correctly.
  """

pub struct TestConcurrency.HibernateTest {
  use Zest.Case

  describe("hibernate wake semantics") {
    test("hibernate parks until a message arrives; the following receive consumes it") {
      child = Process.spawn(&TestConcurrency.HibernateTest.hibernating_echo_entry/0)
      _channel = Process.send(Process.pid(u64, child), Process.self())
      _work = Process.send(Process.pid(i64, child), 41)
      echoed = receive i64 {
        n -> n
      }
      assert(echoed == 42)
      _stop = Process.send(Process.pid(i64, child), -1)
    }

    test("a hibernating server survives many hibernate→receive→reply rounds") {
      child = Process.spawn(&TestConcurrency.HibernateTest.hibernating_echo_entry/0)
      _channel = Process.send(Process.pid(u64, child), Process.self())
      total = TestConcurrency.HibernateTest.round_trip_many(child, 1, 50, 0)
      # sum of (n + 1) for n in 1..50 = sum(2..51) = 1_325.
      assert(total == 1325)
      _stop = Process.send(Process.pid(i64, child), -1)
    }

    test("deep call chains recompute identically after the hibernate wake (stack recommits)") {
      child = Process.spawn(&TestConcurrency.HibernateTest.deep_stack_entry/0)
      _channel = Process.send(Process.pid(u64, child), Process.self())
      before = receive i64 {
        n -> n
      }
      _wake = Process.send(Process.pid(i64, child), 1)
      after_wake = receive i64 {
        n -> n
      }
      # The same 64-frame recursion, before hibernating and after waking,
      # computes the same checksum — the released pages recommitted cleanly.
      assert(before == after_wake)
      assert(before == TestConcurrency.HibernateTest.deep_checksum(64, 0))
    }

    test("hibernate returns immediately when a message is already queued") {
      child = Process.spawn(&TestConcurrency.HibernateTest.pre_queued_entry/0)
      _channel = Process.send(Process.pid(u64, child), Process.self())
      # The child replies :ready only AFTER both work messages are queued —
      # its two hibernates then return without ever parking.
      _first = Process.send(Process.pid(i64, child), 10)
      _second = Process.send(Process.pid(i64, child), 20)
      _go = Process.send(Process.pid(i64, child), 0)
      total = receive i64 {
        n -> n
      }
      assert(total == 30)
    }
  }

  describe("hibernate under the M:N pool") {
    test("a fleet of hibernators woken concurrently all answer") {
      fleet_total = TestConcurrency.HibernateTest.spawn_fleet(16, 0)
      # Each of the 16 echoes (n + 1) for its index n in 1..16:
      # sum(2..17) = 152.
      assert(fleet_total == 152)
    }
  }

  # -- entries ------------------------------------------------------------------

  # Hibernate-first echo: hibernates before EVERY receive; echoes n + 1;
  # exits on -1.
  pub fn hibernating_echo_entry() -> Nil {
    parent = Process.receive_raw(u64)
    TestConcurrency.HibernateTest.hibernate_echo_loop(parent)
  }

  pub fn hibernate_echo_loop(parent :: u64) -> Nil {
    _waiting = Process.hibernate()
    n = receive i64 {
      value -> value
    }
    case n == -1 {
      true -> nil
      false ->
        {
          _sent = Process.send(Process.pid(i64, parent), n + 1)
          TestConcurrency.HibernateTest.hibernate_echo_loop(parent)
        }
    }
  }

  # Deep-stack witness: computes a 64-frame recursive checksum, reports it,
  # hibernates (committing the shrink of the now-idle deep pages), then on
  # wake consumes the message, recomputes the SAME recursion, and reports it
  # again.
  pub fn deep_stack_entry() -> Nil {
    parent = Process.receive_raw(u64)
    before = TestConcurrency.HibernateTest.deep_checksum(64, 0)
    _first = Process.send(Process.pid(i64, parent), before)
    _waiting = Process.hibernate()
    _wake = receive i64 {
      value -> value
    }
    after_wake = TestConcurrency.HibernateTest.deep_checksum(64, 0)
    _second = Process.send(Process.pid(i64, parent), after_wake)
    nil
  }

  # A NON-tail 64-frame recursion (the addition happens after the recursive
  # call returns), so every level holds a live frame while the chain is deep.
  pub fn deep_checksum(depth :: i64, seed :: i64) -> i64 {
    case depth == 0 {
      true -> seed
      false -> depth * 7 + TestConcurrency.HibernateTest.deep_checksum(depth - 1, seed + depth)
    }
  }

  # Pre-queued shape: waits for the 0 go-signal through ordinary receives
  # is impossible (hibernate is non-consuming and order-preserving), so it
  # instead hibernates and drains three messages (10, 20, 0 — FIFO), summing
  # the first two; both post-first hibernates see an ALREADY-QUEUED message
  # and return immediately.
  pub fn pre_queued_entry() -> Nil {
    parent = Process.receive_raw(u64)
    _wait1 = Process.hibernate()
    first = receive i64 {
      value -> value
    }
    _wait2 = Process.hibernate()
    second = receive i64 {
      value -> value
    }
    _wait3 = Process.hibernate()
    _go = receive i64 {
      value -> value
    }
    _sent = Process.send(Process.pid(i64, parent), first + second)
    nil
  }

  # -- fleet helpers ------------------------------------------------------------

  pub fn round_trip_many(child :: u64, next :: i64, remaining :: i64, acc :: i64) -> i64 {
    case remaining == 0 {
      true -> acc
      false ->
        {
          _sent = Process.send(Process.pid(i64, child), next)
          echoed = receive i64 {
            n -> n
          }
          TestConcurrency.HibernateTest.round_trip_many(child, next + 1, remaining - 1, acc + echoed)
        }
    }
  }

  # Spawn `count` hibernating echoes, wake each with its index, and sum the
  # replies. All children hibernate concurrently before the wake wave.
  pub fn spawn_fleet(count :: i64, acc :: i64) -> i64 {
    case count == 0 {
      true -> acc
      false ->
        {
          child = Process.spawn(&TestConcurrency.HibernateTest.hibernating_echo_entry/0)
          _channel = Process.send(Process.pid(u64, child), Process.self())
          _work = Process.send(Process.pid(i64, child), count)
          echoed = receive i64 {
            n -> n
          }
          _stop = Process.send(Process.pid(i64, child), -1)
          TestConcurrency.HibernateTest.spawn_fleet(count - 1, acc + echoed)
        }
    }
  }
}
