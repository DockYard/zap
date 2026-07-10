@doc = """
  Lightweight processes: spawn, typed message passing, and the raw
  receive primitive (concurrency plan Phase 2, item 2.7).

  ## The concurrency runtime gate

  Every operation here requires the concurrency runtime, which is
  compiled into a binary only when the build resolves the
  `runtime_concurrency` gate ON (`runtime_concurrency: true` in the
  `Zap.Manifest`, or `-Druntime-concurrency=on`). Calling any
  `Process` function in a gate-off build is a compile error; the gate
  defaults OFF so non-concurrent binaries pay nothing.

  In a gated-on binary, user `main` runs as the ROOT PROCESS of the
  runtime: the program's lifetime is the root's lifetime (Erlang halt
  semantics — when `main` returns, processes still running are torn
  down wholesale at exit), and `Process.self`/`send`/`receive_raw`
  work in `main` exactly as in any spawned process.

  ## What can travel in a message

  Scalars (`i64`, `u64`, `f64`, `Bool`, `Atom` — atoms as their
  binary-global table ids) travel as fixed-size payloads. Rich values
  — `String`, `List`/`Map` of sendable elements, and by-value structs
  of those — travel by DEEP COPY: the sender serializes the value graph
  into a neutral blob (reading its own data only, never mutating a
  refcount), and the receiver reconstructs a fresh, INDEPENDENT copy it
  solely owns (plan item 2.4, the P2-J5 walker). So the sender and
  receiver never share a mutable cell, and dropping either side's value
  leaves the other intact. Still UNSENDABLE (a compile error, never a
  silent truncation): closures / `Callable` existentials (the captured
  environment is opaque — Phase 3's per-closure serialize glue),
  payload-bearing or parametric unions, and values holding external
  resource handles. Raw pid bits are a `u64`, so a reply channel is
  handed to a child by sending `Process.self()` and re-typing it with
  `Process.pid`/`Pid.of` on the other side.

  ## Spawn scope

  `Process.spawn` accepts a named (or capture-less) zero-parameter
  function — the shapes that lower to a bare function pointer. A
  closure with a captured environment would share the spawner's heap
  into the child unsafely without the P2-J5 walker, so it is rejected
  at compile time. Single-argument `Process.spawn(entry)` runs the
  child under the manifest memory manager. Per-spawn memory managers
  ARE live: the two-argument `Process.spawn(entry, ManagerType)` form
  (below) binds a comptime-resolved manager AT THE SPAWN SITE — this
  is Decision Gate 0, landed in Phase 3 (plan item 3.1, P3-J3). The
  chosen manager's reclamation model is monomorphized into the
  spawn-reachable call graph and recorded in the child's pid bits.

  ## Raw receive

  `Process.receive_raw(t)` blocks until a message arrives and decodes
  it as `t`. It TRUSTS the caller: the compiler cannot yet prove the
  mailbox only carries `t`, and a size mismatch between sender and
  receiver aborts at runtime rather than fabricating bytes. The
  `receive`/`after` LANGUAGE CONSTRUCT (plan item 2.3, P2-J3) is the
  surface for ordinary code: `receive <t> { <pattern> -> <body> … }`
  blocks, takes the oldest USER message, decodes it as the same fixed
  scalar transport, and dispatches by pattern match (with an optional
  `after <ms> -> <body>` timeout arm). Signal envelopes (a trapped
  `{'EXIT', …}` or a `{'DOWN', …}`) are NOT user messages: every
  receive surface skips them, leaving them queued in order for
  `await_signal` (Erlang: an unmatched trapped exit sits in the
  mailbox). Compiler-inferred per-process message unions and
  exhaustiveness (plan item 2.2, P2-J4) will make its explicit `<t>`
  token optional and prove every arm reachable.

  ## Examples

      pub fn echo_entry() -> Nil {
        parent = Process.pid(i64, Process.receive_raw(u64))
        value = Process.receive_raw(i64)
        _sent = Process.send(parent, value)
        nil
      }

      child = Process.pid(u64, Process.spawn(&MyServer.echo_entry/0))
      _hello = Process.send(child, Process.self())
      _ping = Process.send(Process.pid(i64, child.raw), 42)
      Process.receive_raw(i64)   # => 42

  """

pub struct Process {
  @doc = """
    The calling process's pid as its raw `u64` kernel bits. Nonzero
    for every live process (zero is the never-issued invalid pid).
    Type the bits with `Process.pid` to build a sendable handle:
    `Process.pid(i64, Process.self())` is this process's typed reply
    channel for `i64` messages.
    """

