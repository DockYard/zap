@doc = """
  OTP-grade process supervision, written in PURE ZAP over the P5-J1/J2 signal
  intrinsics (`spawn_link`, `link`, `trap_exit`, `exit_signal`, `kill`,
  `await_signal`, `monotonic_millis`, and `receive`'s `after`). A supervisor is
  NOT a runtime primitive — it is an ordinary Zap process running a receive loop
  over its children's exit signals, exactly Gleam OTP's architecture: a small
  signal core in the runtime, supervisors in the surface language.

  ## The realization: a trap-exit receive loop over LINKED children

  A supervisor process:

    1. sets `trap_exit` so a child's death arrives as an `{'EXIT', child, reason}`
       message (via `Process.await_signal`) instead of cascading;
    2. starts its children left→right, `spawn_link`-ing each so their exits are
       delivered to it;
    3. blocks in `Process.await_signal`, and on each child death applies its
       restart strategy + the child's restart type to decide what to restart;
    4. enforces a restart-intensity window (a crash-loop breaker);
    5. terminates children right→left through the per-child shutdown protocol.

  Because every child is `spawn_link`ed to the supervisor, the LINK itself is the
  structured-concurrency guarantee: no child can outlive the supervisor. If the
  supervisor dies, the kernel propagates its exit down every link and the
  children die with it — the same scoped-lifetime lifetime Zig's `Group` gives a
  nursery, achieved here by the link graph rather than a separate primitive. The
  supervisor's own trap-exit receive loop IS the nursery; the restart-intensity
  window and the child specs are what a bare nursery lacks. So we build directly
  on links (research.md §6.7) rather than reaching for a distinct `Group` object.

  ## Driving the loop: `init` + `step`, with a LOCAL child starter

  A supervisor must be able to (re)start a child on demand. In Zap a function
  value cannot be stored in a field, threaded through a recursive loop, or
  re-passed to a helper — so the library never holds a "start" callback. Instead
  control is INVERTED, exactly like an OTP callback module: the library owns all
  the POLICY as pure data transforms (`Supervisor.init`, `Supervisor.step`,
  `Supervisor.installed`) and your supervisor module owns the tiny LOOP that
  actually starts a child. `Supervisor.step` returns the NEXT child id to
  (re)start (one at a time); your loop calls your OWN local `dispatch` for it (a
  same-module call — no function value in sight) and feeds the pid back with
  `Supervisor.installed`.

      pub struct MyApp.Sup {
        pub fn start() -> u64 {
          Supervisor.start_link(&MyApp.Sup.run/0)
        }

        pub fn run() -> Nil {
          children = [Supervisor.worker(:db), Supervisor.worker(:cache)]
          state = Supervisor.init(children, Supervisor.default_options())
          MyApp.Sup.loop(state)
        }

        pub fn loop(state :: SupervisorState) -> Nil {
          current = Supervisor.step(state)
          case current.action {
            :start ->
              MyApp.Sup.loop(Supervisor.installed(current.state, current.child_id, MyApp.Sup.dispatch(current.child_id)))
            :stop ->
              Process.exit_with(current.reason)
            _ ->
              MyApp.Sup.loop(current.state)
          }
        }

        pub fn dispatch(child_id :: Atom) -> u64 {
          case child_id {
            :db    -> Process.spawn_link(&MyApp.db_entry/0)
            :cache -> Process.spawn_link(&MyApp.cache_entry/0)
            _      -> Process.spawn_link(&MyApp.db_entry/0)
          }
        }
      }

  `dispatch` MUST `Process.spawn_link` the child so the supervisor (which runs
  the loop, hence the caller of `dispatch`) is linked to it and notified of its
  death. It typically `case`s on `child_id` to pick the right entry function.

  ## Semantics (Erlang/OTP, research.md §6.7 — implemented precisely)

  - **Strategies**: `:one_for_one` (restart only the crashed child),
    `:rest_for_one` (restart the crashed child + every child started AFTER it, in
    start order), `:one_for_all` (restart ALL children on any crash),
    `:simple_one_for_one` (homogeneous children from one spec — restart just the
    crashed instance, i.e. one-for-one scope over a uniform child set).
  - **Restart types**: `:permanent` (always restarted), `:temporary` (never), and
    `:transient` (restarted only on an ABNORMAL exit — any reason other than
    `:normal` or `:shutdown`).
  - **Restart intensity**: if MORE THAN `intensity` restarts occur within `period`
    milliseconds, the supervisor gives up — it terminates its children right→left
    and exits `:shutdown`. Defaults: intensity 1, period 5000 ms.
  - **Child order**: children START left→right and TERMINATE right→left.
  - **Shutdown protocol** (per child): `:brutal_kill` (immediate untrappable
    `exit(kill)`), `:timeout` (`exit(shutdown)`, then `kill` after
    `shutdown_timeout_ms` if still alive), `:infinity` (`exit(shutdown)`, wait
    indefinitely — the default for supervisor children).
  - **Defaults**: intensity 1, period 5000 ms, strategy `:one_for_one`, restart
    `:permanent`.

  ## Supervision trees

  A supervisor is itself an ordinary process, so a supervisor may be a child of
  another supervisor: the parent's `dispatch(:sub)` simply `spawn_link`s an entry
  that runs `Supervisor.init` + the loop again (a supervisor child uses
  `:infinity` shutdown by default — `Supervisor.supervisor/1`). Terminating a
  subtree therefore recurses: the parent sends the sub-supervisor `:shutdown`,
  which (being a trapping process) observes it as an exit signal from a NON-child
  sender, terminates ITS OWN children right→left, and exits — a depth-first,
  right→left teardown of the whole subtree.
  """

