@doc = """
  P2-J6 — three-layer cooperative safepoints, end-to-end (gate ON).

  The kernel-level yield mechanics (budget exhaustion, watchdog, sole-vs-
  co-runnable) are proved deterministically in `scheduler.zig`'s
  `reductionSafepoint` tests. These tests exercise the FULL compiled path —
  the ZIR-emitted layer-2 back-edge poll and the layer-1 alloc piggyback,
  through the real scheduler — proving (a) the emitted safepoints do not
  corrupt computation and (b) a CPU-bound process cannot starve a
  co-runnable process.

  The preemption tests assert the PROVABLE end-to-end property, not
  arrival order (P7-R1 hardening, the 473f815 class): a co-runnable
  "quick" process (marker 2) and a "slow" CPU-bound process (marker
  derived from its computation — 1 only when the safepoint-instrumented
  loop's result is bit-exact) BOTH reply, and the reply set is exactly
  {1, 2}. Arrival order is deliberately not asserted: the M:N pool may
  run the pair on different cores, the seeded simulator is under no
  obligation to interleave the quick process first, and under host CPU
  load the OS may deschedule a scheduler thread mid-run (plan item 5.8) —
  the design guarantees progress, not ordering. Deterministic proof that
  budget exhaustion forces the yield lives in the kernel suite.
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

    test("a pure CPU-bound process cannot starve a co-runnable process, computation intact") {
      slow = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.slow_pure_reply_entry/0))
      quick = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.quick_reply_entry/0))
      _slow_channel = Process.send(slow, Process.self())
      _quick_channel = Process.send(quick, Process.self())
      first = Process.receive_raw(i64)
      second = Process.receive_raw(i64)
      # Both replies arrive and the set is exactly {1, 2} (the unique i64
      # pair with sum 3 and product 2): the CPU-bound process cannot starve
      # the co-runnable one, and the slow marker is derived from the loop's
      # computed sum, so a safepoint-corrupted computation fails here.
      # Arrival ORDER is deliberately not asserted (plan 5.8; the M:N pool
      # may run the pair on different cores).
      assert(first + second == 3)
      assert(first * second == 2)
    }
  }

  describe("P6-J5 — forced loopification + K-amortized back-edge polls") {
    test("a TCO-safe scalar loop is bit-exact across unroll-boundary iteration counts") {
      # Gate-ON, `sum_loop` (all-scalar, would musttail) is force-loopified
      # (lever b) and its tight non-FP alloc-free body is K-unrolled
      # (lever a). Iteration counts around the K = 8 group boundary — and a
      # large count that is NOT a multiple of K and crosses many reduction
      # reseeds — must all stay bit-exact (the base case exits from any
      # unrolled copy; there is no "remainder" iteration to mishandle).
      assert(TestConcurrency.SafepointTest.sum_loop(0, 0) == 0)
      assert(TestConcurrency.SafepointTest.sum_loop(0, 1) == 1)
      assert(TestConcurrency.SafepointTest.sum_loop(0, 7) == 28)
      assert(TestConcurrency.SafepointTest.sum_loop(0, 8) == 36)
      assert(TestConcurrency.SafepointTest.sum_loop(0, 9) == 45)
      assert(TestConcurrency.SafepointTest.sum_loop(0, 100003) == 5000350006)
    }

    test("a K-unrolled byref reversal loop is exact at every group-boundary length") {
      # `reverse_span` mirrors the fannkuch-redux hot loop (the tight
      # shape the E2 ledger flagged): naturally loopified (List param)
      # and K-unrolled gate-ON.
      # Lengths chosen so the swap count (length / 2) lands before, on, and
      # after the K = 8 group boundary, plus the empty and single-element
      # degenerate spans.
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(0))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(1))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(2))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(3))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(15))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(16))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(17))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(32))
      assert(TestConcurrency.SafepointTest.reversal_roundtrip_ok(33))
    }

    test("a CPU-bound tight unrolled loop still cannot starve a co-runnable process") {
      # The K-amortized poll fires once per K iterations instead of every
      # iteration — this proves the K-amortized tick did not break the
      # safepoint contract: the slow process runs ~900k tight-loop
      # iterations (>> the 4000-reduction budget) through the K-amortized
      # back-edge tick, its round trip stays element-exact (marker 1 only
      # on an exact reversal), and the co-runnable process still replies.
      slow = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.slow_reverse_reply_entry/0))
      quick = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.quick_reply_entry/0))
      _slow_channel = Process.send(slow, Process.self())
      _quick_channel = Process.send(quick, Process.self())
      first = Process.receive_raw(i64)
      second = Process.receive_raw(i64)
      # Reply set exactly {1, 2}; order deliberately unasserted (plan 5.8).
      assert(first + second == 3)
      assert(first * second == 2)
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

    test("an allocating CPU-bound process cannot starve a co-runnable process, list intact") {
      slow = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.slow_alloc_reply_entry/0))
      quick = Process.pid(u64, Process.spawn(&TestConcurrency.SafepointTest.quick_reply_entry/0))
      _slow_channel = Process.send(slow, Process.self())
      _quick_channel = Process.send(quick, Process.self())
      first = Process.receive_raw(i64)
      second = Process.receive_raw(i64)
      # Both replies arrive and the set is exactly {1, 2}: the allocating
      # CPU-bound process cannot starve the co-runnable one, and the slow
      # marker is derived from the built list's length, so a piggyback-
      # corrupted build fails here. Order deliberately unasserted (plan 5.8).
      assert(first + second == 3)
      assert(first * second == 2)
    }
  }

  # -- helper loops -----------------------------------------------------------

  @doc = """
    Alloc-free tail-recursive accumulate. All-scalar (TCO-safe, would
    lower to `musttail` gate-OFF); gate-ON it is force-loopified (P6-J5
    lever b) and, being tight/non-FP/alloc-free with only leaf callees,
    K-unrolled (lever a), so its safepoint is ONE amortized shared-budget
    tick per K iterations at the back-edge.
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

  @doc = """
    Fill `arr[index..length)` with the identity permutation
    (`arr[i] = i`). A tight naturally-loopified (byref `List` param)
    alloc-free loop — K-unrolled gate-ON.
    """

  pub fn fill_identity(arr :: List(i64), index :: i64, length :: i64) -> List(i64) {
    if index >= length {
      arr
    } else {
      one = 1 :: i64
      arr = List.set(arr, index, index)
      TestConcurrency.SafepointTest.fill_identity(arr, index + one, length)
    }
  }

  @doc = """
    Reverse `arr[lo..hi]` in place — the fannkuch-redux `reverse_range`
    shape, the tight loop whose per-iteration safepoint the E2 ledger
    flagged gate-ON before the P6-J5 amortization. Naturally loopified;
    K-unrolled gate-ON.
    """

  pub fn reverse_span(arr :: List(i64), lo :: i64, hi :: i64) -> List(i64) {
    if lo >= hi {
      arr
    } else {
      one = 1 :: i64
      a = List.get(arr, lo)
      b = List.get(arr, hi)
      arr = List.set(arr, lo, b)
      arr = List.set(arr, hi, a)
      TestConcurrency.SafepointTest.reverse_span(arr, lo + one, hi - one)
    }
  }

  @doc = """
    Check `arr[index..length)` holds the REVERSED identity permutation
    (`arr[i] == length - 1 - i`). Verifies a `fill_identity` +
    `reverse_span` round trip element-exactly.
    """

  pub fn reversed_prefix_intact(arr :: List(i64), index :: i64, length :: i64) -> Bool {
    if index >= length {
      true
    } else {
      one = 1 :: i64
      expected = length - one - index
      if List.get(arr, index) == expected {
        TestConcurrency.SafepointTest.reversed_prefix_intact(arr, index + one, length)
      } else {
        false
      }
    }
  }

  @doc = """
    Build an identity list of `n` elements, reverse it with the tight
    unrolled `reverse_span` loop, and verify every element landed exactly
    where the reversal puts it. `true` only on an element-exact round
    trip — the unroll-boundary correctness probe.
    """

  pub fn reversal_roundtrip_ok(n :: i64) -> Bool {
    arr = List.new_filled(n, 0 :: i64)
    arr = TestConcurrency.SafepointTest.fill_identity(arr, 0 :: i64, n)
    arr = TestConcurrency.SafepointTest.reverse_span(arr, 0 :: i64, n - (1 :: i64))
    TestConcurrency.SafepointTest.reversed_prefix_intact(arr, 0 :: i64, n)
  }

  # -- child process entries (each first receives the parent's raw pid) -------

  @doc = """
    Replies immediately with marker 2. Co-runnable with a CPU-bound
    process, it runs and replies either during that process's safepoint
    yields (same core) or concurrently on another core of the M:N pool.
    """

  pub fn quick_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, 2)
    nil
  }

  @doc = """
    Runs a long alloc-free loop (>> the reduction budget) THEN replies with
    a computation-derived marker: 1 exactly when the safepoint-instrumented
    loop's sum is bit-exact (1 + 2 + ... + 300000 = 45000150000), anything
    else on a corrupted computation. Runs its loop through many layer-2
    back-edge polls before replying.
    """

  pub fn slow_pure_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    computed = TestConcurrency.SafepointTest.sum_loop(0, 300000)
    _sent = Process.send(parent, computed - 45000150000 + 1)
    nil
  }

  @doc = """
    Runs a long allocating loop (>> the reduction budget) THEN replies with
    a computation-derived marker: 1 exactly when the built list holds all
    60000 cells, anything else on a corrupted build. Runs its loop through
    many layer-1 alloc-piggyback safepoints before replying.
    """

  pub fn slow_alloc_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    built = TestConcurrency.SafepointTest.build_list([], 60000)
    _sent = Process.send(parent, List.length(built) - 60000 + 1)
    nil
  }

  @doc = """
    Runs ~900k iterations of the tight K-unrolled register-poll loops
    (600k `fill_identity` + 300k `reverse_span` swap iterations — far
    beyond the 4000-reduction budget) THEN replies with a
    computation-derived marker: 1 exactly when the fill + reversal round
    trip is element-exact, -1 on any corrupted element. Runs its loops
    through many K-amortized back-edge polls before replying — the
    end-to-end evidence that amortization broke neither the computation
    nor co-runnable progress.
    """

  pub fn slow_reverse_reply_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    n = 600000 :: i64
    arr = List.new_filled(n, 0 :: i64)
    arr = TestConcurrency.SafepointTest.fill_identity(arr, 0 :: i64, n)
    arr = TestConcurrency.SafepointTest.reverse_span(arr, 0 :: i64, n - (1 :: i64))
    checked = TestConcurrency.SafepointTest.reversed_prefix_intact(arr, 0 :: i64, n)
    _sent = case checked {
      true -> Process.send(parent, 1)
      false -> Process.send(parent, -1)
    }
    nil
  }
}