  pub fn self() -> u64 {
    :zig.ProcessRuntime.self_pid_bits()
  }

  @doc = """
    The calling process's current MONOTONIC time in milliseconds, read through
    the scheduler's clock — the SAME clock that drives `receive`'s `after`
    deadlines. The epoch is unspecified: only the DIFFERENCE between two reads is
    meaningful (elapsed milliseconds). The value never decreases within a run, so
    it is safe for measuring intervals (unlike a wall clock, it does not jump on
    NTP/DST adjustments). Under the seeded deterministic scheduler it reads the
    virtual clock, so interval-based policy — e.g. a `Supervisor`'s restart-
    intensity window — is reproducible under a seed.

    ## Example

        started = Process.monotonic_millis()
        _work = do_something()
        elapsed = Process.monotonic_millis() - started
    """

  pub fn monotonic_millis() -> i64 {
    :zig.ProcessRuntime.monotonic_millis()
  }

  @doc = """
    Spawns a new process running `entry` under the manifest memory
    manager and returns the child's raw pid bits (type them with
    `Process.pid`). The child starts with an empty mailbox; hand it
    state — including a reply channel — by sending messages. Aborts
    the program if the process table is exhausted or the runtime is
    out of memory.

    Scope: `entry` must be a named (or capture-less) zero-parameter
    function; closures with captured environments are rejected at
    compile time (see the struct doc). This single-argument form runs
    the child under the manifest memory manager; to bind a per-spawn
    manager, use the two-argument `Process.spawn(entry, ManagerType)`
    form below (Decision Gate 0, landed in Phase 3 — plan item 3.1).
    """

  pub fn spawn(entry :: fn() -> Nil) -> u64 {
    :zig.ProcessRuntime.spawn_process(entry)
  }

  @doc = """
    Spawns `entry` under the given memory manager — comptime-resolved AT THE
    SPAWN SITE (Decision Gate 0). `Process.spawn(entry, Memory.Arena)` runs the
    child on its OWN private `Memory.Arena` heap: its allocations use the Arena
    reclamation model's codegen (individual frees elided; the whole heap
    bulk-freed wholesale when the process exits), while a `Memory.ARC` process
    reclaims per-drop. No manager (`Process.spawn(entry)`) means the manifest
    default manager. The child's pid carries the chosen manager's
    reclamation-model bits (readable from the raw pid — model at bits 54..55).

    The manager MUST be a comptime-known type implementing `Memory.Manager`
    (`Memory.ARC`, `Memory.Arena`, `Memory.NoOp`, `Memory.Leak`,
    `Memory.Tracking`, `Memory.GC`, or a third-party manager) — pass the type
    directly as the second argument, exactly the first-class `Type` value form.
    A runtime (non-comptime) manager is a COMPILE ERROR: the manager selects the
    process's reclamation model and per-process codegen, so it cannot be a
    threaded runtime value. `entry` is the same named/capture-less zero-parameter
    function `Process.spawn/1` accepts.

    The manager is monomorphized into the spawn-reachable call graph, so hot
    allocating paths carry NO per-allocation dispatch; a manager backend that is
    unsound on the target (e.g. a conservative-tracing manager on WebAssembly)
    is a spawn-time error while the backend stays linkable for the managers this
    binary CAN use there.
    """

  pub macro spawn(entry :: Expr, manager :: Expr) -> Expr {
    quote {
      :zig.ProcessRuntime.spawn_process_managed(unquote(entry), unquote(manager))
    }
  }

  @doc = """
    Spawns `entry` and ATOMICALLY links the calling process to the child, as one
    indivisible operation (Erlang `spawn_link`): the link is established BEFORE
    the child can run, so a child that exits immediately still propagates its
    exit to the parent — there is no race window a plain `spawn` then `link`
    would have (where the child could exit before the link, delivering a `:noproc`
    instead of the child's real reason). Returns the child's raw pid bits.

    Because the link is bidirectional, an abnormal child exit cascades to a
    non-trapping parent (both die), and a trapping parent instead receives an
    `{'EXIT', Child, Reason}` message. `entry` is the same named/capture-less
    zero-parameter function `Process.spawn/1` accepts. This is the ergonomic
    layer over the raw `Process.link` primitive.
    """

  pub fn spawn_link(entry :: fn() -> Nil) -> u64 {
    # Register the kernel reason atoms BEFORE the link exists: a child that
    # exits immediately must deliver its real reason atom (e.g. `:normal`),
    # not the unregistered term, even when this spawn is the program's first
    # signal operation.
    _registered = ensure_reason_atoms_registered()
    :zig.ProcessRuntime.spawn_link_process(entry)
  }