@doc = """
  One child's supervision policy — the data half of an OTP child spec (the "how
  to start it" half is your module's `dispatch`, keyed by `child_id`).

  - `child_id`   — the atom your `dispatch` starts a child for.
  - `restart`    — `:permanent` | `:temporary` | `:transient` (when to restart).
  - `shutdown_kind` — `:brutal_kill` | `:timeout` | `:infinity` (how to stop it).
  - `shutdown_timeout_ms` — grace period for `:timeout` before the `kill`.
  - `child_type` — `:worker` | `:supervisor` (a supervisor child nests a subtree).

  Prefer the `Supervisor.worker/1`, `Supervisor.supervisor/1`, and
  `Supervisor.child_spec/*` constructors over building this struct directly.
  """

pub struct SupervisorChildSpec {
  child_id :: Atom
  restart :: Atom
  shutdown_kind :: Atom
  shutdown_timeout_ms :: i64
  child_type :: Atom
}

@doc = """
  A supervisor's strategy configuration.

  - `strategy`   — `:one_for_one` | `:rest_for_one` | `:one_for_all` |
    `:simple_one_for_one`.
  - `intensity`  — the maximum number of restarts tolerated within `period_ms`;
    exceeding it terminates the supervisor (the crash-loop breaker).
  - `period_ms`  — the restart-intensity window, in milliseconds.

  Build with `Supervisor.options/3` or `Supervisor.default_options/0` (the OTP
  defaults: `:one_for_one`, intensity 1, period 5000 ms).
  """

pub struct SupervisorOptions {
  strategy :: Atom
  intensity :: i64
  period_ms :: i64
}

@doc = """
  The supervisor's live state, threaded through your loop as plain data (no
  function values). `specs` and `options` are fixed; `live_pids` is index-aligned
  with `specs` (`0` = not currently running); `restart_history` is the sliding
  intensity window of restart timestamps (ms); `pending_starts` is the queue of
  child ids `Supervisor.step` will hand you to (re)start, in order. Construct it
  with `Supervisor.init` and evolve it only through `Supervisor.step` /
  `Supervisor.installed`.
  """

pub struct SupervisorState {
  specs :: List(SupervisorChildSpec)
  live_pids :: List(u64)
  restart_history :: List(i64)
  pending_starts :: List(Atom)
  options :: SupervisorOptions
}

@doc = """
  One turn of the supervisor loop, returned by `Supervisor.step`. `action` is
  `:start` (call your `dispatch(child_id)` then `Supervisor.installed`),
  `:continue` (just loop with `state`), or `:stop` (the supervisor is done — its
  children are already terminated; your loop must `Process.exit_with(reason)` so
  the supervisor process dies with the right reason, e.g. `:shutdown`). `child_id`
  is the child to (re)start when `action` is `:start`; `reason` is the exit reason
  when `action` is `:stop`; `state` is the state to carry forward.
  """

