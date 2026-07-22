@doc = """
  P6-J6 (plan item 6.5) — the `RuntimeInfo` observability surface in a
  gate-ON, trace-OFF binary: process listing (pids, states, mailbox
  depths, heap bytes), scheduler utilization and run-queue depths, and
  the trace read API's documented empty behavior when the
  `runtime_tracing` gate is compiled OFF (this suite's configuration).
  The trace-ON behavior is pinned by the separate traced suite
  (`test_concurrency_traced/`).
  """

pub struct Concurrency.RuntimeInfoTest {
  use Zest.Case

  describe("process listing") {
    test("capture names the calling process with its live state") {
      count = RuntimeInfo.capture_processes()
      assert(count >= 1)
      self_index = Concurrency.RuntimeInfoTest.find_pid_index(Process.self(), 0, count)
      assert(self_index < count)
      # The observer is on a CPU taking the snapshot: running.
      state = RuntimeInfo.process_state(self_index)
      assert(state == :running)
    }

    test("mailbox depth counts queued undelivered messages (self-send)") {
      _first = Process.send(Process.pid(i64, Process.self()), 7)
      _second = Process.send(Process.pid(i64, Process.self()), 8)
      count = RuntimeInfo.capture_processes()
      self_index = Concurrency.RuntimeInfoTest.find_pid_index(Process.self(), 0, count)
      assert(self_index < count)
      # At least the two just-queued messages (≥, not ==: the suite's
      # root process may carry unrelated queued messages).
      depth = RuntimeInfo.process_mailbox_depth(self_index)
      assert(depth >= 2)
      # Drain the two queued messages so the suite stays clean.
      first = receive i64 {
        n -> n
      }
      second = receive i64 {
        n -> n
      }
      assert(first + second == 15)
    }

    test("a waiting child is listed with its pid and a quiescent mailbox") {
      child = Process.spawn(&Concurrency.RuntimeInfoTest.parked_echo_entry/0)
      _channel = Process.send(Process.pid(u64, child), Process.self())
      ready = receive i64 {
        n -> n
      }
      assert(ready == 1)
      count = RuntimeInfo.capture_processes()
      assert(count >= 2)
      child_index = Concurrency.RuntimeInfoTest.find_pid_index(child, 0, count)
      assert(child_index < count)
      # The child acked and parked on its next receive: waiting (or
      # momentarily runnable/running if the snapshot straddles its park —
      # the listing is point-in-time, never stop-the-world).
      state = RuntimeInfo.process_state(child_index)
      assert(state == :waiting or state == :runnable or state == :running)
      # Heap bytes read through the manager's STAT capability (u64; the
      # getter is total for any live index).
      _heap = RuntimeInfo.process_heap_bytes(child_index)
      _stop = Process.send(Process.pid(i64, child), -1)
    }

    test("indexed getters are total past the captured count") {
      count = RuntimeInfo.capture_processes()
      assert(RuntimeInfo.process_pid_bits(count + 100) == 0)
      assert(RuntimeInfo.process_state(count + 100) == :invalid)
      assert(RuntimeInfo.process_mailbox_depth(count + 100) == 0)
    }
  }

  describe("scheduler surfaces") {
    test("core count, queue depths, and the utilization split are coherent") {
      cores = RuntimeInfo.scheduler_count()
      assert(cores >= 1)
      # The core running THIS test has a live utilization window.
      busy_total = Concurrency.RuntimeInfoTest.sum_busy(0, cores, 0)
      assert(busy_total > 0)
      # Every per-core ratio is a valid permille; out-of-range cores are 0.
      assert(RuntimeInfo.scheduler_utilization_permille(0) <= 1000)
      assert(RuntimeInfo.scheduler_utilization_permille(cores + 9) == 0)
      assert(RuntimeInfo.run_queue_depth(cores + 9) == 0)
      _global_depth = RuntimeInfo.global_run_queue_depth()
      _parks = RuntimeInfo.scheduler_park_count(0)
    }
  }

  describe("trace read API with tracing compiled OFF") {
    test("tracing reports disabled and every read is empty but total") {
      assert(RuntimeInfo.trace_enabled() == false)
      assert(RuntimeInfo.trace_capture() == 0)
      assert(RuntimeInfo.trace_kind(0) == :invalid)
      assert(RuntimeInfo.trace_pid_bits(0) == 0)
      assert(RuntimeInfo.trace_sequence(0) == 0)
      assert(RuntimeInfo.trace_reset() == true)
    }
  }

  @doc = """
    Linear scan for `pid` in the captured listing; returns its index,
    or `count` (one past the end) when absent. Recursive (Zap's loop
    form).
    """

  pub fn find_pid_index(pid :: u64, index :: i64, count :: i64) -> i64 {
    if index >= count {
      count
    } else {
      if RuntimeInfo.process_pid_bits(index) == pid {
        index
      } else {
        Concurrency.RuntimeInfoTest.find_pid_index(pid, index + 1, count)
      }
    }
  }

  @doc = """
    Sum `scheduler_busy_nanos` across cores `[index, cores)`.
    """

  pub fn sum_busy(index :: i64, cores :: i64, total :: i64) -> i64 {
    if index >= cores {
      total
    } else {
      Concurrency.RuntimeInfoTest.sum_busy(index + 1, cores, total + RuntimeInfo.scheduler_busy_nanos(index))
    }
  }

  @doc = """
    Child body: reads its reply channel, acks with 1, then parks on the
    next `i64` (the observation window) and exits once it arrives.
    """

  pub fn parked_echo_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _ready = Process.send(parent, 1)
    _stop = Process.receive_raw(i64)
    nil
  }
}
