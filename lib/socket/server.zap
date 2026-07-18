@doc = """
  Options for a `SocketServer` acceptor loop.

  - `accept_poll_ms` — the bounded-`accept` deadline the acceptor loops on
    (`Socket.accept(listener, accept_poll_ms)`). It is NOT a connection timeout:
    it is how often the acceptor WAKES from a quiet `accept` to reap dead handlers
    and observe a cooperative `:shutdown`. A trapping acceptor parked in an
    infinite `accept` would never see a trapped signal (a trapped signal sets no
    pending-kill), so the poll deadline is what makes shutdown responsive. Small
    values (25–100 ms) trade a little idle wakeup for prompt shutdown.
  - `max_connections` — the per-acceptor admission cap (`0` = unbounded). At the
    cap the acceptor STOPS ACCEPTING (`SocketServer.at_capacity?` /
    `wait_for_slot`), resuming only when a handler EXIT frees a slot — the Job 5
    Ranch-style load-shedding, so a burst is absorbed by the kernel backlog
    rather than accepted-then-reset.
  - `shutdown_timeout_ms` — the drain grace period (`SocketServer.drain`) an
    acceptor gives its in-flight handlers to finish before force-killing the
    stragglers — the Job 4 coordinated graceful drain.

  Build with `SocketServer.options/3` or `SocketServer.default_options/0`.
  """

@available_on(:network)

pub struct SocketServerOptions {
  accept_poll_ms :: i64
  max_connections :: i64
  shutdown_timeout_ms :: i64
}

@doc = """
  The live state of a `SocketServer` acceptor loop, threaded through the user's
  loop as plain data (no function values — the same inverted-control constraint
  `Supervisor` lives under).

  - `live_pids` — the raw pid bits of the handlers currently serving a
    connection. A handler is added by `SocketServer.admitted` when the acceptor
    `spawn_link`s + `send_move`s it a connection, and removed by
    `SocketServer.reap_signals` when its EXIT signal is reaped. Its length is the
    live connection count (`SocketServer.live_count`).
  - `draining` — set once `reap_signals` observes a shutdown order (an exit signal
    from a NON-handler — the supervisor or parent terminating the acceptor). The
    user's loop reads it (`SocketServer.draining?`) to leave the accept loop.
  - `options` — the fixed `SocketServerOptions`, carried so the loop can read
    `accept_poll_ms` from state and the Job 4/5 policies (drain, capacity) have a
    single source once they land.

  Construct with `SocketServer.init`; evolve it only through
  `SocketServer.admitted` and `SocketServer.reap_signals`.
  """

@available_on(:network)

pub struct SocketServerState {
  live_pids :: List(u64)
  draining :: Bool
  options :: SocketServerOptions
}

