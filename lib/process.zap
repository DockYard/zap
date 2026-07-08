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
  blocks, pops the mailbox head, decodes it as the same fixed scalar
  transport, and dispatches by pattern match (with an optional `after
  <ms> -> <body>` timeout arm). Compiler-inferred per-process message
  unions and exhaustiveness (plan item 2.2, P2-J4) will make its
  explicit `<t>` token optional and prove every arm reachable.

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
    Sends `message` to the process behind `pid`, type-checked against
    the handle's message type: `Process.send(pid :: Pid(m), m)`.
    Returns `true` when the message was enqueued on a live mailbox
    and `false` when it was dead-lettered (the target has exited or
    the pid is stale — Erlang semantics: not an error). The message
    type must be sendable (struct doc): a scalar, `String`, `List`/
    `Map`, or a by-value struct of those — a rich value is deep-copied
    so the receiver gets an independent copy. An unsendable type (a
    closure, a payload-bearing union) is a compile error.
    """

  pub fn send(pid :: Pid(message_type), message :: message_type) -> Bool {
    :zig.ProcessRuntime.send_message(pid.raw, message)
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
    Terminates the calling process immediately (the kernel's teardown
    path; exit reasons and links/monitors are Phase 5 work). Never
    returns. From the root process this ends the program with exit
    status 0. A process that simply returns from its entry function
    exits normally without calling this.
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
}