  @doc = """
    Spawns `entry` and ATOMICALLY installs a monitor from the calling process on
    the child, returning `{pid, ref}` (Erlang `spawn_monitor`): the monitor is
    established BEFORE the child can run, so a child that exits immediately still
    fires a `{'DOWN', ref, :process, pid, reason}` carrying its REAL exit reason
    (not `:noproc`, which a racy `spawn` then `monitor` could deliver). The
    returned `ref` is the monitor reference to match the eventual `DOWN` against
    (`Process.last_signal_ref` after `Process.await_signal`); the returned `pid`
    is the child's raw bits (type them with `Process.pid`).

    Unlike a link, a monitor is unidirectional and never kills the monitoring
    process — it only delivers the `DOWN` message. `entry` is the same
    named/capture-less zero-parameter function `Process.spawn/1` accepts.
    """

  pub fn spawn_monitor(entry :: fn() -> Nil) -> {u64, u64} {
    # Register the kernel reason atoms BEFORE the monitor exists: a child
    # that exits immediately must fire a `DOWN` carrying its real reason
    # atom (e.g. `:normal`), not the unregistered term, even when this
    # spawn is the program's first signal operation.
    _registered = ensure_reason_atoms_registered()
    pid = :zig.ProcessRuntime.spawn_monitor_process(entry)
    ref = :zig.ProcessRuntime.spawn_monitor_ref()
    {pid, ref}
  }

  @doc = """
    Runs the blocking (or long-running) computation `entry` on the dirty-
    scheduler pool and returns its `i64` result — the `Process.blocking`
    intrinsic (concurrency plan Phase 4, item 4.3).

    Zap runs green processes M:N over a small set of core scheduler threads. A
    native call that BLOCKS — a crypto routine, a database driver, `getaddrinfo`,
    or any long CPU-bound leaf — holds its core for its whole duration, stalling
    every other green process co-scheduled on that core, exactly as an over-long
    BEAM NIF stalls a scheduler. `Process.blocking(&Slow.work/0)` avoids that: it
    moves the calling process's fiber onto a DEDICATED blocking-pool OS thread for
    the duration of `work`, freeing the core to run its other processes; when
    `work` returns, the process re-attaches onto a core and this call yields its
    result. This is BEAM's dirty schedulers / Go's syscall handoff / Tokio's
    `spawn_blocking`, in Zap.

    Contract: `entry` is a named (or capture-less) zero-parameter function
    returning `i64`, and it must be a LEAF — it runs off-core, so it must not
    itself `spawn`, `send`, `receive`, or otherwise re-enter the process runtime
    (a blocking FFI call or a pure computation is exactly right). Un-annotated
    blocking calls are NOT rewritten automatically: calling a blocking primitive
    WITHOUT `Process.blocking` stalls the core (the honest BEAM-parity contract) —
    wrapping it in `Process.blocking` is how you keep the scheduler responsive.

    ## Example

        pub fn hash_rounds() -> i64 {
          # a long CPU-bound leaf — runs on the blocking pool, off the core
          Crypto.pbkdf2_cost(1_000_000)
        }

        digest = Process.blocking(&MyServer.hash_rounds/0)

    """

  pub fn blocking(entry :: fn() -> i64) -> i64 {
    :zig.ProcessRuntime.blocking_i64(entry)
  }

  @doc = """
    Sends `message` to a process, addressed EITHER by a typed pid handle OR by a
    registered name (an atom) — the `send/2` family.

    `Process.send(pid :: Pid(m), message :: m)` sends to the process behind `pid`,
    type-checked against the handle's message type. `Process.send(name :: Atom,
    message)` is send-by-NAME: it resolves `name` through `Process.whereis` then
    delivers to the registered process (the common "named server" send); it is
    UNTYPED (a registered name carries no message type), so the caller is
    responsible for sending a value the named process expects.

    Both forms return `true` when the message was enqueued on a live mailbox and
    `false` when it was dead-lettered (the target has exited, the pid is stale, or
    the name is unregistered — Erlang semantics: not an error). The message type
    must be sendable (struct doc): a scalar, `String`, `List`/`Map`, or a by-value
    struct of those — a rich value is deep-copied so the receiver gets an
    independent copy. An unsendable type (a closure, a payload-bearing union) is a
    compile error.
    """

  pub fn send(pid :: Pid(message_type), message :: message_type) -> Bool {
    :zig.ProcessRuntime.send_message(pid.raw, message)
  }

