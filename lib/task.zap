@doc = """
  Typed one-shot worker processes: `Task.async(f)` spawns `f` on its own
  process and returns an awaitable `Task(t)` handle; `Task.await(task)`
  blocks until the worker's typed result arrives — the spawn+await
  request/response idiom (concurrency plan item 5.3, P5-J4; research
  §6.8's `Task.async`-style typed spawn returning a future).

  ## How a task runs

      task = Task.async(&Fib.compute/0)      # Task(i64) — typed by compute's return
      other_work()
      value = Task.await(task)               # i64

  `Task.async` `spawn_monitor`s a worker that runs the given function and
  sends its result back as a message CORRELATED with the monitor
  reference (the Erlang ref-trick — research §6.2). `Task.await` performs
  the internal correlated receive on that reference: it finds the reply —
  or the monitor's `DOWN` if the worker died — in O(1) from the
  receive-mark captured when the reference was minted, skipping any
  backlog already queued in the awaiting process's mailbox. Skipped
  messages stay queued, in order, for the ordinary `receive`; the
  correlation machinery is INTERNAL to `await`/`Process.call` and is not
  surface syntax (zap-concurrency-research §5.2, decision 7).

  ## Failure surface (Elixir-aligned)

  `Task.await` matches Elixir's `Task.await` semantics: it EXITS the
  awaiting process rather than returning an error value.

  * The worker crashed → `await` exits with the WORKER's exit reason
    (the monitor `DOWN` carries it), so the failure propagates to the
    awaiter exactly as `Task.await`'s `exit({reason, …})` does.
  * The timeout elapsed (default 5000 ms) → `await` exits with
    `:timeout`.
  * `await` from a process that did not create the task → exits with
    `:not_owner` (a task is awaited by its owner, as in Elixir).

  On the success path `await` demonitors the worker WITH FLUSH (Elixir's
  `Process.demonitor(ref, [:flush])`), so the worker's subsequent
  `:normal` `DOWN` can never linger in the owner's mailbox and poison a
  later `receive`.

  One deliberate difference from Elixir is documented rather than
  papered over: `Task.async` does not additionally LINK the worker to
  the owner (Elixir links so an owner crash kills its tasks). Linking is
  owner-lifetime policy that belongs with supervised tasks; an
  unawaited Zap task whose owner dies simply runs to completion and its
  reply dead-letters.

  ## Entry scope

  `Task.async` accepts a named (or capture-less) function reference of
  ZERO parameters returning any sendable type — the same spawn scope as
  `Process.spawn`, typed: `&Struct.function/0`. The result type must be
  sendable (`Process.send`'s rules); it is deep-copied back to the
  owner, so worker and owner never share mutable state.

  """

pub struct Task(result_type) {
  pid :: u64
  ref :: u64
  owner :: u64

  @doc = """
    Spawns `entry` (a named or capture-less zero-parameter function
    reference, `&Struct.function/0`) on a monitored worker process and
    returns the awaitable `Task(t)` handle, where `t` is `entry`'s
    return type. The worker computes `entry()` and sends the result
    back correlated with the monitor reference; the monitor's `DOWN`
    carries a crash to `Task.await` (struct doc, "Failure surface").

    The receive-mark for the O(1) correlated `await` is captured BEFORE
    the worker is spawned, so even a worker that crashes instantly is
    observed.

    ## Example

        task = Task.async(&Report.render/0)
        value = Task.await(task)

    """

  pub macro async(entry :: Expr) -> Expr {
    quote {
      _task_mark_prepared = :zig.ProcessRuntime.receive_mark_prepare()
      Task.async_start(unquote(entry), Process.spawn_monitor(fn() -> Nil {
        Task.serve(unquote(entry))
      }))
    }
  }

  @doc = """
    Completes an `async` spawn: binds the receive-mark to the freshly
    minted monitor `ref`, hands the worker its reply address (the
    `TaskHandshake`), and builds the typed handle. INTERNAL — the
    expansion target of the `Task.async` macro; `entry` is the spawned
    function reference, present to type the task (`result_type` is its
    return type), and `spawned` is `Process.spawn_monitor`'s
    `{pid, ref}`.
    """

  pub fn async_start(entry :: fn() -> result_type, spawned :: {u64, u64}) -> Task(result_type) {
    {worker, ref} = spawned
    _mark_bound = :zig.ProcessRuntime.receive_mark_bind(ref)
    handshake = %TaskHandshake{owner: Process.self(), ref: ref}
    _handshake_sent = Process.send((Pid.of(worker) :: Pid(TaskHandshake)), handshake)
    %Task(result_type){pid: worker, ref: ref, owner: Process.self()}
  }

  @doc = """
    The worker body of a task: receives the owner's `TaskHandshake`
    (the reply address and correlation ref), runs `entry`, and sends
    the result back correlated with the ref. INTERNAL — spliced into
    the spawned worker by the `Task.async` macro; it is the reason a
    task worker needs no user-written wrapper function.
    """

  pub fn serve(entry :: fn() -> result_type) -> Nil {
    handshake = receive TaskHandshake { h -> h }
    result = entry()
    _reply_sent = :zig.ProcessRuntime.send_correlated(handshake.owner, handshake.ref, result)
    nil
  }

  @doc = """
    Awaits `task`'s result with the default 5000 ms timeout (Elixir's
    `Task.await/1` default). Returns the worker's typed result, or
    EXITS the calling process — with the worker's crash reason, or
    `:timeout` — per the struct doc's failure surface.
    """

  pub fn await(task :: Task(result_type)) -> result_type {
    Task.await(task, 5000)
  }

  @doc = """
    Awaits `task`'s result for at most `timeout_milliseconds`. Returns
    the worker's typed result; exits with the worker's exit reason if
    it crashed, with `:timeout` if the deadline elapsed, or with
    `:not_owner` when called from a process that did not create the
    task (struct doc, "Failure surface"). The wait is the internal
    correlated receive: O(1) from the receive-mark past any mailbox
    backlog, which stays queued in order for the ordinary `receive`.
    """

  pub fn await(task :: Task(result_type), timeout_milliseconds :: i64) -> result_type {
    case task.owner == Process.self() {
      false -> Process.exit_with(:not_owner)
      true ->
        {
          outcome = :zig.ProcessRuntime.await_correlated(task.ref, timeout_milliseconds)
          case outcome {
            0 ->
              {
                value = (:zig.ProcessRuntime.take_correlated_message() :: result_type)
                # Elixir demonitor(ref, [:flush]): the worker exits right
                # after replying, and its :normal DOWN must never linger.
                _flushed = :zig.ProcessRuntime.demonitor_flush(task.ref)
                value
              }
            1 ->
              {
                # The worker died before replying: the DOWN was consumed
                # by the correlated receive; propagate its reason
                # (Elixir Task.await exits on a crashed task).
                _demonitored = Process.demonitor(task.ref)
                Process.exit_with(Process.last_signal_reason())
              }
            _ ->
              {
                _flushed = :zig.ProcessRuntime.demonitor_flush(task.ref)
                Process.exit_with(:timeout)
              }
          }
        }
    }
  }
}

@doc = """
  The `Task.async` handshake message: the owner's pid and the monitor/
  correlation reference, sent to a freshly spawned worker so it knows
  where — and under which correlation ref — to send its result.
  INTERNAL to the Task machinery.
  """

pub struct TaskHandshake {
  owner :: u64
  ref :: u64
}