@doc = """
  `SocketServer` — the pure POLICY half of the acceptor/handler server pattern,
  written in Zap over the process signal intrinsics, mirroring `Supervisor`'s
  inverted-control style. It is NOT a runtime primitive and it does NOT own the
  loop: a function value cannot be stored or threaded in Zap, so `SocketServer`
  owns the data transforms (`init`, `admitted`, `reap_signals`, the accessors)
  and YOUR acceptor process owns the ~20-line loop that actually `accept`s,
  `spawn_link`s a handler, and `send_move`s it the connection.

  ## The acceptor/handler topology

  A supervised ACCEPTOR process OWNS the listener and TRAPS EXITS — it is the
  connection mini-supervisor. It loops:

      state = SocketServer.reap_signals(state)          # reap dead handlers / see shutdown
      case SocketServer.draining?(state) {
        true  ->                                          # drain (Job 4): close the listener so
          {                                               # new connects are refused, then let the
            _closed  = SocketListener.close(listener)     # in-flight handlers finish (grace) and
            _drained = SocketServer.drain(state)          # force-kill any stragglers, then exit.
            Process.exit_with(:normal)
          }
        false ->
          case SocketServer.at_capacity?(state) {         # capacity (Job 5): at the cap, STOP
            true  -> loop(SocketServer.wait_for_slot(state))  # ACCEPTING — park until a slot frees.
            false ->
              case Socket.accept(listener, state.options.accept_poll_ms) {
                Result.Ok(conn) ->
                  {
                    handler = Process.spawn_link(&MyServer.handler_entry/0)
                    _moved  = Process.send_move((Pid.of(handler) :: Pid(Socket)), conn)
                    loop(SocketServer.admitted(state, handler))
                  }
                Result.Error(_e) -> loop(state)           # :etimedout on a quiet poll — just re-loop
              }
          }
      }

  Each accepted `Socket` is handed to a FRESH handler by `Process.send_move`
  (`controlling_process` — owner-executed handoff); the handler ADOPTS it with a
  top-level `receive Socket { s -> s }` and serves it. Handlers do NOT trap: a
  handler crash arrives at the acceptor as an EXIT signal, is reaped by
  `reap_signals` (dropping it from `live_pids`), and NEVER propagates — one bad
  connection cannot take down the server, and its socket fd is reclaimed by the
  handler's teardown sweep.

  ## Blast radius (honest S3 scope)

  Because handlers are `spawn_link`ed to the ACCEPTOR (not a separate connection
  supervisor), a HANDLER crash is isolated, but an ACCEPTOR crash kills its
  linked handlers and every connection fd is reclaimed with it. The Ranch-style
  separate connection-supervisor (handlers survive an acceptor restart) needs a
  dynamic-children supervisor variant and is future work; the acceptor here is a
  `:permanent` child of an ordinary `Supervisor`, so an acceptor crash is
  restarted by the tree (a fresh listener + acceptor), not silently lost.

  ## Graceful drain and admission capping

  Two policies extend the loop:

  - **Drain (Job 4)** — when the acceptor observes a shutdown order it CLOSES
    the listener (new connects get `ECONNREFUSED`), then `SocketServer.drain`
    gives the in-flight handlers up to `shutdown_timeout_ms`
    (`wait_for_handlers`) to finish and force-kills any stragglers
    (`force_close_stragglers`) so every connection fd is reclaimed before it
    exits.
  - **Capacity (Job 5)** — with a non-zero `max_connections`, the acceptor
    checks `SocketServer.at_capacity?` before accepting; at the cap it parks in
    `wait_for_slot` (STOP ACCEPTING) until a handler EXIT frees a slot, so served
    concurrency never exceeds the cap and bursts are absorbed by the kernel
    backlog rather than accepted-then-reset.
  """

@available_on(:network)

pub struct SocketServer {
  @doc = """
    A `SocketServerOptions` from all three fields.
    """

  @available_on(:network)

  pub fn options(accept_poll_ms :: i64, max_connections :: i64, shutdown_timeout_ms :: i64) -> SocketServerOptions {
    %SocketServerOptions{accept_poll_ms: accept_poll_ms, max_connections: max_connections, shutdown_timeout_ms: shutdown_timeout_ms}
  }

  @doc = """
    Sensible defaults: a 50 ms accept poll (prompt shutdown, negligible idle
    wakeup), no connection cap (`0`), and a 5000 ms drain grace period.
    """

  @available_on(:network)

  pub fn default_options() -> SocketServerOptions {
    SocketServer.options(50, 0, 5000)
  }

  @doc = """
    Begin an acceptor loop: TRAP EXITS (so a `spawn_link`ed handler's death
    arrives as a reap-able signal instead of cascading) and return the initial
    `SocketServerState` — no live handlers, not draining. Call it at the top of
    your acceptor entry, right after it binds/adopts the listener, then drive the
    loop with `Socket.accept`, `SocketServer.admitted`, and
    `SocketServer.reap_signals`.
    """

  @available_on(:network)