  pub fn send(name :: Atom, message :: message_type) -> Bool {
    case :zig.ProcessRuntime.whereis(name) {
      0 -> false
      resolved -> Process.send((Pid.of(resolved) :: Pid(message_type)), message)
    }
  }

  @doc = """
    Sends `message` to `pid` by MOVE, CONSUMING it — the same-model O(1)
    region-move send. Unlike `send` (which deep-copies), `send_move` transfers
    ownership of the value to the receiver: when the value is uniquely owned
    (rc == 1), region-closed, and its backing is relocatable, the sender
    re-parents the whole subgraph to a same-model receiver in O(1) with NO copy
    — the fix for the deep-copy cost of large payloads. Every other case (an
    aliased value, a cross-model receiver, a non-relocatable backing) degrades
    transparently to the copy `send`; the result is identical, only the cost
    differs.

    `send_move` CONSUMES `message`: after `Process.send_move(pid, value)`, using
    `value` again is a use-after-move compile error (the value now belongs to
    the receiver). Returns `true` when enqueued on a live mailbox, `false` when
    dead-lettered (Erlang semantics). The message type and sendability rules are
    exactly `send`'s; a value that is not move-eligible is not an error — it
    simply copies.
    """

  pub fn send_move(pid :: Pid(message_type), message :: unique message_type) -> Bool {
    :zig.ProcessRuntime.send_message_moved(pid.raw, message)
  }

  @doc = """
    Registers the CALLING process in the local registry under `name` (an atom),
    the "named server" pattern — thereafter `Process.whereis(name)` resolves to
    this process and `Process.send(name, msg)` reaches it. Returns `true` on
    success, or `false` when the name is already held by another LIVE process, or
    when this process already holds a name (Erlang/Elixir: a process may hold at
    most ONE registered name). The registration is RELEASED AUTOMATICALLY when
    this process exits or crashes (the classic register-then-crash race: the name
    becomes free again on teardown), and it can be released early with
    `Process.unregister`.
    """

  pub fn register(name :: Atom) -> Bool {
    :zig.ProcessRuntime.register_name(name)
  }

  @doc = """
    Releases `name` if the calling process holds it (idempotent — unregistering a
    name this process does not hold is a `false`-returning no-op). Returns whether
    a registration was removed. A process's name is also released automatically at
    its teardown, so explicit `unregister` is only needed to free a name while the
    process keeps running.
    """

  pub fn unregister(name :: Atom) -> Bool {
    :zig.ProcessRuntime.unregister_name(name)
  }

  @doc = """
    Resolves `name` to the raw pid bits of its LIVE registrant, or `0` (the
    never-issued invalid pid) when `name` is unregistered — or registered to a
    process that has since died (the lookup is generation-validated, so a name
    pointing at a dead or reused pid resolves to `0`, never a stale process).
    Type the nonzero result with `Process.pid`/`Pid.of` to send to it; prefer the
    `Process.send(name, msg)` send-by-name form for the common case.
    """

  pub fn whereis(name :: Atom) -> u64 {
    :zig.ProcessRuntime.whereis(name)
  }

  @doc = """
    Types raw pid bits as a `Pid(t)` handle for the given message
    type token: `Process.pid(i64, bits)` returns a `Pid(i64)`. Tokens
    cover exactly the Phase 2 sendable set: `i64`, `u64`, `f64`,
    `Bool`, `Atom`. This is the untyped escape hatch documented on
    `Pid`: the stamp is an unchecked assertion about what the target
    process expects, used to re-type `Process.spawn`/`Process.self`
    bits and pids received inside messages.
    """

  pub macro pid(i64, raw_bits_expression :: Expr) -> Expr {
    quote { Process.pid_of_i64(unquote(raw_bits_expression)) }
  }

  pub macro pid(u64, raw_bits_expression :: Expr) -> Expr {
    quote { Process.pid_of_u64(unquote(raw_bits_expression)) }
  }

  pub macro pid(f64, raw_bits_expression :: Expr) -> Expr {
    quote { Process.pid_of_f64(unquote(raw_bits_expression)) }
  }

  pub macro pid(Bool, raw_bits_expression :: Expr) -> Expr {
    quote { Process.pid_of_bool(unquote(raw_bits_expression)) }
  }

  pub macro pid(Atom, raw_bits_expression :: Expr) -> Expr {
    quote { Process.pid_of_atom(unquote(raw_bits_expression)) }
  }

