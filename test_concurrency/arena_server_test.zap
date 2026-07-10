@doc = """
  P6-J4 (plan item 6.4) — the receive-back-edge arena auto-reset, end to end
  through the language surface: the §2.4 arena-server growth warning CLOSED.

  A long-lived `Memory.Arena` server whose receive loop the compiler PROVES
  loop-closed (`src/receive_reset.zig`: no allocation from iteration i is
  reachable when control returns to the receive) gets an automatic O(1)
  arena reset at the top of every iteration — so its heap stays BOUNDED
  across 10,000+ messages where, before P6-J4, every per-message list and
  temporary joined the bulk set until process death. The headline test
  asserts EXACT steady state through `Process.heap_bytes` (the Arena
  manager's reserved-chunk accounting, the `STAT` capability).

  The soundness gate is exercised from both sides: an ACCUMULATING loop
  (state retained across iterations rides a heap-typed parameter) is
  conservatively rejected — its retained list survives 1,000 messages
  intact, which it could not if an unsound reset ever fired — and a MIXED
  process proves the decision is per receive site, not per process: the
  same process first runs an unproven accumulating phase, then a proven
  flat phase whose resets still hold the heap flat.
  """

pub struct TestConcurrency.ArenaServerTest {
  use Zest.Case

  describe("proven flat server loop — the bounded-heap headline") {
    test("a flat Memory.Arena server's heap stays EXACTLY bounded across 10_000 messages") {
      server = Process.spawn(&TestConcurrency.ArenaServerTest.flat_server_entry/0, Memory.Arena)
      _channel = Process.send(Process.pid(u64, server), Process.self())

      # Warm up past the first-iteration watermark capture, then sample.
      _warm = TestConcurrency.ArenaServerTest.send_work(server, 100)
      _ask1 = Process.send(Process.pid(i64, server), 0)
      baseline = receive u64 {
        bytes -> bytes
      }

      # The storm: 10,000 messages, each allocating a fresh 50-element list
      # in the server's arena. Without the receive-back-edge reset this
      # grows the bulk set by megabytes (BULK_OR_NEVER frees only at
      # death); with it, every iteration reclaims to the watermark.
      _storm = TestConcurrency.ArenaServerTest.send_work(server, 10000)
      _ask2 = Process.send(Process.pid(i64, server), 0)
      after_storm = receive u64 {
        bytes -> bytes
      }

      _stop = Process.send(Process.pid(i64, server), -1)

      # The arena reserved SOMETHING (the accounting is live)…
      assert(baseline > 0)
      # …and 10,000 allocating iterations later it reserves EXACTLY the
      # same bytes — the watermark reset restores the chunk set every
      # iteration, so steady state is equality, not a fuzzy bound.
      assert(after_storm == baseline)
    }
  }

  describe("rejected accumulating loop — the soundness gate holds") {
    test("state retained across iterations survives 1_000 messages (no unsound reset)") {
      server = Process.spawn(&TestConcurrency.ArenaServerTest.acc_server_entry/0, Memory.Arena)
      _channel = Process.send(Process.pid(u64, server), Process.self())

      # 1,000 retained values. The accumulating loop's receive site is
      # conservatively REJECTED by the proof (its accumulator is a
      # heap-typed parameter live across the receive), so no reset fires —
      # a wrong reset here would free the live accumulator out from under
      # the loop (use-after-free), and the checksum below would be garbage.
      _fill = TestConcurrency.ArenaServerTest.send_work(server, 1000)
      _ask = Process.send(Process.pid(i64, server), 0)
      report = receive i64 {
        checksum -> checksum
      }
      _stop = Process.send(Process.pid(i64, server), -1)

      # length(1000) * 10_000_000 + sum(1..1000) = 10_000_000_000 + 500_500.
      assert(report == 10000500500)
    }
  }

  describe("the proof is per receive site, not per process") {
    test("one process: an unproven accumulating phase, then a proven flat phase with a bounded heap") {
      server = Process.spawn(&TestConcurrency.ArenaServerTest.mixed_entry/0, Memory.Arena)
      _channel = Process.send(Process.pid(u64, server), Process.self())

      # Phase 1 (accumulating helper loop — unproven receive): 200 values
      # collected across iterations, reported intact.
      _fill = TestConcurrency.ArenaServerTest.send_work(server, 200)
      _seal = Process.send(Process.pid(i64, server), 0)
      collected_checksum = receive i64 {
        checksum -> checksum
      }
      # length(200) * 10_000_000 + sum(1..200) = 2_000_000_000 + 20_100.
      assert(collected_checksum == 2000020100)

      # Phase 2 (flat loop in the SAME process — proven receive): heap
      # bytes hold exactly steady across 2,000 allocating messages.
      _warm = TestConcurrency.ArenaServerTest.send_work(server, 100)
      _ask1 = Process.send(Process.pid(i64, server), 0)
      flat_baseline = receive u64 {
        bytes -> bytes
      }
      _storm = TestConcurrency.ArenaServerTest.send_work(server, 2000)
      _ask2 = Process.send(Process.pid(i64, server), 0)
      flat_after = receive u64 {
        bytes -> bytes
      }
      _stop = Process.send(Process.pid(i64, server), -1)
      assert(flat_baseline > 0)
      assert(flat_after == flat_baseline)
    }
  }

  # -- the proven flat server -------------------------------------------------
  #
  # Entry protocol (all servers below): first message is the parent's raw pid
  # bits (the reply channel); then i64 work messages — n >= 1 does
  # per-message heap work, 0 reports (heap bytes on the u64 channel;
  # checksums on the i64 channel), -1 exits.