pub struct SupervisorStep {
  action :: Atom
  child_id :: Atom
  reason :: Atom
  state :: SupervisorState
}

@doc = """
  OTP-grade supervisor implemented entirely in Zap over the process signal
  intrinsics (`spawn_link`, `trap_exit`, `exit_signal`, `kill`, `receive`).

  A supervisor is a receive-loop over a set of linked children. It traps exits
  so a child crash arrives as a message rather than propagating, then applies a
  restart strategy (`:one_for_one`, `:rest_for_one`, `:one_for_all`,
  `:simple_one_for_one`) honoring each child's restart type
  (`:permanent`, `:temporary`, `:transient`) and shutdown protocol
  (`:brutal_kill`, a timeout, or `:infinity`). A restart-intensity breaker
  (`intensity` restarts within `period_ms`) stops the supervisor when a child
  crash-loops.

  The supervisor owns pure data transforms (`init/2`, `step/1`, `installed/3`);
  the driving loop lives in user code and dispatches child start-up locally, so
  no function values ever cross a struct boundary. Supervisors nest: a child
  whose `child_type` is `:supervisor` is itself a supervisor loop, giving full
  supervision trees.
  """

pub struct Supervisor {
  @doc = """
    Build a full `ChildSpec` from all five fields. Prefer `worker/1` or
    `supervisor/1` for the common cases.
    """

  pub fn child_spec(child_id :: Atom, restart :: Atom, shutdown_kind :: Atom, shutdown_timeout_ms :: i64, child_type :: Atom) -> SupervisorChildSpec {
    %SupervisorChildSpec{child_id: child_id, restart: restart, shutdown_kind: shutdown_kind, shutdown_timeout_ms: shutdown_timeout_ms, child_type: child_type}
  }

  @doc = """
    A worker child with the OTP defaults: `:permanent` restart, a 5000 ms
    `:timeout` shutdown, `:worker` type. `child_id` is the atom your `dispatch`
    starts a child for.
    """

  pub fn worker(child_id :: Atom) -> SupervisorChildSpec {
    Supervisor.child_spec(child_id, :permanent, :timeout, 5000, :worker)
  }

  @doc = """
    A worker child with an explicit restart type, keeping the default 5000 ms
    `:timeout` shutdown and `:worker` type.
    """

  pub fn worker(child_id :: Atom, restart :: Atom) -> SupervisorChildSpec {
    Supervisor.child_spec(child_id, restart, :timeout, 5000, :worker)
  }

  @doc = """
    A supervisor child (a nested subtree). Defaults to `:permanent` restart and
    `:infinity` shutdown — the OTP default for supervisor children, which must be
    allowed to terminate their own subtree without a deadline.
    """

  pub fn supervisor(child_id :: Atom) -> SupervisorChildSpec {
    Supervisor.child_spec(child_id, :permanent, :infinity, 0, :supervisor)
  }

  @doc = """
    A ChildSpec whose shutdown is `:brutal_kill` — an immediate, untrappable
    `exit(kill)` with no grace period. Keeps `:permanent` restart and `:worker`
    type.
    """

  pub fn brutal_worker(child_id :: Atom) -> SupervisorChildSpec {
    Supervisor.child_spec(child_id, :permanent, :brutal_kill, 0, :worker)
  }

  @doc = """
    A `SupervisorOptions` from all three fields.
    """

  pub fn options(strategy :: Atom, intensity :: i64, period_ms :: i64) -> SupervisorOptions {
    %SupervisorOptions{strategy: strategy, intensity: intensity, period_ms: period_ms}
  }

  @doc = """
    The OTP default options: `:one_for_one`, intensity 1, period 5000 ms.
    """

  pub fn default_options() -> SupervisorOptions {
    Supervisor.options(:one_for_one, 1, 5000)
  }

