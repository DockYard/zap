@doc = """
  Plan item 2.7 concurrency SCENARIO suite: the four language-surface
  scenarios the plan names — ping-pong, pairwise-FIFO ordering,
  crash-teardown, and timeout semantics — exercised end-to-end through
  the pure-Zap `Process` API (`lib/process.zap`) and the `receive`/`after`
  construct, over the real gated-on concurrency kernel.

  Where the primitive tests in this directory (`process_test`,
  `receive_test`, `message_union_test`, `rich_message_test`) pin each
  primitive's mechanics, this file layers the plan-2.7 SCENARIOS on top:
  multi-round exchanges, multi-sender interleaving, and repeated
  spawn/teardown cycles — the shapes a real program builds from the
  primitives.

  ## Reproducibility (decision 11)

  These tests are REPRODUCIBLE by two mechanisms, neither of which is the
  seeded scheduler:

  1. The Phase-2 runtime runs ONE cooperative scheduler on ONE driver
     thread (the root process is `main`; spawned processes are fibers on
     that same thread — see `lib/process.zap`). There are no producer
     threads and no shared-memory races, so a run's interleaving is a
     PURE FUNCTION of the program: every run of a given test produces the
     identical result. The tests are single-threaded-deterministic BY
     CONSTRUCTION.
  2. The Zest runner prints its shuffle `Seed:` and replays it with
     `--seed`. Because the runtime is deterministic by construction, that
     one seed fixes the WHOLE run (test order plus every process
     interleaving), so a failing run is reproduced exactly by re-running
     with the printed seed — the decision-11 "failing test prints its
     seed" contract, satisfied at the layer that owns test execution.

  The SEEDED deterministic scheduler (decision 11's seed-sweep half —
  random next-runnable choice, randomized per-quantum budgets,
  byte-identical trace comparison, verona-rt seed sweeps, and the
  failing-seed print of `runScenario`) drives the kernel scenarios in
  `src/runtime/concurrency/deterministic.zig`, which sweep the
  STRUCTURALLY-IDENTICAL shapes to this file (ping-pong across 6
  processes, pairwise FIFO across 4 producers under a 50-seed sweep,
  killed-waiter crash-teardown under a 40-seed sweep). That is the right
  home for interleaving exploration: the interleaving-dependent behavior
  lives in the kernel, and the Zap surface above it is thin,
  interleaving-INVARIANT wrappers whose SEMANTICS this suite validates.
  Running the whole gate-on Zest binary under the seeded scheduler is a
  tracked follow-up (it needs scheduler-relative process intrinsics that
  do not exist in Phase 2, and it would contradict sibling tests that
  assert a specific PRODUCTION interleaving, e.g. `safepoint_test`'s
  preemption ordering) — see this job's report.

  ## Timeout semantics

  `after T` firing and `after 0` polling are covered here (empty-mailbox
  cases) and, for the message-beats-deadline case, in `receive_test`.
  Under the single scheduler a timeout's OUTCOME is deterministic: with
  no other runnable process and no pending message, the `after` arm is
  the only way forward, so it fires.
  """

pub struct TestConcurrency.ConcurrencyScenariosTest {
  use Zest.Case

