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
    `shutdown_timeout_ms` if still alive — an ABSOLUTE deadline; stray signals
    consumed while waiting never restart the clock), `:infinity`
    (`exit(shutdown)`, wait indefinitely — the default for supervisor children).
  - **Defaults**: intensity 1, period 5000 ms, strategy `:one_for_one`, restart
    `:permanent`.
  - **Stray signals during teardown**: while a shutdown protocol waits for ONE
    child's exit, another child can crash spontaneously — or the supervisor's
    own parent can order it down. `Process.await_signal` is destructive (it
    cannot leave a non-matching signal queued the way OTP's selective receive
    does), so every such signal is COLLECTED (`SupervisorStrays`) and folded
    back into supervisor state after the sweep: a collected child death is
    handled as a fresh exit (restart policy + intensity charge, its own sweep
    skipping already-collected pids — never a blocked re-reap), and a parent
    signal collected mid-sweep is honored as a shutdown order. Ordinary USER
    messages sent to the supervisor are skipped by the signal waits and stay
    queued — they are never decoded as signals and never abort the supervisor.

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
  The stray signals a supervisor's blocking waits collected while waiting for
  a SPECIFIC child's exit (`reap_exit`/`wait_exit` during a shutdown
  protocol). `Process.await_signal` is DESTRUCTIVE — unlike OTP's selective
  receive it cannot leave a non-matching signal queued — so every signal
  popped while awaiting a particular pid is RECORDED here (never discarded)
  and folded back into supervisor state once the wait completes: a collected
  child death is handled as if its exit had arrived at the loop (restart
  policy, intensity charge), and a collected non-child signal (the
  supervisor's own parent terminating it) is honored as a shutdown order.
  Two index-aligned lists: `froms` holds each signal's sender pid bits,
  `reasons` its reason atom. Practically bounded by the supervisor's
  link/monitor fan-in (its children plus the parent's one shutdown signal);
  an adversarial `exit_signal` spammed at the supervisor during a sweep
  window folds to a stop order on the first such stray (plan item 5.9
  tracks the parent-vs-unknown classification refinement), so the list
  cannot grow past that turn. Internal to the supervisor machinery.
  """

pub struct SupervisorStrays {
  froms :: List(u64)
  reasons :: List(Atom)
}

@doc = """
  Outcome of a timed wait for one child's exit (`wait_exit`): whether the
  child's exit was consumed before the deadline (`exited`), plus every stray
  signal collected while waiting. Internal.
  """

pub struct SupervisorReap {
  exited :: Bool
  strays :: SupervisorStrays
}

@doc = """
  Outcome of a termination sweep over a child-index range
  (`terminate_scope`): the live-pid list with the swept children zeroed, plus
  every stray signal collected during the sweep. Internal.
  """

pub struct SupervisorSweep {
  live_pids :: List(u64)
  strays :: SupervisorStrays
}

@doc = """
  Outcome of applying ONE child death to supervisor state
  (`apply_child_death`): either the supervisor must stop (`stopped` with
  `stop_reason` — the restart-intensity breaker tripped and the survivors
  were already terminated), or the updated `state` (slots zeroed, restarts
  queued, intensity recorded) plus the strays still awaiting resolution
  (`resolve_strays` folds them in). Internal.
  """

pub struct SupervisorDeathOutcome {
  stopped :: Bool
  stop_reason :: Atom
  state :: SupervisorState
  strays :: SupervisorStrays
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
                # loop to exit with the received reason. Strays collected during
                # the teardown steer its own reaps (an already-dead child is
                # never re-reaped) and are then moot — everything is stopping.
                _swept = Supervisor.terminate_all(state.specs, state.live_pids, List.length(state.specs) - 1, Supervisor.strays_empty())
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
    Decide and act on one child's exit: apply the death (restart type,
    intensity window, strategy — `apply_child_death`), then RESOLVE every
    stray signal the termination sweep collected (`resolve_strays`) before
    handing the next `Step` to the loop. Internal to `step`.
    """

  fn handle_child_death(state :: SupervisorState, crashed_index :: i64, reason :: Atom) -> SupervisorStep {
    # Snapshot of the live pids as of THIS event: the classifier for strays.
    # A stray from a snapshot pid is a child of this turn (fresh if its slot
    # is still set, already-handled if zeroed); anything else is an outside
    # signal (the supervisor's own parent). No new child pid can appear
    # mid-turn (starts happen in the loop, after `step` returns).
    snapshot = state.live_pids
    outcome = Supervisor.apply_child_death(state, crashed_index, reason, Supervisor.strays_empty())
    Supervisor.settle(outcome, snapshot)
  }

  @doc = """
    Turn one `apply_child_death` outcome into the loop's next move: a
    `:stop` step when the intensity breaker tripped, else fold the collected
    strays into state (`resolve_strays`). Internal.
    """

  fn settle(outcome :: SupervisorDeathOutcome, snapshot :: List(u64)) -> SupervisorStep {
    case outcome.stopped {
      true -> %SupervisorStep{action: :stop, child_id: :none, reason: outcome.stop_reason, state: outcome.state}
      false -> Supervisor.resolve_strays(outcome.state, snapshot, outcome.strays, 0)
    }
  }

  @doc = """
    Fold the collected stray signals into supervisor state, oldest first
    (queue order). Each stray `{from, reason}` is classified against the
    turn's `snapshot`:

    - `from` matches a LIVE child slot — a child died spontaneously while a
      sweep was waiting on someone else: handle it as a fresh child death
      (restart type, intensity charge, strategy scope — whose own sweep is
      seeded with the still-unresolved strays so it never re-reaps a
      collected pid, and whose restart queue MERGES with the pending one).
    - `from` was a child this turn but its slot is zeroed — the sweep already
      terminated (or skip-zeroed) it and its restart, if due, is already
      queued: ignore, exactly OTP's exit-from-unknown-pid rule and with no
      double intensity charge.
    - `from` was never a child — the supervisor's own parent terminated it
      mid-sweep: honor the order (terminate everything still live, skipping
      already-collected deaths) and stop with the stray's reason.

    Once every stray is resolved, re-enter `step` to emit the queued
    restarts. Internal.
    """

  fn resolve_strays(state :: SupervisorState, snapshot :: List(u64), strays :: SupervisorStrays, index :: i64) -> SupervisorStep {
    case index < List.length(strays.froms) {
      false -> Supervisor.step(state)
      true ->
        {
          stray_from = List.at(strays.froms, index)
          stray_reason = List.at(strays.reasons, index)
          child_index = Supervisor.index_of_pid(state.live_pids, stray_from, 0, List.length(state.live_pids))
          case child_index >= 0 {
            true ->
              {
                remaining = Supervisor.strays_after(strays, index + 1)
                outcome = Supervisor.apply_child_death(state, child_index, stray_reason, remaining)
                Supervisor.settle(outcome, snapshot)
              }
            false ->
              case Supervisor.index_of_pid(snapshot, stray_from, 0, List.length(snapshot)) >= 0 {
                true -> Supervisor.resolve_strays(state, snapshot, strays, index + 1)
                false ->
                  {
                    remaining = Supervisor.strays_after(strays, index + 1)
                    _swept = Supervisor.terminate_all(state.specs, state.live_pids, List.length(state.specs) - 1, remaining)
                    %SupervisorStep{action: :stop, child_id: :none, reason: stray_reason, state: state}
                  }
              }
          }
        }
    }
  }

  @doc = """
    Apply ONE child death to supervisor state: honor its restart type,
    enforce the intensity window (terminating the survivors and reporting
    `stopped` when the breaker trips), and apply the restart strategy. The
    incoming `strays` seed every sweep (collected deaths are never
    re-reaped) and accumulate what the sweeps pop; the caller resolves the
    result. Internal.
    """

  fn apply_child_death(state :: SupervisorState, crashed_index :: i64, reason :: Atom, strays :: SupervisorStrays) -> SupervisorDeathOutcome {
    spec = List.at(state.specs, crashed_index)
    case Supervisor.triggers_restart?(spec.restart, reason) {
      false ->
        {
          # `:temporary` (never restarted) or a `:transient` child that exited
          # cleanly: drop it from the live set with no sibling effect and no
          # intensity charge — no restart happened.
          dropped = Supervisor.with_live_pids(state, List.set(state.live_pids, crashed_index, (0 :: u64)))
          %SupervisorDeathOutcome{stopped: false, stop_reason: :normal, state: dropped, strays: strays}
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
                # SURVIVORS right→left (already-collected deaths skipped), then
                # tell the loop to give up and exit `:shutdown`.
                survivors = List.set(state.live_pids, crashed_index, (0 :: u64))
                _swept = Supervisor.terminate_all(state.specs, survivors, List.length(state.specs) - 1, strays)
                %SupervisorDeathOutcome{stopped: true, stop_reason: :shutdown, state: Supervisor.with_live_pids(state, survivors), strays: strays}
              }
            false -> Supervisor.plan_restart(state, updated_history, crashed_index, strays)
          }
        }
    }
  }

  @doc = """
    Build the restart plan for the crashed child under the state's strategy:
    terminate the affected still-live siblings (right→left, per their shutdown
    protocol, skipping already-collected deaths), and queue the children to
    (re)start (left→right, skipping `:temporary` ones, MERGED with any
    already-pending starts in spec order). Returns the outcome carrying the
    updated live pids, the new intensity history, the merged `pending_starts`
    queue, and the accumulated strays. Internal.
    """

  fn plan_restart(state :: SupervisorState, updated_history :: List(i64), crashed_index :: i64, strays :: SupervisorStrays) -> SupervisorDeathOutcome {
    last_index = List.length(state.specs) - 1
    planned = case state.options.strategy {
      :one_for_one -> Supervisor.plan_scope(state, crashed_index, crashed_index, crashed_index, strays)
      :simple_one_for_one -> Supervisor.plan_scope(state, crashed_index, crashed_index, crashed_index, strays)
      :rest_for_one -> Supervisor.plan_scope(state, crashed_index, last_index, crashed_index, strays)
      :one_for_all -> Supervisor.plan_scope(state, 0, last_index, crashed_index, strays)
      _ -> Supervisor.plan_scope(state, crashed_index, crashed_index, crashed_index, strays)
    }
    %SupervisorDeathOutcome{stopped: false, stop_reason: :normal, state: Supervisor.with_history(planned.state, updated_history), strays: planned.strays}
  }

  @doc = """
    Terminate the still-live children in `[low_index, high_index]` (right→left,
    skipping the already-dead crashed child and any child whose death was
    already collected as a stray), then return the outcome with those pids
    zeroed and `pending_starts` MERGED (spec order) with the scope's restart
    ids (left→right, skipping `:temporary`). Backs `:one_for_one` (scope = the
    crashed child alone), `:rest_for_one` (crashed..last), and `:one_for_all`
    (0..last). Internal.
    """

  fn plan_scope(state :: SupervisorState, low_index :: i64, high_index :: i64, crashed_index :: i64, strays :: SupervisorStrays) -> SupervisorDeathOutcome {
    after_crash = List.set(state.live_pids, crashed_index, (0 :: u64))
    sweep = Supervisor.terminate_scope(state.specs, after_crash, high_index, low_index, strays)
    restart_ids = Supervisor.scope_restart_ids(state.specs, low_index, high_index, (List.new_empty(high_index - low_index + 1) :: List(Atom)))
    merged = Supervisor.merge_pending(state.specs, state.pending_starts, restart_ids)
    %SupervisorDeathOutcome{stopped: false, stop_reason: :normal, state: Supervisor.with_live_and_pending(state, sweep.live_pids, merged), strays: sweep.strays}
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
    live-pid list with those children zeroed plus the strays collected along
    the way. Skips children already dead (pid `0`) and children whose death
    was already COLLECTED as a stray (their exit is consumed — reaping again
    would block forever on a signal that can never arrive; the collected
    death is resolved by the caller). Internal.
    """

  fn terminate_scope(specs :: List(SupervisorChildSpec), live_pids :: List(u64), index :: i64, low_index :: i64, strays :: SupervisorStrays) -> SupervisorSweep {
    case index >= low_index {
      true ->
        {
          pid = List.at(live_pids, index)
          case pid == 0 {
            true -> Supervisor.terminate_scope(specs, live_pids, index - 1, low_index, strays)
            false ->
              case Supervisor.strays_contain(strays, pid) {
                true ->
                  # Died on its own mid-sweep; its exit is already collected.
                  # Zero the slot without a reap — the stray fold accounts it.
                  Supervisor.terminate_scope(specs, List.set(live_pids, index, (0 :: u64)), index - 1, low_index, strays)
                false ->
                  {
                    swept = Supervisor.terminate_child(List.at(specs, index), pid, strays)
                    Supervisor.terminate_scope(specs, List.set(live_pids, index, (0 :: u64)), index - 1, low_index, swept)
                  }
              }
          }
        }
      false -> %SupervisorSweep{live_pids: live_pids, strays: strays}
    }
  }

  @doc = """
    Terminate every live child right→left (index `high_index` downto 0), each
    through its shutdown protocol — the whole-subtree teardown used when the
    supervisor is shutting down or giving up. Children whose deaths were
    already collected as strays are skipped (never re-reaped). Returns the
    accumulated strays, which the stopping caller then drops — every child is
    dead or terminated at that point. Internal.
    """

  fn terminate_all(specs :: List(SupervisorChildSpec), live_pids :: List(u64), index :: i64, strays :: SupervisorStrays) -> SupervisorStrays {
    case index >= 0 {
      true ->
        {
          pid = List.at(live_pids, index)
          swept = case pid == 0 {
            true -> strays
            false ->
              case Supervisor.strays_contain(strays, pid) {
                true -> strays
                false -> Supervisor.terminate_child(List.at(specs, index), pid, strays)
              }
          }
          Supervisor.terminate_all(specs, live_pids, index - 1, swept)
        }
      false -> strays
    }
  }

  @doc = """
    Terminate one child through its shutdown protocol and reap its exit:
    `:brutal_kill` — untrappable `kill`, then reap; `:infinity` — `exit(shutdown)`
    then reap, waiting indefinitely; `:timeout` — `exit(shutdown)`, wait until an
    ABSOLUTE deadline (`monotonic_millis` now + `shutdown_timeout_ms` — strays
    consumed while waiting never restart the clock) for it to die, and `kill` it
    if the deadline passes. Because the supervisor traps exits and is linked to
    the child, the child's death always arrives as a reap-able exit signal.
    Every signal from another sender popped along the way is COLLECTED into the
    returned strays (never discarded). Internal.
    """

  fn terminate_child(spec :: SupervisorChildSpec, pid :: u64, strays :: SupervisorStrays) -> SupervisorStrays {
    case spec.shutdown_kind {
      :brutal_kill ->
        {
          _killed = Process.kill(pid)
          Supervisor.reap_exit(pid, strays)
        }
      :infinity ->
        {
          _asked = Process.exit_signal(pid, :shutdown)
          Supervisor.reap_exit(pid, strays)
        }
      :timeout ->
        {
          _asked = Process.exit_signal(pid, :shutdown)
          deadline = Process.monotonic_millis() + spec.shutdown_timeout_ms
          reaped = Supervisor.wait_exit(pid, deadline, strays)
          case reaped.exited {
            true -> reaped.strays
            false ->
              {
                _killed = Process.kill(pid)
                Supervisor.reap_exit(pid, reaped.strays)
              }
          }
        }
      _ ->
        {
          _asked = Process.exit_signal(pid, :shutdown)
          Supervisor.reap_exit(pid, strays)
        }
    }
  }

  @doc = """
    Block (via `await_signal`) until the exit of the process `pid` has been
    consumed, COLLECTING every other signal that arrives first (another
    child's spontaneous death, or the supervisor's own parent terminating it
    mid-sweep) into the returned strays — the caller folds them into
    supervisor state; nothing is discarded. Internal to `terminate_child`.
    """

  fn reap_exit(pid :: u64, strays :: SupervisorStrays) -> SupervisorStrays {
    reason = Process.await_signal()
    from = Process.last_signal_from()
    case from == pid {
      true -> strays
      false -> Supervisor.reap_exit(pid, Supervisor.strays_push(strays, from, reason))
    }
  }

  @doc = """
    Wait until `deadline_ms` (an ABSOLUTE `Process.monotonic_millis` instant)
    for the exit of `pid`, consuming it if it arrives (`exited: true`) or
    reporting the deadline elapsed (`exited: false`). Built on the timed
    signal wait (`await_signal_timeout` — user messages are skipped and stay
    queued); every signal from another sender is COLLECTED into the returned
    strays and the remaining time recomputed, so a burst of strays can never
    extend the child's grace period. Internal.
    """

  fn wait_exit(pid :: u64, deadline_ms :: i64, strays :: SupervisorStrays) -> SupervisorReap {
    remaining = deadline_ms - Process.monotonic_millis()
    case remaining <= 0 {
      true -> %SupervisorReap{exited: false, strays: strays}
      false ->
        case :zig.ProcessRuntime.await_signal_timeout(remaining) {
          false -> %SupervisorReap{exited: false, strays: strays}
          true ->
            {
              from = Process.last_signal_from()
              reason = Process.last_signal_reason()
              case from == pid {
                true -> %SupervisorReap{exited: true, strays: strays}
                false -> Supervisor.wait_exit(pid, deadline_ms, Supervisor.strays_push(strays, from, reason))
              }
            }
        }
    }
  }

  @doc = """
    An empty stray-signal collection. Internal.
    """

  fn strays_empty() -> SupervisorStrays {
    %SupervisorStrays{froms: (List.new_empty(4) :: List(u64)), reasons: (List.new_empty(4) :: List(Atom))}
  }

  @doc = """
    Append one collected signal to the strays. Internal.
    """

  fn strays_push(strays :: SupervisorStrays, from :: u64, reason :: Atom) -> SupervisorStrays {
    %SupervisorStrays{froms: List.push(strays.froms, from), reasons: List.push(strays.reasons, reason)}
  }

  @doc = """
    Whether a signal from `pid` was already collected. Internal.
    """

  fn strays_contain(strays :: SupervisorStrays, pid :: u64) -> Bool {
    Supervisor.index_of_pid(strays.froms, pid, 0, List.length(strays.froms)) >= 0
  }

  @doc = """
    The strays from index `start` on — the still-unresolved tail handed to a
    nested sweep as its seed. Internal.
    """

  fn strays_after(strays :: SupervisorStrays, start :: i64) -> SupervisorStrays {
    Supervisor.strays_copy_from(strays, start, List.length(strays.froms), Supervisor.strays_empty())
  }

  @doc = """
    Copy the strays in `[index, total)` into `collected`. Internal.
    """

  fn strays_copy_from(strays :: SupervisorStrays, index :: i64, total :: i64, collected :: SupervisorStrays) -> SupervisorStrays {
    case index < total {
      true -> Supervisor.strays_copy_from(strays, index + 1, total, Supervisor.strays_push(collected, List.at(strays.froms, index), List.at(strays.reasons, index)))
      false -> collected
    }
  }

  @doc = """
    Merge two restart queues into one, in SPEC (start) order, deduplicated —
    a stray-driven restart plan joining an already-pending one must keep
    every queued child exactly once, left→right. Internal.
    """

  fn merge_pending(specs :: List(SupervisorChildSpec), current :: List(Atom), additions :: List(Atom)) -> List(Atom) {
    Supervisor.merge_pending_walk(specs, current, additions, 0, List.length(specs), (List.new_empty(List.length(specs)) :: List(Atom)))
  }

  @doc = """
    The spec-order walk behind `merge_pending`: keep each spec's `child_id`
    when it appears in either queue. Internal.
    """

  fn merge_pending_walk(specs :: List(SupervisorChildSpec), current :: List(Atom), additions :: List(Atom), index :: i64, total :: i64, collected :: List(Atom)) -> List(Atom) {
    case index < total {
      true ->
        {
          id = List.at(specs, index).child_id
          queued = Supervisor.contains_atom(current, id, 0, List.length(current)) or Supervisor.contains_atom(additions, id, 0, List.length(additions))
          next_collected = case queued {
            true -> List.push(collected, id)
            false -> collected
          }
          Supervisor.merge_pending_walk(specs, current, additions, index + 1, total, next_collected)
        }
      false -> collected
    }
  }

  @doc = """
    Whether `target` appears in `atoms`. Internal.
    """

  fn contains_atom(atoms :: List(Atom), target :: Atom, index :: i64, total :: i64) -> Bool {
    case index < total {
      true ->
        case List.at(atoms, index) == target {
          true -> true
          false -> Supervisor.contains_atom(atoms, target, index + 1, total)
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
