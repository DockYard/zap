@doc = """
  Options for a `SocketServer` acceptor loop.

  - `accept_poll_ms` — the bounded-`accept` deadline the acceptor loops on
    (`Socket.accept(listener, accept_poll_ms)`). It is NOT a connection timeout:
    it is how often the acceptor WAKES from a quiet `accept` to reap dead handlers
    and observe a cooperative `:shutdown`. A trapping acceptor parked in an
    infinite `accept` would never see a trapped signal (a trapped signal sets no
    pending-kill), so the poll deadline is what makes shutdown responsive. Small
    values (25–100 ms) trade a little idle wakeup for prompt shutdown.
  - `max_connections` — the admission cap (Job 5 seam; `0` = unbounded). Present
    now so the options shape is stable; the shed-at-capacity policy lands later.
  - `shutdown_timeout_ms` — the drain grace period (Job 4 seam) an acceptor will
    give in-flight handlers before force-killing stragglers. Present now; the
    coordinated drain lands later.

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
        true  -> stop                                    # leave the loop (Job 4 adds the drain)
        false ->
          case Socket.accept(listener, state.options.accept_poll_ms) {
            Result.Ok(conn) ->
              {
                handler = Process.spawn_link(&MyServer.handler_entry/0)
                _moved  = Process.send_move((Pid.of(handler) :: Pid(Socket)), conn)
                loop(SocketServer.admitted(state, handler))
              }
            Result.Error(_e) -> loop(state)              # :etimedout on a quiet poll — just re-loop
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

  Coordinated graceful drain (`shutdown_timeout_ms`) and admission capping
  (`max_connections`) are later jobs; their fields already exist on
  `SocketServerOptions` so the shape is stable.
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