  describe("ping-pong across multiple rounds") {
    test("a two-process exchange increments a value across four rounds") {
      ponger = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.incrementing_ponger_entry/0))
      _channel = Process.send(ponger, Process.self())
      typed_ponger = Process.pid(i64, ponger.raw)
      # Send 10; the ponger replies 11; carry 11 forward; ... four rounds:
      # 10 -> 11 -> 12 -> 13 -> 14.
      final_value = ping_exchange(typed_ponger, 4, 10)
      assert(final_value == 14)
    }
  }

  describe("pairwise FIFO ordering") {
    test("a six-message sequence from one sender arrives in send order") {
      sender = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.ordered_sequence_sender_entry/0))
      _channel = Process.send(sender, Process.self())
      # The sender pushes 0,1,2,3,4,5 in order. FIFO delivery means we
      # receive them in exactly that order; the helper returns false the
      # moment any value arrives out of sequence.
      assert(receive_ascending_ok(0, 6))
    }

    test("two interleaved senders each preserve their own send order") {
      parent_bits = Process.self()
      # Sender A tags its messages 100..104, sender B tags them 200..204.
      # However the scheduler interleaves the two streams, EACH sender's
      # own subsequence must arrive monotonically (pairwise FIFO).
      sender_a = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.tagged_sequence_sender_entry/0))
      _channel_a = Process.send(sender_a, parent_bits)
      _base_a = Process.send(Process.pid(i64, sender_a.raw), 100)
      sender_b = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.tagged_sequence_sender_entry/0))
      _channel_b = Process.send(sender_b, parent_bits)
      _base_b = Process.send(Process.pid(i64, sender_b.raw), 200)
      # Drain all ten; last-seen starts one below each base so the first
      # of each stream must be the base value itself.
      assert(drain_pairwise_fifo_ok(10, 99, 199))
    }
  }

  describe("crash-teardown (observable accounting; links are Phase 5)") {
    test("a send to an exited child's pid dead-letters — teardown recycled the slot") {
      exiting_child = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.ack_then_exit_entry/0))
      _channel = Process.send(exiting_child, Process.self())
      acknowledgement = Process.receive_raw(i64)
      assert(acknowledgement == 1)
      # The child sent its ack and then called Process.exit() within the
      # same quantum (a send does not preempt the sender), so it is fully
      # torn down before this process resumes: its pid generation is
      # bumped and a send to the now-stale bits dead-letters (returns
      # false) rather than reaching a recycled process.
      delivered = Process.send(Process.pid(i64, exiting_child.raw), 99)
      reject(delivered)
    }

    test("many spawn-then-exit cycles reclaim resources — a fresh round-trip still works") {
      # Fifty children are each spawned, answered, and exited in turn.
      # Receiving every acknowledgement proves none were lost; that the
      # runtime keeps servicing spawns proves each exit reclaimed its pid
      # slot, stack, and envelopes for reuse (a leak would wedge or
      # exhaust the runtime). Exhaustive leak accounting is the kernel
      # teardown-stress campaign; this asserts the language-surface path.
      completed_cycles = run_exit_cycles(50, 0)
      assert(completed_cycles == 50)
      # A brand-new child round-trips after all the teardown churn.
      echo_child = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.increment_once_entry/0))
      _echo_channel = Process.send(echo_child, Process.self())
      _ping = Process.send(Process.pid(i64, echo_child.raw), 41)
      final_echo = Process.receive_raw(i64)
      assert(final_echo == 42)
    }
  }

  describe("timeout semantics") {
    test("after T fires when the mailbox stays empty") {
      # No process ever sends here, so the timeout arm is the only way
      # forward and fires deterministically.
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
  }

  # -- pinger side (runs in the test/root process) ---------------------------

  # Sends `carried`, waits for the ponger's incremented reply, and carries
  # that reply into the next round; after `remaining` rounds returns the
  # last value received. The base clause stops the recursion.
  fn ping_exchange(_ponger :: Pid(i64), 0 :: i64, carried :: i64) -> i64 {
    carried
  }

  fn ping_exchange(ponger :: Pid(i64), remaining :: i64, carried :: i64) -> i64 {
    _sent = Process.send(ponger, carried)
    echoed = Process.receive_raw(i64)
    ping_exchange(ponger, remaining - 1, echoed)
  }

  # -- single-sender FIFO receiver (runs in the root process) ----------------

  # Receives `remaining` values and asserts each equals the running
  # `expected` counter; returns false at the first out-of-order value.
  fn receive_ascending_ok(_expected :: i64, 0 :: i64) -> Bool {
    true
  }

  fn receive_ascending_ok(expected :: i64, remaining :: i64) -> Bool {
    received = Process.receive_raw(i64)
    case received == expected {
      true -> receive_ascending_ok(expected + 1, remaining - 1)
      false -> false
    }
  }

  # -- two-sender pairwise-FIFO receiver (runs in the root process) ----------

  # Drains `remaining` tagged values, tracking the last value seen for
  # each stream (tags < 200 are stream A, otherwise stream B). Every
  # value must be exactly one past its stream's previous value, so each
  # sender's own order is preserved regardless of how the two interleave.
  fn drain_pairwise_fifo_ok(0 :: i64, _last_a :: i64, _last_b :: i64) -> Bool {
    true
  }

  fn drain_pairwise_fifo_ok(remaining :: i64, last_a :: i64, last_b :: i64) -> Bool {
    tag = Process.receive_raw(i64)
    case tag < 200 {
      true ->
        case tag == last_a + 1 {
          true -> drain_pairwise_fifo_ok(remaining - 1, tag, last_b)
          false -> false
        }
      false ->
        case tag == last_b + 1 {
          true -> drain_pairwise_fifo_ok(remaining - 1, last_a, tag)
          false -> false
        }
    }
  }

  # -- repeated spawn/exit driver (runs in the root process) -----------------

  # Spawns one acknowledging-then-exiting child per cycle, waits for its
  # ack, and tallies the acks. Returns the accumulated count so the test
  # can assert every cycle completed.
  fn run_exit_cycles(0 :: i64, accumulated :: i64) -> i64 {
    accumulated
  }

  fn run_exit_cycles(remaining :: i64, accumulated :: i64) -> i64 {
    child = Process.pid(u64, Process.spawn(&TestConcurrency.ConcurrencyScenariosTest.ack_then_exit_entry/0))
    _channel = Process.send(child, Process.self())
    acknowledgement = Process.receive_raw(i64)
    run_exit_cycles(remaining - 1, accumulated + acknowledgement)
  }

  # -- child process entries (each first receives the parent's raw pid
  # -- bits as its reply channel) --------------------------------------------

  # Receives four values, replying to each with value + 1, then exits by
  # returning — the ponger half of the multi-round ping-pong.
  pub fn incrementing_ponger_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    pong_rounds(parent, 4)
  }

  fn pong_rounds(parent :: Pid(i64), remaining :: i64) -> Nil {
    case remaining {
      0 -> nil
      _ ->
        {
          value = Process.receive_raw(i64)
          _sent = Process.send(parent, value + 1)
          pong_rounds(parent, remaining - 1)
        }
    }
  }

  # Sends the ascending sequence 0,1,2,3,4,5 to its reply channel.
  pub fn ordered_sequence_sender_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    send_ascending(parent, 0, 6)
  }

  fn send_ascending(parent :: Pid(i64), next :: i64, remaining :: i64) -> Nil {
    case remaining {
      0 -> nil
      _ ->
        {
          _sent = Process.send(parent, next)
          send_ascending(parent, next + 1, remaining - 1)
        }
    }
  }

  # Receives its reply channel and a tag base, then sends five messages
  # tagged base, base+1, ..., base+4 — a monotonic per-sender stream.
  pub fn tagged_sequence_sender_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    tag_base = Process.receive_raw(i64)
    send_tagged(parent, tag_base, 0, 5)
  }

  fn send_tagged(parent :: Pid(i64), tag_base :: i64, sequence :: i64, remaining :: i64) -> Nil {
    case remaining {
      0 -> nil
      _ ->
        {
          _sent = Process.send(parent, tag_base + sequence)
          send_tagged(parent, tag_base, sequence + 1, remaining - 1)
        }
    }
  }

  # Replies with 1, then exits explicitly through the teardown path.
  pub fn ack_then_exit_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 1)
    Process.exit()
  }

  # Replies once with value + 1, then exits by returning.
  pub fn increment_once_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    value = Process.receive_raw(i64)
    _sent = Process.send(parent, value + 1)
    nil
  }
}
