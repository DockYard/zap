@doc = """
  P6-J6 (plan item 6.5) — the message-flow trace ring in a gate-ON,
  TRACE-ON binary (`runtime_tracing: true`, this suite's manifest): the
  ring records the spawn → send → receive → exit lifecycle IN ORDER
  with correct pids, `trace_enabled()` reports the compiled-in gate, and
  reset restarts the window. The trace-OFF behavior (empty, total reads)
  is pinned by the main gate suite (`test_concurrency/runtime_info_test.zap`).
  """

pub struct TestConcurrencyTraced.TraceTest {
  use Zest.Case

  describe("message-flow trace ring") {
    test("tracing reports enabled") {
      assert(RuntimeInfo.trace_enabled() == true)
    }

    test("spawn, send, receive, and exit are captured in order with correct pids") {
      _reset = RuntimeInfo.trace_reset()

      child = Process.spawn(&TestConcurrencyTraced.TraceTest.echo_once_entry/0)
      _channel = Process.send(Process.pid(u64, child), Process.self())
      _work = Process.send(Process.pid(i64, child), 41)
      echoed = receive i64 {
        n -> n
      }
      assert(echoed == 42)

      # The child replied and exits; its teardown finishes asynchronously
      # on its core — poll until the exit event lands in the ring.
      count = TestConcurrencyTraced.TraceTest.capture_until_exit(child, 200)
      assert(count > 0)

      spawn_index = TestConcurrencyTraced.TraceTest.find_event(:spawn, child, 0, 0, count)
      send_index = TestConcurrencyTraced.TraceTest.find_event(:send, Process.self(), child, 0, count)
      receive_index = TestConcurrencyTraced.TraceTest.find_event(:receive, child, 0, 0, count)
      exit_index = TestConcurrencyTraced.TraceTest.find_event(:exit, child, 0, 0, count)
      reply_send_index = TestConcurrencyTraced.TraceTest.find_event(:send, child, Process.self(), 0, count)
      reply_receive_index = TestConcurrencyTraced.TraceTest.find_event(:receive, Process.self(), 0, 0, count)

      # Every lifecycle event is present…
      assert(spawn_index < count)
      assert(send_index < count)
      assert(receive_index < count)
      assert(exit_index < count)
      assert(reply_send_index < count)
      assert(reply_receive_index < count)

      # …in causal order (captures are oldest-first, so index order IS
      # sequence order): the child is spawned before the parent's send is
      # recorded, the send before the child consumes it, the child's
      # reply-send before its exit.
      assert(spawn_index < send_index)
      assert(send_index < receive_index)
      assert(receive_index < reply_send_index)
      assert(reply_send_index < exit_index)

      # Sequence numbers are strictly increasing alongside the indexes.
      assert(RuntimeInfo.trace_sequence(spawn_index) < RuntimeInfo.trace_sequence(send_index))
      assert(RuntimeInfo.trace_sequence(send_index) < RuntimeInfo.trace_sequence(receive_index))
      assert(RuntimeInfo.trace_sequence(receive_index) < RuntimeInfo.trace_sequence(exit_index))

      # Detail codes: the send was delivered (0) and the exit normal (0).
      assert(RuntimeInfo.trace_detail(send_index) == 0)
      assert(RuntimeInfo.trace_detail(exit_index) == 0)
    }

    test("reset discards the retained window") {
      _reset = RuntimeInfo.trace_reset()
      count = RuntimeInfo.trace_capture()
      # At most this process's own just-emitted activity can trickle in
      # between reset and capture; the child lifecycle above is gone.
      assert(count <= 2)
    }
  }

  @doc = """
    Capture the ring, retrying (bounded) until an `:exit` event for
    `child` is present — the child's teardown races the parent's
    capture, and each retry parks 1 ms via `receive … after`. Returns
    the final captured count (0 when the exit never appeared).
    """

  pub fn capture_until_exit(child :: u64, attempts_left :: i64) -> i64 {
    count = RuntimeInfo.trace_capture()
    exit_index = TestConcurrencyTraced.TraceTest.find_event(:exit, child, 0, 0, count)
    if exit_index < count {
      count
    } else {
      if attempts_left == 0 {
        0
      } else {
        _pause = receive i64 {
          n -> n
        after
          1 -> 0
        }
        TestConcurrencyTraced.TraceTest.capture_until_exit(child, attempts_left - 1)
      }
    }
  }

  @doc = """
    Linear scan of the captured events for the first event of `kind`
    with acting pid `pid` and — when `peer` is nonzero — counterparty
    `peer`. Returns its index, or `count` (one past the end) when
    absent.
    """

  pub fn find_event(kind :: Atom, pid :: u64, peer :: u64, index :: i64, count :: i64) -> i64 {
    if index >= count {
      count
    } else {
      if RuntimeInfo.trace_kind(index) == kind and RuntimeInfo.trace_pid_bits(index) == pid and (peer == 0 or RuntimeInfo.trace_peer_bits(index) == peer) {
        index
      } else {
        TestConcurrencyTraced.TraceTest.find_event(kind, pid, peer, index + 1, count)
      }
    }
  }

  @doc = """
    Child body: reads its reply channel, receives one `i64`, replies
    with the value plus one, and exits normally.
    """

  pub fn echo_once_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    value = Process.receive_raw(i64)
    _reply = Process.send(parent, value + 1)
    nil
  }
}