  pub fn flat_server_entry() -> Nil {
    parent = Process.receive_raw(u64)
    TestConcurrency.ArenaServerTest.flat_loop(parent)
  }

  # The loop-closed shape the compiler proves: scalar-only state across the
  # receive (the parent's raw pid bits), fresh per-message allocations that
  # die before the back-edge, and a self tail call returning to the receive.
  pub fn flat_loop(parent :: u64) -> Nil {
    n = receive i64 {
      value -> value
    }
    case n {
      -1 -> nil
      0 ->
        {
          # Do one iteration's worth of heap work BEFORE reading, so the
          # report observes live chunk accounting (the auto-reset at this
          # iteration's receive freed everything back to the pre-first-
          # receive watermark — which is EMPTY for these servers, so a
          # read without work would report 0 and prove nothing about the
          # STAT accounting being alive).
          _work = TestConcurrency.ArenaServerTest.build_and_sum(1, 50)
          _reported = Process.send(Process.pid(u64, parent), Process.heap_bytes())
          TestConcurrency.ArenaServerTest.flat_loop(parent)
        }
      work ->
        {
          # Fresh per-iteration heap: a 50-element list built, summed, and
          # dead before the loop returns to the receive.
          total = TestConcurrency.ArenaServerTest.build_and_sum(work, 50)
          _consumed = TestConcurrency.ArenaServerTest.observe(total)
          TestConcurrency.ArenaServerTest.flat_loop(parent)
        }
    }
  }

  # -- the rejected accumulating server ----------------------------------------

  pub fn acc_server_entry() -> Nil {
    parent = Process.receive_raw(u64)
    TestConcurrency.ArenaServerTest.acc_loop(parent, [])
  }

  # State accumulates across iterations through the heap-typed `acc`
  # parameter — live across every receive, so the proof REJECTS this loop
  # and no reset is ever emitted for it.
  pub fn acc_loop(parent :: u64, acc :: List(i64)) -> Nil {
    n = receive i64 {
      value -> value
    }
    case n {
      -1 -> nil
      0 ->
        {
          checksum = List.length(acc) * 10000000 + TestConcurrency.ArenaServerTest.sum_list(acc, List.length(acc), 0)
          _reported = Process.send(Process.pid(i64, parent), checksum)
          TestConcurrency.ArenaServerTest.acc_loop(parent, acc)
        }
      work -> TestConcurrency.ArenaServerTest.acc_loop(parent, List.push(acc, work))
    }
  }

  # -- the mixed per-loop process ----------------------------------------------

  pub fn mixed_entry() -> Nil {
    parent = Process.receive_raw(u64)
    # Phase 1: an UNPROVEN receive loop (heap-typed accumulator) in a helper.
    # The retained list lives entirely inside `collect_phase`'s frames (only
    # the scalar checksum flows back), so THIS frame stays heap-free at the
    # phase-2 call below — a heap value held here across that call would
    # (correctly, conservatively) disqualify the shared flat loop for every
    # caller, since the proof is per function, not per activation.
    checksum = TestConcurrency.ArenaServerTest.collect_phase([])
    _reported = Process.send(Process.pid(i64, parent), checksum)
    # Phase 2: the PROVEN flat loop, in the same process.
    TestConcurrency.ArenaServerTest.flat_loop(parent)
  }

  # Collect until the 0 sentinel, retaining every value across iterations
  # (the heap-typed accumulator parameter is live across the receive, so
  # this loop is conservatively rejected — the unproven phase-1 receive),
  # then reduce the retained state to its scalar checksum.
  pub fn collect_phase(acc :: List(i64)) -> i64 {
    n = receive i64 {
      value -> value
    }
    case n {
      0 -> List.length(acc) * 10000000 + TestConcurrency.ArenaServerTest.sum_list(acc, List.length(acc), 0)
      other -> TestConcurrency.ArenaServerTest.collect_phase(List.push(acc, other))
    }
  }

  # -- shared helpers -----------------------------------------------------------

  # Send `count` work messages (1..count) to `server`.
  pub fn send_work(server :: u64, count :: i64) -> Bool {
    TestConcurrency.ArenaServerTest.send_work_from(server, 1, count)
  }

  fn send_work_from(server :: u64, next :: i64, remaining :: i64) -> Bool {
    case remaining == 0 {
      true -> true
      false ->
        {
          _sent = Process.send(Process.pid(i64, server), next)
          TestConcurrency.ArenaServerTest.send_work_from(server, next + 1, remaining - 1)
        }
    }
  }

  # Build a `length`-element list seeded from `seed` and sum it — the
  # per-message heap work whose allocations must die by the back-edge.
  pub fn build_and_sum(seed :: i64, length :: i64) -> i64 {
    items = TestConcurrency.ArenaServerTest.build_list(seed, length, [])
    TestConcurrency.ArenaServerTest.sum_list(items, List.length(items), 0)
  }

  fn build_list(seed :: i64, remaining :: i64, acc :: List(i64)) -> List(i64) {
    case remaining == 0 {
      true -> acc
      false -> TestConcurrency.ArenaServerTest.build_list(seed + 1, remaining - 1, List.push(acc, seed))
    }
  }

  pub fn sum_list(items :: List(i64), index :: i64, acc :: i64) -> i64 {
    case index == 0 {
      true -> acc
      false -> TestConcurrency.ArenaServerTest.sum_list(items, index - 1, acc + List.get(items, index - 1))
    }
  }

  # Keep the flat loop's per-message result observably consumed without
  # retaining anything across the back-edge.
  fn observe(total :: i64) -> Bool {
    total >= 0
  }
}
