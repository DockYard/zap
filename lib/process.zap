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

  ## What can travel in a message (Phase 2)

  Messages ride the kernel's opaque-bytes seam as fixed-size scalar
  payloads: `i64`, `u64`, `f64`, `Bool`, and `Atom` (atoms travel as
  their binary-global table ids). Everything richer — `String`,
  structs, lists, maps, closures — needs the P2-J5 deep-copy walker
  (plan item 2.4) and is REJECTED AT COMPILE TIME today; nothing is
  silently truncated. Raw pid bits are a `u64`, so a reply channel is
  handed to a child by sending `Process.self()` and re-typing it with
  `Process.pid` on the other side.

  ## Spawn scope (Phase 2)

  `Process.spawn` accepts a named (or capture-less) zero-parameter
  function — the shapes that lower to a bare function pointer. A
  closure with a captured environment would share the spawner's heap
  into the child unsafely without the P2-J5 walker, so it is rejected
  at compile time. Processes are always spawned under the manifest
  memory manager: a per-spawn manager option is not expressible in
  this surface by design — comptime-resolved per-spawn manager
  binding is Decision Gate 0 and lands with Phase 3 (plan item 3.1).

  ## Raw receive

  `Process.receive_raw(t)` blocks until a message arrives and decodes
  it as `t`. It TRUSTS the caller: the compiler cannot yet prove the
  mailbox only carries `t`, and a size mismatch between sender and
  receiver aborts at runtime rather than fabricating bytes. The
  checked `receive` construct over inferred per-process message
  unions is the next job (plan items 2.2/2.3, P2-J3) and replaces
  raw receives in ordinary code.

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

    Phase 2 scope: `entry` must be a named (or capture-less)
    zero-parameter function; closures with captured environments are
    rejected at compile time (see the struct doc). A per-spawn
    manager option is deliberately absent until Phase 3's Decision
    Gate 0 (plan item 3.1).
    """

  pub fn spawn(entry :: fn() -> Nil) -> u64 {
    :zig.ProcessRuntime.spawn_process(entry)
  }

  @doc = """
    Sends `message` to the process behind `pid`, type-checked against
    the handle's message type: `Process.send(pid :: Pid(m), m)`.
    Returns `true` when the message was enqueued on a live mailbox
    and `false` when it was dead-lettered (the target has exited or
    the pid is stale — Erlang semantics: not an error). The message
    type must be Phase 2 sendable (struct doc); anything richer is a
    compile error until P2-J5.
    """

  pub fn send(pid :: Pid(message_type), message :: message_type) -> Bool {
    :zig.ProcessRuntime.send_message(pid.raw, message)
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
    token and returns it: `Process.receive_raw(i64)` parks the
    calling process until its mailbox is nonempty and yields the
    oldest message as an `i64`. Tokens cover the Phase 2 sendable set
    (`i64`, `u64`, `f64`, `Bool`, `Atom`). RAW primitive — the type
    is trusted, not checked (struct doc); a payload whose size does
    not match the token aborts the program.
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