  @doc = """
    Blocks until a message arrives, then decodes it as the given type
    token and returns it: `Process.receive_raw(i64)` parks the calling
    process until its mailbox is nonempty and yields the oldest message
    as an `i64`. Tokens cover the fixed scalar transport (`i64`, `u64`,
    `f64`, `Bool`, `Atom`). RAW primitive — the type is trusted, not
    checked (struct doc); a payload whose size does not match the token
    aborts the program. RICH messages (`String`, `List`/`Map`, structs)
    are received through the `receive`/`after` LANGUAGE CONSTRUCT — the
    checked surface — which decodes any sendable message type through
    the deep-copy walker and dispatches by pattern (`receive <t> {
    <pattern> -> <body> … }`).
    """

  pub macro receive_raw(i64) -> Expr {
    quote { Process.receive_raw_i64() }
  }

  pub macro receive_raw(u64) -> Expr {
    quote { Process.receive_raw_u64() }
  }

  pub macro receive_raw(f64) -> Expr {
    quote { Process.receive_raw_f64() }
  }

  pub macro receive_raw(Bool) -> Expr {
    quote { Process.receive_raw_bool() }
  }

  pub macro receive_raw(Atom) -> Expr {
    quote { Process.receive_raw_atom() }
  }

  @doc = """
    Terminates the calling process NORMALLY (reason `:normal`) — the same clean
    exit as returning from its entry function. A linked NON-trapping process is
    NOT killed by a normal exit; a trapping linked/monitoring process receives
    `{'EXIT', Self, :normal}` / a `:normal` `DOWN`. Never returns. From the root
    process this ends the program with exit status 0. To exit abnormally (so a
    linked process dies or a supervisor restarts), use `Process.exit_with`.
    """

  pub fn exit() -> Never {
    :zig.ProcessRuntime.exit_process()
  }

  @doc = """
    Types raw pid bits as `Pid(i64)`. Prefer the `Process.pid(i64,
    bits)` token form; this named constructor is its expansion
    target.
    """

  pub fn pid_of_i64(raw_bits :: u64) -> Pid(i64) {
    %Pid{raw: raw_bits}
  }

  @doc = """
    Types raw pid bits as `Pid(u64)`. Prefer the `Process.pid(u64,
    bits)` token form; this named constructor is its expansion
    target.
    """

  pub fn pid_of_u64(raw_bits :: u64) -> Pid(u64) {
    %Pid{raw: raw_bits}
  }

  @doc = """
    Types raw pid bits as `Pid(f64)`. Prefer the `Process.pid(f64,
    bits)` token form; this named constructor is its expansion
    target.
    """

  pub fn pid_of_f64(raw_bits :: u64) -> Pid(f64) {
    %Pid{raw: raw_bits}
  }

  @doc = """
    Types raw pid bits as `Pid(Bool)`. Prefer the `Process.pid(Bool,
    bits)` token form; this named constructor is its expansion
    target.
    """

  pub fn pid_of_bool(raw_bits :: u64) -> Pid(Bool) {
    %Pid{raw: raw_bits}
  }

  @doc = """
    Types raw pid bits as `Pid(Atom)`. Prefer the `Process.pid(Atom,
    bits)` token form; this named constructor is its expansion
    target.
    """

  pub fn pid_of_atom(raw_bits :: u64) -> Pid(Atom) {
    %Pid{raw: raw_bits}
  }

  @doc = """
    Blocking raw receive decoded as `i64`. Prefer the
    `Process.receive_raw(i64)` token form; this named primitive is
    its expansion target.
    """

  pub fn receive_raw_i64() -> i64 {
    :zig.ProcessRuntime.receive_i64()
  }

  @doc = """
    Blocking raw receive decoded as `u64` (including raw pid bits —
    the reply-channel handshake in the struct doc). Prefer the
    `Process.receive_raw(u64)` token form; this named primitive is
    its expansion target.
    """

  pub fn receive_raw_u64() -> u64 {
    :zig.ProcessRuntime.receive_u64()
  }

  @doc = """
    Blocking raw receive decoded as `f64`. Prefer the
    `Process.receive_raw(f64)` token form; this named primitive is
    its expansion target.
    """

  pub fn receive_raw_f64() -> f64 {
    :zig.ProcessRuntime.receive_f64()
  }

  @doc = """
    Blocking raw receive decoded as `Bool`. Prefer the
    `Process.receive_raw(Bool)` token form; this named primitive is
    its expansion target.
    """

  pub fn receive_raw_bool() -> Bool {
    :zig.ProcessRuntime.receive_bool()
  }

  @doc = """
    Blocking raw receive decoded as `Atom`. Prefer the
    `Process.receive_raw(Atom)` token form; this named primitive is
    its expansion target.
    """

