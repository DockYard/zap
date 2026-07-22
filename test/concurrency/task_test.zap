pub struct Concurrency.TaskTest {
  use Zest.Case

  describe("Task.async/await round trips") {
    test("round-trips a typed i64 result") {
      task = Task.async(&Concurrency.TaskTest.compute_seven/0)
      assert(Task.await(task) == 7)
    }

    test("round-trips a rich String result through the correlated decode") {
      task = Task.async(&Concurrency.TaskTest.compute_greeting/0)
      assert(Task.await(task) == "hello from the worker")
    }

    test("two overlapping tasks resolve independently (mark fallback stays sound)") {
      first = Task.async(&Concurrency.TaskTest.compute_seven/0)
      second = Task.async(&Concurrency.TaskTest.compute_eleven/0)
      # Await in reverse creation order: only the SECOND task's mark is
      # still bound (one mark slot, the Erlang recv_mark limitation), so
      # the first await exercises the sound head-scan fallback.
      assert(Task.await(second) == 11)
      assert(Task.await(first) == 7)
    }

    test("the owner's mailbox stays clean after await (demonitor+flush leaves no stale DOWN)") {
      task = Task.async(&Concurrency.TaskTest.compute_seven/0)
      _value = Task.await(task)
      # If the worker's :normal DOWN lingered, this steady-state receive
      # would hit it first and dead-letter the process.
      _self_sent = Process.send(Process.pid(i64, Process.self()), 99)
      got = receive i64 { n -> n }
      assert(got == 99)
    }
  }

  describe("Task.await failure surface (Elixir-aligned exits)") {
    test("await propagates a worker crash as an exit with the worker's reason") {
      _observer = Process.spawn_monitor(&Concurrency.TaskTest.awaits_crashing_task_entry/0)
      reason = Process.await_signal()
      assert(reason == :task_boom)
      assert(Process.last_signal_kind() == 2)
    }

    test("await exits with :timeout when the worker never replies") {
      _observer = Process.spawn_monitor(&Concurrency.TaskTest.awaits_stuck_task_entry/0)
      reason = Process.await_signal()
      assert(reason == :timeout)
    }

    test("await by a non-owner exits with :not_owner") {
      task = Task.async(&Concurrency.TaskTest.compute_seven/0)
      # The owner (this test) consumes the result first, so the task's
      # reply cannot sit at OUR mailbox head when we await the signal.
      assert(Task.await(task) == 7)
      {helper, _helper_ref} = Process.spawn_monitor(&Concurrency.TaskTest.non_owner_await_entry/0)
      _task_sent = Process.send((Pid.of(helper) :: Pid(Task(i64))), task)
      reason = Process.await_signal()
      assert(reason == :not_owner)
    }
  }

  # -- task worker functions --------------------------------------------------

  pub fn compute_seven() -> i64 {
    7
  }

  pub fn compute_eleven() -> i64 {
    11
  }

  pub fn compute_greeting() -> String {
    "hello from the worker"
  }

  pub fn crashing_worker() -> i64 {
    Process.exit_with(:task_boom)
  }

  pub fn stuck_worker() -> i64 {
    # Parks forever: nobody ever sends this worker an i64.
    receive i64 { n -> n }
  }

  # -- observer entries (spawn_monitor-ed by tests; their EXIT REASON is the
  # -- assertion surface for await's Elixir-aligned exits) ---------------------

  pub fn awaits_crashing_task_entry() -> Nil {
    task = Task.async(&Concurrency.TaskTest.crashing_worker/0)
    _never = Task.await(task)
    nil
  }

  pub fn awaits_stuck_task_entry() -> Nil {
    task = Task.async(&Concurrency.TaskTest.stuck_worker/0)
    _never = Task.await(task, 30)
    nil
  }

  pub fn non_owner_await_entry() -> Nil {
    task = receive Task(i64) { t -> t }
    _never = Task.await(task)
    nil
  }
}