  pub fn init(options :: SocketServerOptions) -> SocketServerState {
    _trapped = Process.trap_exit(true)
    %SocketServerState{live_pids: (List.new_empty(8) :: List(u64)), draining: false, options: options}
  }

  @doc = """
    Record that a handler `pid` was `spawn_link`ed and handed a connection —
    call it right after `Process.send_move`ing the accepted `Socket` to the
    handler. Adds `pid` to the live set; its EXIT is later reaped by
    `reap_signals`.
    """

  @available_on(:network)

  pub fn admitted(state :: SocketServerState, pid :: u64) -> SocketServerState {
    %SocketServerState{live_pids: List.push(state.live_pids, pid), draining: state.draining, options: state.options}
  }

  @doc = """
    Non-blocking drain of every pending signal (via `await_signal_timeout(0)` —
    the zero-deadline probe that never parks), folding each into state:

    - an exit from a LIVE handler (its pid is in `live_pids`) — that connection
      ended (a clean finish or a crash); drop it from the live set. A crashed
      handler's socket fd is reclaimed by its own teardown sweep, so no cleanup
      is needed here.
    - an exit from anything ELSE (the supervisor or parent terminating the
      acceptor) — a shutdown order; set `draining`. The loop reads it via
      `draining?` and leaves the accept loop.

    Recurses until the probe finds no pending signal, so a burst of handler
    deaths is fully reaped in one call. Call it once per loop turn (the bounded
    `accept` poll bounds how long a signal waits to be seen).
    """

  @available_on(:network)

  pub fn reap_signals(state :: SocketServerState) -> SocketServerState {
    case :zig.ProcessRuntime.await_signal_timeout(0) {
      false -> state
      true ->
        {
          from = Process.last_signal_from()
          next = case SocketServer.contains_pid(state.live_pids, from, 0, List.length(state.live_pids)) {
            true -> SocketServer.retire(state, from)
            false -> SocketServer.mark_draining(state)
          }
          SocketServer.reap_signals(next)
        }
    }
  }

  @doc = """
    Whether the acceptor has observed a shutdown order (`reap_signals` set
    `draining`). The loop tests this each turn and leaves the accept loop when
    true.
    """

  @available_on(:network)

  pub fn draining?(state :: SocketServerState) -> Bool {
    state.draining
  }

  @doc = """
    The number of handlers currently serving a connection (the length of the
    live set) — the live connection count, and the value a `max_connections`
    admission cap will compare against.
    """

  @available_on(:network)

  pub fn live_count(state :: SocketServerState) -> i64 {
    List.length(state.live_pids)
  }

  @doc = """
    Whether the acceptor is at its `max_connections` admission cap — the Job 5
    load-shedding gate. A `max_connections` of `0` (or any non-positive
    sentinel) means UNBOUNDED, so this is always `false` and the acceptor never
    sheds. Otherwise it is `true` once the live handler count
    (`live_count`) has reached the cap.

    An acceptor that finds itself `at_capacity?` must NOT `accept` — accepting
    would admit a `(cap + 1)`th connection. Instead it parks in
    `SocketServer.wait_for_slot` until a handler EXIT frees a slot. This is the
    Ranch "stop accepting at the cap" model: the kernel `listen` backlog absorbs
    inbound bursts and the OS refuses only what overflows the backlog, so a
    connection is never accepted-then-immediately-reset (no accept/RST churn).
    """

  @available_on(:network)

  pub fn at_capacity?(state :: SocketServerState) -> Bool {
    case state.options.max_connections <= 0 {
      true -> false
      false -> SocketServer.live_count(state) >= state.options.max_connections
    }
  }