  pub fn receive_raw_atom() -> Atom {
    :zig.ProcessRuntime.receive_atom()
  }

  # Register the well-known reason atoms the kernel synthesizes (`:normal` for a
  # clean exit, `:killed` for a kill, `:noproc` for a dead-process address) so
  # the atom IDENTITIES live in Zap, never hardcoded in the compiler. Idempotent;
  # the signal ops below call it before first use.
  fn ensure_reason_atoms_registered() -> Bool {
    :zig.ProcessRuntime.register_reason_atoms(:normal, :killed, :noproc)
  }

  @doc = """
    Links the calling process to the process behind `target_pid` (raw pid
    bits) — a BIDIRECTIONAL, one-per-pair link (linking twice is idempotent).
    When either linked process exits abnormally, the exit signal propagates to
    the other: a non-trapping peer dies with the same reason (cascading); a
    trapping peer receives an `{'EXIT', From, Reason}` message instead. A
    `normal` exit does NOT kill a linked peer. Linking an already-dead process
    delivers a `:noproc` exit signal to the caller. Returns `true` when the link
    was established. The raw-bits surface; `spawn_link` (J2) wraps it.
    """

  pub fn link(target_pid :: u64) -> Bool {
    _registered = ensure_reason_atoms_registered()
    :zig.ProcessRuntime.link_process(target_pid)
  }

  @doc = """
    Removes the bidirectional link between the calling process and
    `target_pid` (idempotent — unlinking a non-link is a no-op). Returns
    whether a link existed on the caller's side.
    """

  pub fn unlink(target_pid :: u64) -> Bool {
    :zig.ProcessRuntime.unlink_process(target_pid)
  }

  @doc = """
    Monitors `target_pid` and returns a unique reference. UNIDIRECTIONAL and
    STACKABLE: N monitors of the same process deliver N independent
    `{'DOWN', Ref, :process, Pid, Reason}` messages when it exits. Unlike a
    link, a monitor never propagates an exit to the monitoring process — it only
    delivers a message. Monitoring an already-dead process fires a `:noproc`
    `DOWN` immediately. Drop a monitor with `demonitor(ref)`. The raw-bits
    surface; `spawn_monitor` (J2) wraps it.
    """

  pub fn monitor(target_pid :: u64) -> u64 {
    _registered = ensure_reason_atoms_registered()
    :zig.ProcessRuntime.monitor_process(target_pid)
  }

  @doc = """
    Drops the monitor identified by `ref` (from a prior `monitor`). Returns
    whether `ref` named a live monitor this process holds. A `DOWN` message
    already delivered to the mailbox is not removed (plain demonitor).
    """

  pub fn demonitor(ref :: u64) -> Bool {
    :zig.ProcessRuntime.demonitor_process(ref)
  }

  @doc = """
    Sets the calling process's `trap_exit` flag, returning the PREVIOUS value.
    With `trap_exit` set, a trappable exit signal that would otherwise kill this
    process is converted into an `{'EXIT', From, Reason}` message in its mailbox
    (read via `await_signal`) — the foundation supervisors stand on. An
    untrappable `kill` (`Process.kill`) still terminates a trapping process.
    """

  pub fn trap_exit(value :: Bool) -> Bool {
    :zig.ProcessRuntime.set_trap_exit(value)
  }

  @doc = """
    Whether the calling process currently traps exits.
    """

  pub fn traps_exits() -> Bool {
    :zig.ProcessRuntime.get_trap_exit()
  }

  @doc = """
    Sends an exit signal carrying `reason` (an atom) to `target_pid` — Erlang
    `exit/2`, with its two special reasons implemented exactly:

    - `:kill` is the UNTRAPPABLE kill: it routes to the kill path, so the
      target dies with reason `:killed` REGARDLESS of `trap_exit` (identical
      to `Process.kill`). Only `exit/2`'s literal `:kill` is untrappable — a
      `:kill` that arrives by LINK cascade (a process that died calling
      `Process.exit_with(:kill)`) is an ordinary trappable reason.
    - `:normal` does NOT kill a non-trapping target (a trapping one still
      receives `{'EXIT', From, :normal}`) — with ONE exception: sending
      `:normal` to YOURSELF while not trapping terminates the caller with
      reason `:normal` (erlang.org `exit/2`'s self-normal special case; the
      call then never returns).

    Any other reason kills a non-trapping target (which then propagates the
    reason to ITS links) or is delivered as an `{'EXIT', From, Reason}`
    message to a trapping one. Returns `true` when the target resolved (a
    signal to a dead process is a silent no-op, not an error).
    """