  @doc = """
    Spawn a new process running `entry` (which must run `Supervisor.init` + your
    loop) and LINK it to the caller — the top-level way to start a supervision
    tree, and how a parent supervisor's `dispatch` starts a supervisor child.
    Returns the supervisor's raw pid bits. `entry` is a named, capture-less
    zero-parameter function, exactly as `Process.spawn_link` requires.
    """

  pub fn start_link(entry :: fn() -> Nil) -> u64 {
    Process.spawn_link(entry)
  }

  @doc = """
    Spawn a new process running `entry` WITHOUT linking it to the caller — for a
    caller that observes the tree from outside it (e.g. a test harness) and does
    not want the supervisor's death to cascade to it. Returns the supervisor's
    raw pid bits.
    """

  pub fn start(entry :: fn() -> Nil) -> u64 {
    Process.spawn(entry)
  }

  @doc = """
    Begin supervising `children` under `options`: trap exits (so child deaths
    arrive as signals rather than cascading) and return the initial `State` with
    every child queued to be started, left→right. Call it at the top of your
    supervisor entry, then drive `Supervisor.step` in your loop — the first
    `step` calls hand you each child to start in order.
    """

  pub fn init(children :: List(SupervisorChildSpec), options :: SupervisorOptions) -> SupervisorState {
    _trapped = Process.trap_exit(true)
    child_count = List.length(children)
    initial_pids = (List.new_filled(child_count, (0 :: u64)) :: List(u64))
    initial_history = (List.new_empty(4) :: List(i64))
    initial_pending = Supervisor.child_ids(children, 0, child_count, (List.new_empty(child_count) :: List(Atom)))
    %SupervisorState{specs: children, live_pids: initial_pids, restart_history: initial_history, pending_starts: initial_pending, options: options}
  }

  @doc = """
    Advance the supervisor by one turn. If a child is queued to (re)start,
    returns `%Step{action: :start, child_id: <id>, state: <state>}` — your loop
    must then call your `dispatch(child_id)` and feed the pid back through
    `Supervisor.installed`. Otherwise it BLOCKS in `Process.await_signal` for the
    next child death, applies the restart strategy + restart type, enforces the
    intensity window (terminating the whole subtree and exiting `:shutdown` if
    exceeded — this call then never returns), and returns either a `:start` (the
    first child of the resulting restart plan) or a `:continue` (nothing to
    start). A signal from a NON-child sender (the supervisor's own parent
    terminating it) tears the subtree down right→left and exits — again never
    returning.
    """

  pub fn step(state :: SupervisorState) -> SupervisorStep {
    case List.empty?(state.pending_starts) {
      false ->
        {
          next_id = List.head(state.pending_starts)
          remaining = List.tail(state.pending_starts)
          %SupervisorStep{action: :start, child_id: next_id, reason: :normal, state: Supervisor.with_pending(state, remaining)}
        }
      true ->
        {
          reason = Process.await_signal()
          from = Process.last_signal_from()
          crashed_index = Supervisor.index_of_pid(state.live_pids, from, 0, List.length(state.live_pids))
          case crashed_index < 0 {
            true ->
              {
                # A signal from a NON-child (the supervisor's own parent/linker
                # terminating it): tear the subtree down right→left and tell the
                # loop to exit with the received reason.
                _down = Supervisor.terminate_all(state.specs, state.live_pids, List.length(state.specs) - 1)
                %SupervisorStep{action: :stop, child_id: :none, reason: reason, state: state}
              }
            false -> Supervisor.handle_child_death(state, crashed_index, reason)
          }
        }
    }
  }

  @doc = """
    Record that `child_id` was (re)started as `pid`, returning the updated state —
    call it right after your `dispatch(child_id)` when `step` returned `:start`.
    """

  pub fn installed(state :: SupervisorState, child_id :: Atom, pid :: u64) -> SupervisorState {
    index = Supervisor.index_of_child_id(state.specs, child_id, 0, List.length(state.specs))
    Supervisor.with_live_pids(state, List.set(state.live_pids, index, pid))
  }

  @doc = """
    Decide and act on one child's exit: honor its restart type, enforce the
    intensity window, and apply the strategy — returning the next `Step`.
    Internal to `step`.
    """