  @doc = """
    Park (once, up to the `accept_poll_ms` poll quantum) waiting for a slot to
    free when the acceptor is `at_capacity?` — the Job 5 shed-by-not-accepting
    step. Call it INSTEAD of `Socket.accept` while at capacity; the loop then
    re-checks `draining?`/`at_capacity?` and only `accept`s once a slot is free.

    It blocks on the same zero-user-message timed signal wait the rest of the
    policy uses (`await_signal_timeout`), so it stays BOTH kill-responsive and
    drain-responsive while parked at the cap:

    - a handler EXIT (`from` in `live_pids`) — a connection ended, freeing a
      slot: drop it from the live set (the next loop turn is now under the cap
      and `accept`s the backlogged connection);
    - anything else (the supervisor or parent terminating the acceptor) — a
      shutdown order even while parked at capacity: set `draining` so the loop
      leaves the accept path and drains;
    - no signal within the poll — return unchanged; the loop re-checks and
      parks again (bounded, so a kill/shutdown is still observed promptly).
    """

  @available_on(:network)

  pub fn wait_for_slot(state :: SocketServerState) -> SocketServerState {
    case :zig.ProcessRuntime.await_signal_timeout(state.options.accept_poll_ms) {
      false -> state
      true ->
        {
          from = Process.last_signal_from()
          case SocketServer.contains_pid(state.live_pids, from, 0, List.length(state.live_pids)) {
            true -> SocketServer.retire(state, from)
            false -> SocketServer.mark_draining(state)
          }
        }
    }
  }

  @doc = """
    Perform the coordinated graceful DRAIN (Job 4), run BY the acceptor once it
    has observed a shutdown order and CLOSED its listener (so no new connections
    are accepted). The sequence:

    1. `wait_for_handlers` — give the live handlers up to `shutdown_timeout_ms`
       (an ABSOLUTE monotonic deadline) to finish on their own, consuming each
       handler EXIT and dropping it from the live set as it arrives;
    2. `force_close_stragglers` — for every handler STILL live at the deadline,
       send an untrappable `Process.kill`, so each victim's teardown sweep closes
       its connection fd, then reap its exit.

    Returns the final state with an empty live set. The acceptor then exits;
    because handlers were `spawn_link`ed to it, this drain (kill + reap) is the
    graceful path, and an acceptor that itself blows its supervisor's shutdown
    budget is the backstop — its `:killed` propagates down the links and every
    handler's drop-list still closes its fd.
    """

  @available_on(:network)

  pub fn drain(state :: SocketServerState) -> SocketServerState {
    deadline = Process.monotonic_millis() + state.options.shutdown_timeout_ms
    waited = SocketServer.wait_for_handlers(state, deadline)
    SocketServer.force_close_stragglers(waited)
  }

  @doc = """
    Wait until `deadline_ms` (an ABSOLUTE `Process.monotonic_millis` instant)
    for the live handlers to finish, consuming each handler EXIT and dropping it
    from the live set. Returns as soon as the live set empties (every connection
    finished within the grace) or the deadline passes (whatever handlers remain
    are the stragglers `force_close_stragglers` will kill). The Job 4 grace step.

    Built on the same timed signal wait `Supervisor.wait_exit` uses: a handler
    EXIT (`from` in `live_pids`) retires that pid; any other signal that arrives
    mid-drain (a second shutdown order) is ignored — the acceptor is already
    draining. The remaining time is recomputed each turn against the absolute
    deadline, so a burst of finishing handlers can never extend the grace.
    """

  @available_on(:network)

  pub fn wait_for_handlers(state :: SocketServerState, deadline_ms :: i64) -> SocketServerState {
    case SocketServer.live_count(state) <= 0 {
      true -> state
      false ->
        {
          remaining = deadline_ms - Process.monotonic_millis()
          case remaining <= 0 {
            true -> state
            false ->
              case :zig.ProcessRuntime.await_signal_timeout(remaining) {
                false -> state
                true ->
                  {
                    from = Process.last_signal_from()
                    next = case SocketServer.contains_pid(state.live_pids, from, 0, List.length(state.live_pids)) {
                      true -> SocketServer.retire(state, from)
                      false -> state
                    }
                    SocketServer.wait_for_handlers(next, deadline_ms)
                  }
              }
          }
        }
    }
  }