  pub fn exit_signal(target_pid :: u64, reason :: Atom) -> Bool {
    _registered = ensure_reason_atoms_registered()
    case reason {
      :kill -> :zig.ProcessRuntime.kill_process(target_pid)
      :normal ->
        case target_pid == Process.self() and Process.traps_exits() == false {
          true -> Process.exit()
          false -> :zig.ProcessRuntime.send_exit_signal(target_pid, false, :normal)
        }
      _ -> :zig.ProcessRuntime.send_exit_signal(target_pid, true, reason)
    }
  }

  @doc = """
    Sends the UNTRAPPABLE kill signal to `target_pid`: it terminates with reason
    `:killed` regardless of `trap_exit` (a trapping process cannot survive a
    kill). Because the target dies as `:killed` (not `:kill`), its own linked
    processes receive the ordinary trappable `:killed` reason. Returns `true`
    when the target resolved.
    """

  pub fn kill(target_pid :: u64) -> Bool {
    _registered = ensure_reason_atoms_registered()
    :zig.ProcessRuntime.kill_process(target_pid)
  }

  @doc = """
    Terminates the calling process ABNORMALLY with `reason` (an atom) — Erlang
    `exit(Reason)`. Linked non-trapping processes die with `reason`; trapping
    linked/monitoring processes receive it as a message. Never returns. For a
    clean exit use `Process.exit()`.
    """

  pub fn exit_with(reason :: Atom) -> Never {
    _registered = ensure_reason_atoms_registered()
    :zig.ProcessRuntime.exit_with_reason(reason)
  }

  @doc = """
    Blocks until the next SIGNAL message (a trapped `{'EXIT', …}` or a
    `{'DOWN', …}`) is queued, consumes the OLDEST one, and returns its reason
    as an `Atom`. Ordinary user messages are SKIPPED and stay queued, in
    order, for the typed `receive` (Erlang selective-receive semantics — a
    registered process sent unrelated user messages still observes its
    signals; the skipped messages are never consumed or reordered). The other
    fields of the just-consumed signal are read with `last_signal_from`,
    `last_signal_ref`, and `last_signal_kind`.

    This is the raw primitive a trapping/monitoring process uses to observe a
    signal. The typed `receive` construct is the mirror image: it consumes
    only USER messages, skipping queued signals (which stay queued for this
    surface) — decoding signals into `{'EXIT', from, reason}` /
    `{'DOWN', ref, pid, reason}` tuples inside `receive` is planned as
    concurrency plan item 5.5 and NOT yet available.
    """

  pub fn await_signal() -> Atom {
    :zig.ProcessRuntime.await_signal()
  }

  @doc = """
    The raw pid bits the most recently `await_signal`-consumed signal came FROM
    (the exiting process for an `{'EXIT', …}`, the monitored process for a
    `{'DOWN', …}`).
    """

  pub fn last_signal_from() -> u64 {
    :zig.ProcessRuntime.last_signal_from()
  }

  @doc = """
    The monitor reference of the most recently consumed signal (meaningful only
    for a `{'DOWN', …}`; zero for an `{'EXIT', …}`).
    """

  pub fn last_signal_ref() -> u64 {
    :zig.ProcessRuntime.last_signal_ref()
  }

  @doc = """
    The kind of the most recently consumed signal: `1` for a trapped exit
    (`{'EXIT', …}`), `2` for a monitor `DOWN` (`{'DOWN', …}`).
    """

  pub fn last_signal_kind() -> i64 {
    :zig.ProcessRuntime.last_signal_kind()
  }

  @doc = """
    The reason atom of the most recently consumed signal — the value
    `await_signal` returned, re-readable without consuming another
    signal. Also carries the reason of the `DOWN` a failed `Process.call`
    or `Task.await` consumed internally (which those surfaces re-exit
    with).
    """

  pub fn last_signal_reason() -> Atom {
    :zig.ProcessRuntime.last_signal_reason()
  }