  fn handle_child_death(state :: SupervisorState, crashed_index :: i64, reason :: Atom) -> SupervisorStep {
    spec = List.at(state.specs, crashed_index)
    case Supervisor.triggers_restart?(spec.restart, reason) {
      false ->
        {
          # `:temporary` (never restarted) or a `:transient` child that exited
          # cleanly: drop it from the live set with no sibling effect and no
          # intensity charge — no restart happened.
          dropped = Supervisor.with_live_pids(state, List.set(state.live_pids, crashed_index, (0 :: u64)))
          %SupervisorStep{action: :continue, child_id: :none, reason: :normal, state: dropped}
        }
      true ->
        {
          now = Process.monotonic_millis()
          updated_history = Supervisor.record_restart(state.restart_history, now, state.options.period_ms)
          case List.length(updated_history) > state.options.intensity {
            true ->
              {
                # Restart-intensity exceeded: the crash-loop breaker. The crashed
                # child is already dead, so drop it before terminating the
                # SURVIVORS right→left, then tell the loop to give up and exit
                # `:shutdown`.
                survivors = List.set(state.live_pids, crashed_index, (0 :: u64))
                _down = Supervisor.terminate_all(state.specs, survivors, List.length(state.specs) - 1)
                %SupervisorStep{action: :stop, child_id: :none, reason: :shutdown, state: Supervisor.with_live_pids(state, survivors)}
              }
            false ->
              {
                planned = Supervisor.plan_restart(state, updated_history, crashed_index)
                Supervisor.step(planned)
              }
          }
        }
    }
  }

  @doc = """
    Build the restart plan for the crashed child under the state's strategy:
    terminate the affected still-live siblings (right→left, per their shutdown
    protocol), and queue the children to (re)start (left→right, skipping
    `:temporary` ones). Returns the state carrying the updated live pids, the new
    intensity history, and the `pending_starts` queue. Internal.
    """

  fn plan_restart(state :: SupervisorState, updated_history :: List(i64), crashed_index :: i64) -> SupervisorState {
    last_index = List.length(state.specs) - 1
    scoped = case state.options.strategy {
      :one_for_one -> Supervisor.plan_scope(state, crashed_index, crashed_index, crashed_index)
      :simple_one_for_one -> Supervisor.plan_scope(state, crashed_index, crashed_index, crashed_index)
      :rest_for_one -> Supervisor.plan_scope(state, crashed_index, last_index, crashed_index)
      :one_for_all -> Supervisor.plan_scope(state, 0, last_index, crashed_index)
      _ -> Supervisor.plan_scope(state, crashed_index, crashed_index, crashed_index)
    }
    Supervisor.with_history(scoped, updated_history)
  }

  @doc = """
    Terminate the still-live children in `[low_index, high_index]` (right→left,
    skipping the already-dead crashed child), then return the state with those
    pids zeroed and `pending_starts` set to the children of the scope to restart
    (left→right, skipping `:temporary`). Backs `:one_for_one` (scope = the crashed
    child alone), `:rest_for_one` (crashed..last), and `:one_for_all` (0..last).
    Internal.
    """

  fn plan_scope(state :: SupervisorState, low_index :: i64, high_index :: i64, crashed_index :: i64) -> SupervisorState {
    after_crash = List.set(state.live_pids, crashed_index, (0 :: u64))
    after_terminate = Supervisor.terminate_scope(state.specs, after_crash, high_index, low_index)
    restart_ids = Supervisor.scope_restart_ids(state.specs, low_index, high_index, (List.new_empty(high_index - low_index + 1) :: List(Atom)))
    Supervisor.with_live_and_pending(state, after_terminate, restart_ids)
  }

  @doc = """
    Collect the child ids in `[index, high_index]` (start order) whose restart
    type is not `:temporary` — the children a scope restart re-starts. Internal.
    """

  fn scope_restart_ids(specs :: List(SupervisorChildSpec), index :: i64, high_index :: i64, collected :: List(Atom)) -> List(Atom) {
    case index <= high_index {
      true ->
        {
          spec = List.at(specs, index)
          next_collected = case spec.restart == :temporary {
            true -> collected
            false -> List.push(collected, spec.child_id)
          }
          Supervisor.scope_restart_ids(specs, index + 1, high_index, next_collected)
        }
      false -> collected
    }
  }