  @doc = """
    Force-close every handler still live after the drain grace — the Job 4
    straggler step. Sends an untrappable `Process.kill` to ALL remaining
    handlers FIRST, then reaps exactly one exit per handler. Killing every
    victim before reaping any is what makes the reap sound even when a straggler
    happens to die on its own in the same instant: each killed (and linked)
    handler delivers exactly one EXIT, so reaping until every victim pid is
    accounted for consumes them all — a stray signal from a non-handler is
    simply skipped and re-awaited, never mistaken for a victim. Each victim's
    teardown sweep closes its connection fd (crash-safe fd lifetime), so no
    connection leaks. Returns the state with an empty live set.
    """

  @available_on(:network)

  pub fn force_close_stragglers(state :: SocketServerState) -> SocketServerState {
    victims = state.live_pids
    _killed = SocketServer.kill_all(victims, 0, List.length(victims))
    _reaped = SocketServer.reap_all(victims)
    %SocketServerState{live_pids: (List.new_empty(8) :: List(u64)), draining: state.draining, options: state.options}
  }

  @doc = """
    Send an untrappable `Process.kill` to every pid in `pids[index, total)`.
    Internal to `force_close_stragglers`.
    """

  fn kill_all(pids :: List(u64), index :: i64, total :: i64) -> Bool {
    case index < total {
      true ->
        {
          _k = Process.kill(List.at(pids, index))
          SocketServer.kill_all(pids, index + 1, total)
        }
      false -> true
    }
  }

  @doc = """
    Reap exactly one exit signal for each pid still in `remaining` (blocking on
    `await_signal` — every killed, linked handler is guaranteed to deliver its
    exit), removing each reaped pid. A signal from a pid NOT in `remaining` (a
    stray) leaves the set unchanged and is re-awaited. Terminates once the set
    is empty. Internal to `force_close_stragglers`.
    """

  fn reap_all(remaining :: List(u64)) -> Bool {
    case List.empty?(remaining) {
      true -> true
      false ->
        {
          _r = Process.await_signal()
          from = Process.last_signal_from()
          SocketServer.reap_all(SocketServer.list_without(remaining, from, 0, List.length(remaining), (List.new_empty(List.length(remaining)) :: List(u64))))
        }
    }
  }

  @doc = """
    Return `state` with `pid` removed from the live set. Internal to
    `reap_signals`.
    """

  fn retire(state :: SocketServerState, pid :: u64) -> SocketServerState {
    %SocketServerState{live_pids: SocketServer.list_without(state.live_pids, pid, 0, List.length(state.live_pids), (List.new_empty(List.length(state.live_pids)) :: List(u64))), draining: state.draining, options: state.options}
  }

  @doc = """
    Return `state` with `draining` set. Internal to `reap_signals`.
    """

  fn mark_draining(state :: SocketServerState) -> SocketServerState {
    %SocketServerState{live_pids: state.live_pids, draining: true, options: state.options}
  }

  @doc = """
    Whether `target` raw pid bits appear in `pids[index, total)`. Internal.
    """

  fn contains_pid(pids :: List(u64), target :: u64, index :: i64, total :: i64) -> Bool {
    case index < total {
      true ->
        case List.at(pids, index) == target {
          true -> true
          false -> SocketServer.contains_pid(pids, target, index + 1, total)
        }
      false -> false
    }
  }

  @doc = """
    Copy `pids[index, total)` into `collected`, skipping every occurrence of
    `target` — the live set with one handler removed. Internal.
    """

  fn list_without(pids :: List(u64), target :: u64, index :: i64, total :: i64, collected :: List(u64)) -> List(u64) {
    case index < total {
      true ->
        {
          pid = List.at(pids, index)
          next_collected = case pid == target {
            true -> collected
            false -> List.push(collected, pid)
          }
          SocketServer.list_without(pids, target, index + 1, total, next_collected)
        }
      false -> collected
    }
  }
}