  @doc = """
    Synchronous typed request/response against a server process — the
    GenServer-call shape (concurrency plan item 5.3, P5-J4), with the
    default 5000 ms timeout (Elixir's `GenServer.call/2`).

    `Process.call(server, request)` monitors the server, sends it a
    `Call(request_type)` envelope carrying the request plus the reply
    address, and blocks until the correlated reply arrives. The wait is
    the INTERNAL correlated receive (research §6.2's ref-trick): it finds
    the reply in O(1) from the receive-mark captured when the monitor
    reference was minted — an arbitrarily deep mailbox backlog is skipped,
    stays queued, and keeps its order for the ordinary `receive`.

    The server receives the envelope as an ordinary message of type
    `Call(request_type)` and answers with `Process.reply(call, value)`:

        # server loop
        call = receive Call(i64) { c -> c }
        _sent = Process.reply(call, call.request + 1)

    The reply type is the call expression's annotated type — bind or
    ascribe it at the call site: `sum = (Process.call(server, 41) :: i64)`.

    Failure surface (Elixir-aligned — `GenServer.call` semantics): the
    caller EXITS rather than receiving an error value. A DEAD server —
    or one that dies mid-call — is detected through the monitor
    IMMEDIATELY (a `:noproc` `DOWN` for an already-dead server, the real
    exit reason for a mid-call death), and the caller exits with that
    reason instead of hanging until the timeout; a silent-but-alive
    server exits the caller with `:timeout` when the deadline elapses.
    On every return path the monitor is dropped with FLUSH semantics, so
    no stale `DOWN` can ever poison a later `receive`.
    """

  pub fn call(server :: Pid(Call(request_type)), request :: request_type) -> reply_type {
    Process.call(server, request, 5000)
  }

  @doc = """
    `Process.call` with an explicit timeout in milliseconds. See
    `call/2` for the protocol, typing, and the Elixir-aligned failure
    surface (exit on dead server / `:timeout` on deadline).
    """

  pub fn call(server :: Pid(Call(request_type)), request :: request_type, timeout_milliseconds :: i64) -> reply_type {
    # Mark BEFORE the ref exists so even the immediately-fired :noproc
    # DOWN of a dead server lands after the mark (O(1) to find).
    _mark_prepared = :zig.ProcessRuntime.receive_mark_prepare()
    ref = Process.monitor(server.raw)
    _mark_bound = :zig.ProcessRuntime.receive_mark_bind(ref)
    envelope = %Call(request_type){request: request, reply_ref: ref, reply_to: Process.self()}
    # A dead server dead-letters the send; the monitor's :noproc DOWN
    # (not the send) is what reports it — Erlang semantics.
    _request_sent = Process.send(server, envelope)
    outcome = :zig.ProcessRuntime.await_correlated(ref, timeout_milliseconds)
    case outcome {
      0 ->
        {
          value = (:zig.ProcessRuntime.take_correlated_message() :: reply_type)
          # demonitor + flush: a server that dies right after replying
          # must not leave a late DOWN in our mailbox.
          _flushed = :zig.ProcessRuntime.demonitor_flush(ref)
          value
        }
      1 ->
        {
          # The server died before replying (or was already dead —
          # :noproc): the DOWN was consumed; exit with its reason,
          # immediately, never waiting out the timeout.
          _demonitored = Process.demonitor(ref)
          Process.exit_with(Process.last_signal_reason())
        }
      _ ->
        {
          _flushed = :zig.ProcessRuntime.demonitor_flush(ref)
          Process.exit_with(:timeout)
        }
    }
  }

  @doc = """
    Answers a `Process.call`: sends `value` back to the caller identified
    by the received `Call` envelope, correlated with its reply reference
    (the correlation stamp rides the message envelope's header, so the
    caller's typed await decodes exactly `value`). Returns `true` when
    the reply was enqueued on a live mailbox, `false` when the caller is
    gone (it crashed or timed out and exited — a late reply dead-letters
    harmlessly, Erlang semantics).
    """

  pub fn reply(call_envelope :: Call(request_type), value :: reply_type) -> Bool {
    :zig.ProcessRuntime.send_correlated(call_envelope.reply_to, call_envelope.reply_ref, value)
  }

  @doc = """
    Cumulative count of mailbox envelopes examined by this process's
    internal correlated receives (`Process.call`/`Task.await`) — the
    observability counter for the O(1)-from-mark skip (research §6.2
    R8): a call made over a deep mailbox backlog examines a handful of
    envelopes, not the backlog. Deltas between two reads measure one
    call's scan work.
    """

  pub fn correlated_receive_visits() -> u64 {
    :zig.ProcessRuntime.correlated_scan_visits()
  }
}

@doc = """
  The request envelope a `Process.call` delivers to the server: the typed
  `request` plus the reply address (`reply_to`, the caller's raw pid bits)
  and the correlation reference (`reply_ref`) that `Process.reply` stamps
  on the answer. A server receives it as an ordinary typed message —
  `receive Call(i64) { c -> ... }` — and never touches the correlation
  fields except through `Process.reply(call, value)`.
  """

pub struct Call(request_type) {
  request :: request_type
  reply_ref :: u64
  reply_to :: u64
}