  @doc = """
    The child ids of `specs` in start order — the initial start queue. Internal.
    """

  fn child_ids(specs :: List(SupervisorChildSpec), index :: i64, total :: i64, collected :: List(Atom)) -> List(Atom) {
    case index < total {
      true -> Supervisor.child_ids(specs, index + 1, total, List.push(collected, List.at(specs, index).child_id))
      false -> collected
    }
  }

  @doc = """
    Whether a child of the given restart type, having exited with `reason`,
    should be restarted: `:permanent` always; `:temporary` never; `:transient`
    only on an ABNORMAL exit (any reason but `:normal` or `:shutdown`).
    """

  fn triggers_restart?(restart :: Atom, reason :: Atom) -> Bool {
    case restart {
      :permanent -> true
      :temporary -> false
      :transient -> reason != :normal and reason != :shutdown
      _ -> true
    }
  }

  @doc = """
    Append `now` to the restart history and drop every entry older than
    `period_ms` — the sliding restart-intensity window. The caller compares the
    result's length against `intensity`. Internal.
    """

  fn record_restart(history :: List(i64), now :: i64, period_ms :: i64) -> List(i64) {
    cutoff = now - period_ms
    empty_kept = (List.new_empty(List.length(history) + 1) :: List(i64))
    pruned = Supervisor.prune_history(history, cutoff, 0, List.length(history), empty_kept)
    List.push(pruned, now)
  }

  @doc = """
    Keep only the restart timestamps at or after `cutoff`. Internal.
    """

  fn prune_history(history :: List(i64), cutoff :: i64, index :: i64, total :: i64, kept :: List(i64)) -> List(i64) {
    case index < total {
      true ->
        {
          timestamp = List.at(history, index)
          next_kept = case timestamp >= cutoff {
            true -> List.push(kept, timestamp)
            false -> kept
          }
          Supervisor.prune_history(history, cutoff, index + 1, total, next_kept)
        }
      false -> kept
    }
  }

  @doc = """
    Terminate the still-live children in `[low_index, high_index]` in reverse
    (right→left) order, each through its shutdown protocol, returning the
    live-pid list with those children zeroed. Skips children already dead (pid
    `0`). Internal.
    """

  fn terminate_scope(specs :: List(SupervisorChildSpec), live_pids :: List(u64), index :: i64, low_index :: i64) -> List(u64) {
    case index >= low_index {
      true ->
        {
          pid = List.at(live_pids, index)
          next_live = case pid == 0 {
            true -> live_pids
            false ->
              {
                _stopped = Supervisor.terminate_child(List.at(specs, index), pid)
                List.set(live_pids, index, (0 :: u64))
              }
          }
          Supervisor.terminate_scope(specs, next_live, index - 1, low_index)
        }
      false -> live_pids
    }
  }

  @doc = """
    Terminate every live child right→left (index `high_index` downto 0), each
    through its shutdown protocol — the whole-subtree teardown used when the
    supervisor is shutting down or giving up. Internal.
    """

  fn terminate_all(specs :: List(SupervisorChildSpec), live_pids :: List(u64), index :: i64) -> Bool {
    case index >= 0 {
      true ->
        {
          pid = List.at(live_pids, index)
          _stopped = case pid == 0 {
            true -> true
            false -> Supervisor.terminate_child(List.at(specs, index), pid)
          }
          Supervisor.terminate_all(specs, live_pids, index - 1)
        }
      false -> true
    }
  }

  @doc = """
    Terminate one child through its shutdown protocol and reap its exit:
    `:brutal_kill` — untrappable `kill`, then reap; `:infinity` — `exit(shutdown)`
    then reap, waiting indefinitely; `:timeout` — `exit(shutdown)`, wait up to
    `shutdown_timeout_ms` for it to die, and `kill` it if the deadline passes.
    Because the supervisor traps exits and is linked to the child, the child's
    death always arrives as a reap-able exit signal. Internal.
    """

