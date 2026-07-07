@doc = """
  P2-J6 — three-layer cooperative safepoints, end-to-end (gate ON).

  The kernel-level yield mechanics (budget exhaustion, watchdog, sole-vs-
  co-runnable) are proved deterministically in `scheduler.zig`'s
  `reductionSafepoint` tests. These tests exercise the FULL compiled path —
  the ZIR-emitted layer-2 back-edge poll and the layer-1 alloc piggyback,
  through the real scheduler — proving (a) the emitted safepoints do not
  corrupt computation and (b) a CPU-bound process actually yields so a
  co-runnable process makes progress.

  The preemption tests observe ordering: a co-runnable "quick" process's
  reply (marker 2) must reach the parent BEFORE a "slow" CPU-bound
  process's reply (marker 1). Under production FIFO with cooperative
  yielding the slow process yields at its safepoints, so the quick process
  replies first. Were the safepoints absent, the slow process would run to
  completion first and its marker would arrive first — so the assertion
  distinguishes working preemption from broken preemption.
  """

pub struct TestConcurrency.SafepointTest {
  use Zest.Case

  describe("layer 2 — bare back-edge poll (alloc-free loops)") {
    test("an alloc-free tail-recursive loop computes correctly under back-edge polls") {
      # `sum_loop` loopifies and is alloc-free, so it carries the emitted
      # layer-2 counter decrement at its back-edge. The result must be
      # bit-exact: 1 + 2 + ... + 100000 = 5000050000.
      total = TestConcurrency.SafepointTest.sum_loop(0, 100000)
      assert(total == 5000050000)
    }

    test("a pure CPU-bound process is preempted so a co-runnable process replies first") {
      slow = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.slow_pure_reply_entry/0))
      quick = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.quick_reply_entry/0))
      _slow_channel = Process.send(slow, Process.self())
      _quick_channel = Process.send(quick, Process.self())
      first = Process.receive_raw(i64)
      second = Process.receive_raw(i64)
      # marker 2 (quick) arrives before marker 1 (slow) — the CPU-bound
      # process yielded at its layer-2 back-edge polls.
      assert(first == 2)
      assert(second == 1)
    }
  }

  describe("layer 1 — alloc piggyback (allocating loops)") {
    test("an allocating loop builds correctly under the alloc piggyback") {
      # `build_list` conses one cell per iteration (an allocation), so it is
      # covered by the layer-1 piggyback rather than a back-edge poll. The
      # list must be built intact.
      built = TestConcurrency.SafepointTest.build_list([], 5000)
      assert(List.length(built) == 5000)
    }

    test("an allocating CPU-bound process is preempted so a co-runnable process replies first") {
      slow = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.slow_alloc_reply_entry/0))
      quick = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.quick_reply_entry/0))
      _slow_channel = Process.send(slow, Process.self())
      _quick_channel = Process.send(quick, Process.self())
      first = Process.receive_raw(i64)
      second = Process.receive_raw(i64)
      # marker 2 (quick) arrives before marker 1 (slow) — the allocating
      # process yielded at its layer-1 alloc-piggyback safepoints.
      assert(first == 2)
      assert(second == 1)
    }
  }

  # -- helper loops -----------------------------------------------------------

  @doc = """
    Alloc-free tail-recursive accumulate. Loopifies; its iterating path is
    allocation-free, so the ZIR builder emits a layer-2 back-edge poll here.
    """

  pub fn sum_loop(acc :: i64, 0 :: i64) -> i64 {
    acc
  }

  pub fn sum_loop(acc :: i64, n :: i64) -> i64 {
    TestConcurrency.SafepointTest.sum_loop(acc + n, n - 1)
  }

  @doc = """
    Allocating tail-recursive list build. Each `[n | acc]` conses a cell
    through the manager, so this loop is covered by the layer-1 alloc
    piggyback (and excluded from the layer-2 back-edge poll).
    """

  pub fn build_list(acc :: [i64], 0 :: i64) -> [i64] {
    acc
  }

  pub fn build_list(acc :: [i64], n :: i64) -> [i64] {
    TestConcurrency.SafepointTest.build_list([n | acc], n - 1)
  }

  # -- child process entries (each first receives the parent's raw pid) -------

  @doc = """
    Replies immediately with marker 2. Co-runnable with a CPU-bound process,
    it runs and replies during that process's yields.
    """

  pub fn quick_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 2)
    nil
  }

  @doc = """
    Runs a long alloc-free loop (>> the reduction budget) THEN replies with
    marker 1. Reaches its reply only after yielding many times at its
    layer-2 back-edge polls.
    """

  pub fn slow_pure_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _computed = TestConcurrency.SafepointTest.sum_loop(0, 300000)
    _sent = Process.send(parent, 1)
    nil
  }

  @doc = """
    Runs a long allocating loop (>> the reduction budget) THEN replies with
    marker 1. Reaches its reply only after yielding many times at its
    layer-1 alloc-piggyback safepoints.
    """

  pub fn slow_alloc_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _built = TestConcurrency.SafepointTest.build_list([], 60000)
    _sent = Process.send(parent, 1)
    nil
  }
}