  fn terminate_child(spec :: SupervisorChildSpec, pid :: u64) -> Bool {
    case spec.shutdown_kind {
      :brutal_kill ->
        {
          _killed = Process.kill(pid)
          Supervisor.reap_exit(pid)
        }
      :infinity ->
        {
          _asked = Process.exit_signal(pid, :shutdown)
          Supervisor.reap_exit(pid)
        }
      :timeout ->
        {
          _asked = Process.exit_signal(pid, :shutdown)
          case Supervisor.wait_exit(pid, spec.shutdown_timeout_ms) {
            true -> true
            false ->
              {
                _killed = Process.kill(pid)
                Supervisor.reap_exit(pid)
              }
          }
        }
      _ ->
        {
          _asked = Process.exit_signal(pid, :shutdown)
          Supervisor.reap_exit(pid)
        }
    }
  }

  @doc = """
    Block (via `await_signal`) until the exit of the process `pid` has been
    consumed, discarding any other signal that arrives first (another child's
    stray death during teardown). Internal to `terminate_child`.
    """

  fn reap_exit(pid :: u64) -> Bool {
    _reason = Process.await_signal()
    case Process.last_signal_from() == pid {
      true -> true
      false -> Supervisor.reap_exit(pid)
    }
  }

  @doc = """
    Wait up to `timeout_ms` for the exit of `pid`, consuming it if it arrives
    (returning `true`) or reporting the deadline elapsed (`false`). Composed from
    the non-consuming `wait_for_message` peek (which reports ANY head envelope,
    signals included) plus `await_signal` to consume the signal once present —
    the timed-signal-wait the `:timeout` shutdown protocol needs. Internal.
    """

  fn wait_exit(pid :: u64, timeout_ms :: i64) -> Bool {
    case :zig.ProcessRuntime.wait_for_message(timeout_ms) {
      true ->
        {
          _reason = Process.await_signal()
          case Process.last_signal_from() == pid {
            true -> true
            false -> Supervisor.wait_exit(pid, timeout_ms)
          }
        }
      false -> false
    }
  }

  @doc = """
    The index of `target` raw pid bits in `live_pids`, or `-1` if absent. Used to
    tell a child's exit signal from the supervisor's own parent's. Internal.
    """

  fn index_of_pid(live_pids :: List(u64), target :: u64, index :: i64, total :: i64) -> i64 {
    case index < total {
      true ->
        case List.at(live_pids, index) == target {
          true -> index
          false -> Supervisor.index_of_pid(live_pids, target, index + 1, total)
        }
      false -> -1
    }
  }

  @doc = """
    The index of the spec whose `child_id` is `target`. Internal to `installed`.
    """

  fn index_of_child_id(specs :: List(SupervisorChildSpec), target :: Atom, index :: i64, total :: i64) -> i64 {
    case index < total {
      true ->
        case List.at(specs, index).child_id == target {
          true -> index
          false -> Supervisor.index_of_child_id(specs, target, index + 1, total)
        }
      false -> -1
    }
  }

  @doc = """
    Return `state` with a new `pending_starts` queue. Internal.
    """

  fn with_pending(state :: SupervisorState, pending :: List(Atom)) -> SupervisorState {
    %SupervisorState{specs: state.specs, live_pids: state.live_pids, restart_history: state.restart_history, pending_starts: pending, options: state.options}
  }

  @doc = """
    Return `state` with new `live_pids`. Internal.
    """

  fn with_live_pids(state :: SupervisorState, live_pids :: List(u64)) -> SupervisorState {
    %SupervisorState{specs: state.specs, live_pids: live_pids, restart_history: state.restart_history, pending_starts: state.pending_starts, options: state.options}
  }

  @doc = """
    Return `state` with new `restart_history`. Internal.
    """

  fn with_history(state :: SupervisorState, restart_history :: List(i64)) -> SupervisorState {
    %SupervisorState{specs: state.specs, live_pids: state.live_pids, restart_history: restart_history, pending_starts: state.pending_starts, options: state.options}
  }

  @doc = """
    Return `state` with new `live_pids` and `pending_starts`. Internal.
    """

  fn with_live_and_pending(state :: SupervisorState, live_pids :: List(u64), pending :: List(Atom)) -> SupervisorState {
    %SupervisorState{specs: state.specs, live_pids: live_pids, restart_history: state.restart_history, pending_starts: pending, options: state.options}
  }
}
