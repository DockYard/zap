# Concurrency in Zap

Zap ships a BEAM-style concurrency runtime: lightweight processes
scheduled M:N over your CPU cores, share-nothing isolation, typed
message passing, links, monitors, and supervisors — compiled into your
binary only when you ask for it.

This guide is the user-facing walkthrough: enabling the runtime, your
first process, typed messages, request/response, fault tolerance,
per-process memory managers, sharing big data, and observability. It
closes with three contracts every production user should read: the
[FFI safety contract](#the-ffi-safety-contract), the
[message-versioning posture](#message-versioning-evolving-message-types),
and the [preemption-latency bound](#latency-bounds-the-preemption-model).

Every complete program in this guide compiles and runs as shown.

## Enabling the runtime

The concurrency runtime is behind a compile-time gate that defaults
**off**. A gate-off binary carries none of the runtime — no kernel
object is linked, no scheduler threads exist, and no safepoint
instructions are emitted. You pay nothing until you opt in.

In a project, set `runtime_concurrency: true` in the target's
`Zap.Manifest` (in `build.zap`):

```zap
%Zap.Manifest{
  name: "my_app",
  version: "0.1.0",
  kind: :bin,
  root: &MyApp.main/1,
  paths: ["lib/**/*.zap"],
  runtime_concurrency: true
}
```

Or override per build on the command line (works for `zap build`,
`zap run`, and single-file script mode):

```sh
zap run -Druntime-concurrency=on my_script.zap
```

Calling any `Process`, `Task`, `Supervisor`, `Blob`, or `RuntimeInfo`
function in a gate-off build is a compile error, not a silent no-op.

In a gate-on binary, your `main` runs as the **root process** of the
runtime. The program's lifetime is the root's lifetime: when `main`
returns, any processes still running are torn down wholesale and the
program exits (Erlang halt semantics). `Process.self()`, `send`, and
`receive` work in `main` exactly as in any spawned process.

### Supported platforms

The runtime requires stackful fibers and an OS-primitive layer that
currently exist for:

- **Architectures**: aarch64, x86_64
- **Operating systems**: macOS and Linux

A gate-on build for any other target is **rejected at compile time**
with a diagnostic explaining why and what to do. Two examples, verbatim:

- `wasm32-wasi`: "runtime_concurrency is not supported on wasm32 …:
  the concurrency kernel requires stackful fibers, and the wasm call
  stack is architecturally inaccessible — no wasm fiber substrate
  exists (Asyncify is ruled out; revisit when the wasm stack-switching
  proposal ships)."
- `x86_64-windows-gnu`: "runtime_concurrency is not supported on
  windows …: the concurrency kernel's OS-primitive layer exists for
  macOS/Darwin and Linux only — the Windows port (plan item 7.2a)
  still needs futex parking …"

Gate-**off** builds cross-compile to Zap's full target matrix as
always; the capability gate constrains only gate-on binaries.

## Your first process

`Process.spawn` takes a **named, zero-parameter function** and returns
the child's raw pid bits (a `u64`). The child starts with an empty
mailbox; you hand it everything it needs — including a reply channel —
by sending messages. The idiomatic handshake: the child's first
message is the parent's own pid bits.

```zap
# First process: spawn a child, hand it a reply channel, exchange messages.
pub struct Greeter {
  # The child entry: receives the parent's raw pid bits (its reply
  # channel), then a number, and replies with the number doubled.
  pub fn doubler() -> Nil {
    parent_bits = receive u64 {
      bits -> bits
    }
    parent = Process.pid(i64, parent_bits)
    value = receive i64 {
      n -> n
    }
    _sent = Process.send(parent, value * 2)
    nil
  }
}

fn main(_args :: [String]) -> u8 {
  # Note the bind-then-wrap shape: `Process.spawn` is bound to a local BEFORE
  # `Process.pid(...)` wraps it. In script-mode `main` specifically, nesting the
  # spawn call directly inside `Process.pid(...)`'s macro argument fails to
  # resolve the function capture (a known limitation, plan item 7.3a) — keep
  # the two steps separate; do not "simplify" them into one expression.
  child_bits = Process.spawn(&Greeter.doubler/0)
  _channel = Process.send(Process.pid(u64, child_bits), Process.self())
  _work = Process.send(Process.pid(i64, child_bits), 21)
  answer = receive i64 {
    n -> n
  }
  IO.puts("the child says: #{answer}")
  0
}
```

```
$ zap run -Druntime-concurrency=on first_process.zap
the child says: 42
```

Three things to notice:

- **Spawn scope.** The entry must be a named (or capture-less)
  zero-parameter function — `&Greeter.doubler/0`. A closure with a
  captured environment is rejected at compile time: it would share the
  spawner's heap into the child unsafely.
- **`receive` blocks.** `receive <type> { <pattern> -> <body> … }`
  parks the process until a message arrives, takes the **oldest** user
  message, decodes it as the given type, and dispatches by pattern
  match. An optional `after <ms> -> <body>` arm times the wait out;
  `after 0` polls without blocking.
- **Send never blocks, and never errors on a dead target.**
  `Process.send` returns `true` when the message was enqueued on a
  live mailbox and `false` when it was **dead-lettered** (the target
  exited, the pid is stale, or the name is unregistered). Erlang
  semantics: sending into the void is not an error.

### What can travel in a message

Scalars (`i64`, `u64`, `f64`, `Bool`, `Atom`) travel as fixed-size
payloads. Rich values — `String`, `List`/`Map` of sendable elements,
and by-value structs of those — travel by **deep copy**: the sender
serializes the value graph, and the receiver reconstructs a fresh,
independent copy it solely owns. Sender and receiver never share a
mutable cell; the sender keeps its original (send borrows, never
moves).

Still unsendable — a **compile error**, never a silent truncation:
closures / `Callable` existentials, payload-bearing or parametric
unions, and values holding external resource handles. (Payload-*free*
unions are sendable — they are the message-union workhorse, below.)

When a payload is large and you are done with it, skip the copy:

```zap
payload = [1, 2, 3, 4, 5]
# Consumes `payload`: using it after this line is a compile error.
_sent = Process.send_move((Pid.of(child) :: Pid([i64])), payload)
```

`Process.send_move` transfers ownership. When the value is uniquely
owned, region-closed, and the receiver runs the same memory model, the
whole subgraph is re-parented in O(1) with no copy; every other case
degrades transparently to the copy send — the result is identical,
only the cost differs.

## Typed pids and message unions

A pid handle is typed by the messages it carries: `Pid(M)` is the
analogue of Gleam's typed `Subject`. `Process.send` only accepts a
`Pid(M)` paired with a message of type `M`, so sending a value the
receiver cannot decode is a compile error at the send site.

Raw pid bits (`u64`) carry no message type — they are how pids travel
inside messages. Re-type them on arrival:

- `Process.pid(i64, bits)` — scalar token forms (`i64`, `u64`, `f64`,
  `Bool`, `Atom`)
- `(Pid.of(bits) :: Pid(M))` — the general form, for any sendable
  message type including unions

Both are unchecked assertions about what the target expects; the
compiler checks every send *against the handle*, not the handle
against the process.

The standard shape for a process with a real protocol is a
**payload-free message union**:

```zap
# Typed pids + a message union: exhaustive receive, catch-all, after.
pub union Signal {
  Ping,
  Pong,
  Stop
}

pub struct Player {
  pub fn responder() -> Nil {
    parent_bits = receive u64 {
      bits -> bits
    }
    parent = (Pid.of(parent_bits) :: Pid(Signal))
    message = receive Signal {
      :Ping -> Signal.Pong
      :Pong -> Signal.Ping
      :Stop -> Signal.Stop
    }
    _sent = Process.send(parent, message)
    nil
  }
}

fn main(_args :: [String]) -> u8 {
  responder_bits = Process.spawn(&Player.responder/0)
  _channel = Process.send(Process.pid(u64, responder_bits), Process.self())
  responder = (Pid.of(responder_bits) :: Pid(Signal))
  _pinged = Process.send(responder, Signal.Ping)
  reply = receive Signal {
    :Pong -> "pong"
    _ -> "unexpected"
  after
    1000 -> "timed out"
  }
  IO.puts("reply: #{reply}")
  0
}
```

```
$ zap run -Druntime-concurrency=on ping_pong.zap
reply: pong
```

### The exhaustiveness contract

A `receive` over a message union must handle **every variant** — or
carry a catch-all `_` arm. Leaving one out is a compile error:

```
error: non-exhaustive `receive` over message union `Signal`
  │
8 │     receive Signal {
  │     ^^^^^^^^^^^^^^^^ missing: Pong
  │
  = help: handle the missing variants, or add a catch-all `_ ->` arm
    to accept unexpected messages (routed to the dead-letter path)
```

This is the safe-evolution lever: **adding a variant to a message
union makes the compiler point at every `receive` that must now handle
it.** See [Message versioning](#message-versioning-evolving-message-types)
for what this means for rolling deploys and dynamic senders.

### What happens to an unexpected message

If a message arrives that matches **no arm** of the `receive` that
consumes it, it is routed to the **dead-letter path**: the event is
counted in runtime telemetry (never a silent drop) and the *receiving
process* is terminated through the kill path. The failure is contained
to that one process — the scheduler, every other process, and the
program as a whole continue. Under a supervisor, the process is simply
restarted. A catch-all `_` arm is how a process opts out and absorbs
anything.

## Request/response

### `Process.call` — the typed synchronous call

For the GenServer-call shape, `Process.call` sends a typed request and
blocks for the correlated reply. A server receives a `Call(RequestType)`
envelope as an ordinary message and answers with `Process.reply`:

```zap
# Request/response: a Process.call server plus Task.async/await.
pub struct Adder {
  pub fn server() -> Nil {
    call = receive Call(i64) {
      c -> c
    }
    _replied = Process.reply(call, call.request + 1)
    Adder.server()
  }
}

pub struct Report {
  pub fn render() -> String {
    "rendered by a task worker"
  }

  pub fn render_async() -> String {
    task = Task.async(&Report.render/0)
    Task.await(task)
  }
}

fn main(_args :: [String]) -> u8 {
  server = (Pid.of(Process.spawn(&Adder.server/0)) :: Pid(Call(i64)))
  answer = (Process.call(server, 41) :: i64)
  IO.puts("call reply: #{answer}")
  IO.puts("task reply: #{Report.render_async()}")
  0
}
```

```
call reply: 42
task reply: rendered by a task worker
```

The reply type is the call expression's annotated type — bind or
ascribe it at the call site: `(Process.call(server, 41) :: i64)`. The
default timeout is 5000 ms; `Process.call(server, request, timeout_ms)`
overrides it.

**The failure surface is Elixir's** (`GenServer.call` semantics): the
caller *exits* rather than receiving an error value.

- The server is already dead → the caller exits `:noproc`
  **immediately** (the call is monitored — it never hangs out the
  timeout waiting for a corpse).
- The server dies mid-call → the caller exits with the server's real
  exit reason, immediately.
- The server is alive but silent → the caller exits `:timeout` when
  the deadline elapses.

The wait is a **correlated receive**: the reply (or the monitor's
`DOWN`) is found in O(1) from a mark captured when the call began. An
arbitrarily deep mailbox backlog is skipped, stays queued, and keeps
its order for the ordinary `receive` — calling into a busy server from
a busy process costs a handful of envelope visits, not a mailbox scan.
On every return path the monitor is dropped with flush semantics, so
no stale `DOWN` can poison a later `receive`.

### `Task.async` / `Task.await` — one-shot workers

`Task.async(&F/0)` spawns a monitored worker running `F` and returns a
typed `Task(T)` handle, where `T` is `F`'s return type; `Task.await`
blocks (default 5000 ms) for the typed result. The same correlation
machinery backs it, and the failure surface is Elixir's: `await` exits
with the worker's crash reason, `:timeout` on deadline, or
`:not_owner` when a process that did not create the task awaits it.

One deliberate difference from Elixir, documented rather than papered
over: `Task.async` does **not** link the worker to the owner. An
unawaited task whose owner dies runs to completion and its reply
dead-letters. Linking is owner-lifetime policy that belongs with
supervised tasks.

## Named processes

A process registers *itself* under an atom, holds at most one name,
and the name is released automatically when it exits (including by
crash):

```zap
# Named processes: register, whereis, send-by-name.
pub struct Counter {
  pub fn server() -> Nil {
    _registered = Process.register(:counter)
    Counter.loop(0)
  }

  fn loop(count :: i64) -> Nil {
    request = receive Call(i64) {
      c -> c
    }
    updated = count + request.request
    _replied = Process.reply(request, updated)
    Counter.loop(updated)
  }

  # Poll until the name is registered (spawn is asynchronous). The
  # `after 1` arm yields this process while it waits.
  pub fn wait_for(name :: Atom) -> u64 {
    case Process.whereis(name) {
      0 ->
        {
          _waited = receive i64 {
            n -> n
          after
            1 -> -1
          }
          Counter.wait_for(name)
        }
      bits -> bits
    }
  }
}

fn main(_args :: [String]) -> u8 {
  _spawned = Process.spawn(&Counter.server/0)

  server_bits = Counter.wait_for(:counter)
  server = (Pid.of(server_bits) :: Pid(Call(i64)))

  first = (Process.call(server, 5) :: i64)
  second = (Process.call(server, 7) :: i64)
  IO.puts("running total: #{second}")

  # Send-by-name works for plain (non-call) messages; it returns false
  # when the name is unregistered (dead-letter, not an error).
  ghost_delivered = Process.send(:nobody_home, 1)
  IO.puts("send to an unregistered name delivered: #{ghost_delivered}")
  0
}
```

```
running total: 12
send to an unregistered name delivered: false
```

- `Process.whereis(name)` resolves to the live registrant's pid bits,
  or `0`. The lookup is generation-validated: a name whose holder died
  resolves to `0`, never to a stale or recycled process.
- `Process.send(name, message)` is send-by-name. It is **untyped** (a
  name carries no message type), so the caller is responsible for
  sending what the named process expects.
- `Process.unregister(name)` releases a name early; teardown releases
  it automatically.

## Fault tolerance

### Links, monitors, trap_exit

The raw material of supervision, with Erlang's exact semantics:

- **`Process.link(pid)` / `Process.spawn_link(entry)`** — a
  bidirectional link. An *abnormal* exit on either side cascades to
  the other; a `:normal` exit never kills a linked peer. `spawn_link`
  establishes the link atomically **before the child can run**, so
  even a child that exits instantly propagates its real reason.
- **`Process.monitor(pid)` / `Process.spawn_monitor(entry)`** — a
  unidirectional, stackable watch. The watcher never dies with the
  target; it receives a `DOWN` signal carrying the exit reason.
  Monitoring an already-dead process fires a `:noproc` `DOWN`
  immediately.
- **`Process.trap_exit(true)`** — converts trappable exit signals into
  `{'EXIT', from, reason}` mailbox signals instead of dying. The
  untrappable exception: `Process.kill` (and `exit_signal` with the
  literal `:kill`) terminates even a trapping process with reason
  `:killed`.
- **`Process.await_signal()`** — blocks for the next *signal* (a
  trapped `EXIT` or a monitor `DOWN`), returns its reason atom, and
  leaves ordinary user messages queued in order. The mirror-image
  contract: `receive` consumes only user messages and skips signals.
  (Decoding signals as tuples inside `receive` is planned but not yet
  available; `await_signal` plus `Process.last_signal_from/ref/kind`
  is the shipped surface.)
- **`Process.exit_with(reason)`** terminates the calling process
  abnormally; **`Process.exit_signal(pid, reason)`** is Erlang
  `exit/2`, with the `:kill` and `:normal` special cases implemented
  exactly.

```zap
# Fault tolerance primitives: links, monitors, trap_exit.
pub struct Fragile {
  pub fn crashes() -> Nil {
    Process.exit_with(:boom)
  }

  pub fn finishes() -> Nil {
    nil
  }

  # A trapping parent observes a linked child's crash as a signal
  # instead of dying with it.
  pub fn supervise_once() -> Atom {
    _previous = Process.trap_exit(true)
    _child = Process.spawn_link(&Fragile.crashes/0)
    Process.await_signal()
  }

  # A monitor is one-way: the watcher gets a DOWN, never dies.
  pub fn watch_once() -> Atom {
    {_pid, _ref} = Process.spawn_monitor(&Fragile.finishes/0)
    Process.await_signal()
  }
}

fn main(_args :: [String]) -> u8 {
  crash_reason = Fragile.supervise_once()
  IO.puts("trapped linked exit: #{crash_reason}")

  down_reason = Fragile.watch_once()
  IO.puts("monitor DOWN reason: #{down_reason}")
  0
}
```

```
trapped linked exit: boom
monitor DOWN reason: normal
```

### Supervisors

`Supervisor` (in `lib/supervisor.zap`) is OTP-grade supervision
written in pure Zap over those primitives: a supervisor is an ordinary
process that traps exits, `spawn_link`s its children, and runs a
receive loop over their exit signals. Because every child is linked,
no child can outlive its supervisor — the link graph *is* the
structured-concurrency guarantee.

The library owns all the **policy** as pure data transforms
(`Supervisor.init`, `Supervisor.step`, `Supervisor.installed`); your
module owns the small **loop** that actually starts children, calling
your own local `dispatch` function. This inversion exists because Zap
does not store function values in fields — it is the same shape as an
OTP callback module.

A complete supervised application:

```zap
# A complete supervisor: one_for_one over two registered workers.
pub struct App.Workers {
  # A worker parks in receive; :crash makes it exit abnormally so the
  # supervisor restarts it, :stop makes it exit cleanly.
  pub fn db_entry() -> Nil {
    _registered = Process.register(:db)
    App.Workers.worker_loop()
  }

  pub fn cache_entry() -> Nil {
    _registered = Process.register(:cache)
    App.Workers.worker_loop()
  }

  pub fn worker_loop() -> Nil {
    command = receive Atom {
      c -> c
    }
    case command {
      :crash -> Process.exit_with(:boom)
      :stop -> nil
      _ -> App.Workers.worker_loop()
    }
  }
}

pub struct App.Sup {
  pub fn start() -> u64 {
    Supervisor.start(&App.Sup.run/0)
  }

  pub fn run() -> Nil {
    children = [Supervisor.worker(:db), Supervisor.worker(:cache)]
    state = Supervisor.init(children, Supervisor.options(:one_for_one, 5, 5000))
    App.Sup.loop(state)
  }

  pub fn loop(state :: SupervisorState) -> Nil {
    current = Supervisor.step(state)
    case current.action {
      :start ->
        App.Sup.loop(Supervisor.installed(current.state, current.child_id, App.Sup.dispatch(current.child_id)))
      :stop ->
        Process.exit_with(current.reason)
      _ ->
        App.Sup.loop(current.state)
    }
  }

  pub fn dispatch(child_id :: Atom) -> u64 {
    case child_id {
      :db -> Process.spawn_link(&App.Workers.db_entry/0)
      :cache -> Process.spawn_link(&App.Workers.cache_entry/0)
      _ -> Process.spawn_link(&App.Workers.db_entry/0)
    }
  }

  # Poll until `name` resolves (registration is asynchronous).
  pub fn wait_for(name :: Atom) -> u64 {
    case Process.whereis(name) {
      0 ->
        {
          _waited = receive i64 {
            n -> n
          after
            1 -> -1
          }
          App.Sup.wait_for(name)
        }
      bits -> bits
    }
  }

  # Poll until `name` resolves to a pid DIFFERENT from `old` (the restart).
  pub fn wait_for_restart(name :: Atom, old :: u64) -> u64 {
    current = App.Sup.wait_for(name)
    case current == old {
      false -> current
      true ->
        {
          _waited = receive i64 {
            n -> n
          after
            1 -> -1
          }
          App.Sup.wait_for_restart(name, old)
        }
    }
  }
}
```

Driving it (crash `:db`, watch it come back as a fresh process while
`:cache` is untouched):

```zap
fn main(_args :: [String]) -> u8 {
  _sup = App.Sup.start()

  first_db = App.Sup.wait_for(:db)
  _cache = App.Sup.wait_for(:cache)
  IO.puts("both workers up")

  # Crash the db worker; the supervisor restarts it as a FRESH process.
  _crashed = Process.send(:db, :crash)
  restarted_db = App.Sup.wait_for_restart(:db, first_db)
  IO.puts("db restarted with a new pid: #{restarted_db != first_db}")
  IO.puts("cache untouched: #{Process.whereis(:cache) != 0}")
  0
}
```

```
both workers up
db restarted with a new pid: true
cache untouched: true
```

The policy surface, exactly OTP's — the `Supervisor` doc in
`lib/supervisor.zap` covers every rule in depth:

- **Strategies**: `:one_for_one`, `:rest_for_one`, `:one_for_all`,
  `:simple_one_for_one`.
- **Restart types**: `:permanent` (always restart), `:temporary`
  (never), `:transient` (only on abnormal exit).
- **Restart intensity**: more than `intensity` restarts within
  `period_ms` and the supervisor gives up — terminates its children
  right-to-left and exits `:shutdown` (the crash-loop breaker).
  Defaults: intensity 1, period 5000 ms.
- **Shutdown protocols** (per child): `:brutal_kill`, `:timeout`
  (graceful `exit(shutdown)` then kill after a grace period),
  `:infinity` (the default for supervisor children).
- **Order**: children start left-to-right, terminate right-to-left.
- **Trees**: a supervisor is an ordinary process, so a child can be
  another supervisor (`Supervisor.supervisor(:sub)`); teardown recurses
  depth-first, right-to-left.

## Per-spawn memory managers

Every process owns its own heap, and each spawn can choose the memory
manager for that heap — bound **at the spawn site, at compile time**:

```zap
worker = Process.spawn(&MyServer.run/0, Memory.Arena)
```

`Process.spawn(entry)` uses the manifest manager (default:
`Memory.ARC`). The manager argument must be a comptime-known type
implementing `Memory.Manager`; the chosen manager's reclamation model
is monomorphized into the spawn-reachable call graph — hot allocation
paths carry no per-allocation dispatch — and recorded in the child's
pid bits. A manager that is unsound on the build target is a
spawn-time error while the rest of the roster stays usable.

The roster and when to reach for each:

| Manager | Model | Pick it when |
| --- | --- | --- |
| `Memory.ARC` | Atomic refcounting, deterministic per-drop reclamation | The default. General-purpose; predictable prompt frees. |
| `Memory.Arena` | Bump allocation; frees elided; bulk-freed at process exit — plus the automatic receive-loop reset (below) | Short-lived processes, and long-lived **bounded servers** whose per-message garbage should vanish per iteration. |
| `Memory.ORC` | ARC plus a Bacon–Rajan per-process cycle collector | You want ARC semantics with insurance against reference cycles. Honest note: Zap's surface immutability means user code cannot currently *construct* a reference cycle, so ORC's cycle-collection value is dormant until mutation primitives land — it is proven at the manager level and safe to use today, behaving like ARC. |
| `Memory.GC` | Conservative stop-the-world mark-sweep (per process) | Allocation-heavy work where refcount traffic hurts and pauses are acceptable. See the [latency section](#latency-bounds-the-preemption-model): a collect over a large live heap is blocking-scale work. |
| `Memory.NoOp` / `Memory.Leak` | Never reclaim | Diagnostics/CI (leak baselines, elision verification). Not for production. |
| `Memory.Tracking` | Wraps allocations with leak/invalid-free/canary detection | Diagnostics/CI. |

### The bounded arena server

A long-lived `Memory.Arena` server whose receive loop the compiler can
prove *loop-closed* — no allocation from one iteration is reachable
when control returns to the `receive` — gets an **automatic O(1) arena
reset** at the top of every iteration. Per-message garbage never
accumulates; the heap holds exactly steady:

```zap
# A bounded Memory.Arena server: per-message garbage is reclaimed at
# every receive back-edge, so the heap holds steady across a storm.
pub struct Metrics {
  pub fn start() -> u64 {
    Process.spawn(&Metrics.server_entry/0, Memory.Arena)
  }

  pub fn server_entry() -> Nil {
    parent = Process.receive_raw(u64)
    Metrics.serve(parent)
  }

  pub fn serve(parent :: u64) -> Nil {
    n = receive i64 {
      value -> value
    }
    case n {
      -1 -> nil
      0 ->
        {
          # Do one iteration of work first so the report observes live
          # accounting, then report our reserved heap bytes.
          _work = Metrics.build_and_sum(1, 50)
          _sent = Process.send(Process.pid(u64, parent), Process.heap_bytes())
          Metrics.serve(parent)
        }
      seed ->
        {
          # Fresh per-message garbage: dead before the loop returns to
          # receive, so the arena reset reclaims it.
          _total = Metrics.build_and_sum(seed, 50)
          Metrics.serve(parent)
        }
    }
  }

  pub fn build_and_sum(seed :: i64, length :: i64) -> i64 {
    items = Metrics.build_list(seed, length, [])
    Metrics.sum(items, List.length(items), 0)
  }

  fn build_list(seed :: i64, remaining :: i64, acc :: List(i64)) -> List(i64) {
    case remaining == 0 {
      true -> acc
      false -> Metrics.build_list(seed + 1, remaining - 1, List.push(acc, seed))
    }
  }

  fn sum(items :: List(i64), index :: i64, acc :: i64) -> i64 {
    case index == 0 {
      true -> acc
      false -> Metrics.sum(items, index - 1, acc + List.get(items, index - 1))
    }
  }

  pub fn send_work(server :: u64, next :: i64, remaining :: i64) -> Bool {
    case remaining == 0 {
      true -> true
      false ->
        {
          _sent = Process.send(Process.pid(i64, server), next)
          Metrics.send_work(server, next + 1, remaining - 1)
        }
    }
  }
}

fn main(_args :: [String]) -> u8 {
  server = Metrics.start()
  _channel = Process.send(Process.pid(u64, server), Process.self())

  _warmup = Metrics.send_work(server, 1, 100)
  _ask1 = Process.send(Process.pid(i64, server), 0)
  baseline = receive u64 {
    bytes -> bytes
  }

  _storm = Metrics.send_work(server, 1, 10000)
  _ask2 = Process.send(Process.pid(i64, server), 0)
  after_storm = receive u64 {
    bytes -> bytes
  }

  _stop = Process.send(Process.pid(i64, server), -1)
  IO.puts("baseline heap bytes: #{baseline}")
  IO.puts("heap bounded after 10k messages: #{after_storm == baseline}")
  0
}
```

Ten thousand allocating messages later, the reported
`Process.heap_bytes()` is **equal** to the warm baseline — not fuzzily
bounded, equal:

```
baseline heap bytes: 8388608
heap bounded after 10k messages: true
```

The proof is conservative and per receive site: a loop that *retains*
state across iterations (an accumulator parameter holding a list, say)
is rejected and never reset — correctness first, the optimization only
where it is sound.

`Process.heap_bytes()` reports the calling process's reserved heap at
its manager's accounting granularity (Arena reports reserved chunk
bytes; managers without byte accounting, `Memory.ARC` today, report
`0`).

### Hibernation

For long-lived, rarely-messaged processes, `Process.hibernate()` parks
until the next message arrives *without consuming it* — and while
parked, the committed fiber-stack pages below the parked frame are
released back to the OS (recommitted transparently on wake). An idle
handler's resident footprint shrinks to a few pages no matter how deep
its earlier call chains ran:

```zap
pub fn handler() -> Nil {
  parent = Process.pid(i64, Process.receive_raw(u64))
  _woke = Process.hibernate()
  event = receive i64 {
    n -> n
  }
  _sent = Process.send(parent, event * 10)
  nil
}
```

Hibernating between messages composes with the arena receive-loop
reset for the full BEAM-hibernation effect.

## Sharing big data: Blob

Deep-copying every message is exactly right for structured data and
exactly wrong for large immutable payloads. `Blob` is Zap's one
sanctioned exception to share-nothing: an atomically-refcounted,
**deeply immutable** byte buffer shared by pointer across processes.
No writes exist, so no data race can.

```zap
# Blob: the shared immutable tier + the global registry.
pub struct Config.Reader {
  pub fn worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    received = receive Blob {
      b -> b
    }
    # Zero payload bytes were copied; read straight from the shared buffer.
    _sent = Process.send(parent, Blob.size(received))
    nil
  }

  pub fn global_reader() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    fallback = Blob.new("unset")
    config = Blob.get_global(:app_config, fallback)
    _sent = Process.send(parent, Blob.size(config))
    nil
  }
}

fn main(_args :: [String]) -> u8 {
  config = Blob.new("shared configuration bytes")

  # Share by pointer: the handle is one word, the payload is never copied.
  child = Process.spawn(&Config.Reader.worker/0)
  _channel = Process.send(Process.pid(u64, child), Process.self())
  _shared = Process.send((Pid.of(child) :: Pid(Blob)), config)
  child_size = receive i64 {
    n -> n
  }
  IO.puts("child saw #{child_size} bytes without a copy")

  # The persistent-term analogue: put once, fetch from any process.
  _stored = Blob.put_global(:app_config, config)
  reader = Process.spawn(&Config.Reader.global_reader/0)
  _channel2 = Process.send(Process.pid(u64, reader), Process.self())
  global_size = receive i64 {
    n -> n
  }
  IO.puts("registry reader saw #{global_size} bytes")
  0
}
```

```
child saw 26 bytes without a copy
registry reader saw 26 bytes
```

The rules that keep it safe (full detail in `lib/blob.zap`):

- The bytes are copied in **once**, at `Blob.new`; every share after
  that is a one-word handle plus an atomic count bump — zero payload
  bytes copied, for any size, across any pair of memory models.
- The payload outlives any one process: a receiver's blob survives its
  dead sender; the last holder anywhere frees it. References are
  released explicitly with `Blob.release` or automatically at process
  exit.
- **Slices copy out** (`Blob.slice`, `Blob.to_string`): a 20-byte
  slice of a 10 MB blob can never pin those 10 MB — Erlang's
  sub-binary leak pathology is impossible by construction.
- A blob is sendable as a **top-level message only** (`Pid(Blob)`);
  nesting one inside a `List`/`Map`/struct payload is a compile error.
- `Blob.put_global` / `Blob.get_global` / `Blob.fetch_global` form the
  `persistent_term` analogue: a global atom-keyed registry for
  read-mostly data every process needs. Replacement on an existing key
  is safe with no copy-on-update; old readers keep the old payload
  alive until they release it.
- Misuse (double release, a handle you never acquired) **panics
  loudly** — handles are generation-validated, so it can never corrupt
  memory.

### Large strings ride the same tier automatically

You do not need to reach for `Blob` to send a big `String`. A string
send whose payload is at or above the promotion threshold (65,536
bytes) automatically promotes to a shared blob — **one copy, the last
of its cross-process life** — and the receiver's string *is* the
shared payload. Forwarding it to a third process copies nothing.
Small strings never touch the blob tier, and locally-constructed
strings — however large — pay nothing until they are actually sent.

## Blocking work: `Process.blocking`

Zap runs green processes M:N over a small set of core scheduler
threads. A call that blocks the OS thread — a blocking FFI call, a
long un-yielding CPU leaf — holds its core for the whole duration.
`Process.blocking` is the escape hatch (BEAM's dirty schedulers, Go's
syscall handoff, Tokio's `spawn_blocking`):

```zap
digest = Process.blocking(&Hasher.slow_digest/0)
```

It moves the calling process's fiber onto a dedicated blocking-pool OS
thread for the duration of the call, freeing the core to run other
processes; on return the process re-attaches to a core and the call
yields its `i64` result. The full contract — and why you must use it —
is the [FFI safety contract](#the-ffi-safety-contract) below.

## Observability

`RuntimeInfo` (in `lib/runtime_info.zap`) is the operability surface:

```zap
IO.puts("scheduler cores: #{RuntimeInfo.scheduler_count()}")
captured = RuntimeInfo.capture_processes()
IO.puts("live processes captured: #{captured}")
IO.puts("global run queue depth: #{RuntimeInfo.global_run_queue_depth()}")
IO.puts("tracing compiled in: #{RuntimeInfo.trace_enabled()}")
```

- **Process listing**: `capture_processes()` snapshots the live set;
  indexed getters read each process's pid bits, scheduling state
  (`:runnable`, `:running`, `:waiting`, `:blocking`, …), mailbox
  depth, and heap bytes.
- **Scheduler utilization**: per-core busy/parked wall-time split
  (`scheduler_utilization_permille`), run-queue depths per core plus
  the global overflow queue.
- **Message-flow tracing**: compile-time optional
  (`runtime_tracing: true` in the manifest, or
  `-Druntime-tracing=on`; requires the concurrency gate). When off —
  the default — the binary contains zero trace instructions and the
  read API reports empty. When on, every spawn/exit/send/receive/
  signal-delivery event lands in a bounded in-memory ring (the newest
  4096 events), readable through `trace_capture()` and the
  `trace_*` getters. Measured cost when on: roughly 10–15 ns per
  event.
- **Dead-letter telemetry**: unexpected-message dead-letters and
  send-to-dead-target dead-letters are counted, never silently
  dropped; trace `:send` events carry a delivered-vs-dead-lettered
  detail.

Two detectors run inside the scheduler itself:

- **Deadlock detection** — "live processes exist, yet every core is
  idle and no message, timer, or blocking completion can ever arrive."
  The check is a consistent scan with no false positives under M:N
  (pending `receive … after` timers and in-flight `Process.blocking`
  work correctly suppress it). On detection the runtime reports once —
  naming every waiting process with its mailbox depth, heap bytes, and
  suspend site — then, by default, stays parked (BEAM-compatible
  behavior, plus the diagnostic). Set `ZAP_DEADLOCK_ACTION=stop` or
  `=panic` to opt into fail-fast instead; that is sound because a
  detected deadlock is permanent — no external wake source exists.
- **Starvation detection** — a watermark on consecutive passed-over
  picks at a core's run-queue head. Structurally silent under the
  production scheduler's FIFO + fairness rules; if it ever fires, it
  names the starved process. It exists to catch scheduler bugs, not
  load.

## The FFI safety contract

Zap will happily call into native code. Four rules keep the runtime
healthy — they are BEAM's NIF rules, stated for Zap:

1. **An un-annotated blocking call stalls a core scheduler.** The
   runtime does not detect or rewrite blocking calls. A native call
   that blocks — a crypto routine, a database driver, `getaddrinfo`,
   any long CPU-bound leaf — holds its scheduler core for its entire
   duration, stalling every green process co-scheduled on that core,
   exactly as an over-long NIF stalls a BEAM scheduler. This is the
   honest contract: the language cannot see inside a native call.

2. **`Process.blocking` is the escape.** Wrap the blocking leaf:

   ```zap
   pub fn hash_rounds() -> i64 {
     Crypto.pbkdf2_cost(1000000)
   }

   digest = Process.blocking(&MyServer.hash_rounds/0)
   ```

   The calling process's fiber is evacuated to a dedicated
   blocking-pool OS thread; the core keeps running its other
   processes; the process re-attaches when the leaf returns. Rule of
   thumb (BEAM's): anything that may run longer than about a
   millisecond belongs under `Process.blocking`.

3. **The leaf-call rule.** The function you hand to `Process.blocking`
   runs *off-core*. It must be a leaf with respect to the runtime: it
   must not `spawn`, `send`, `receive`, or otherwise re-enter the
   process runtime. A blocking FFI call or a pure computation is
   exactly right; scheduler operations from a blocking-pool thread are
   not supported.

4. **A bad native call crashes the whole OS process.** All Zap
   processes share one OS process image. Process isolation protects
   you from *Zap-level* failures (a crash in one process is a signal
   to its links, nothing more) — it cannot protect you from a native
   call that corrupts memory or segfaults. That failure takes down
   every process in the program, exactly as a crashing NIF takes down
   the whole BEAM VM. Treat native code as part of your trusted
   computing base. For genuinely untrusted native code, the safe
   pattern is an out-of-process port (BEAM's `Port` model) — a
   documented future direction, not shipped today.

## Message versioning: evolving message types

Two facts shape how message protocols evolve in a running system.

**The static story: exhaustiveness is the migration tool.** A
process's protocol is its message union. When you add a variant —
`Signal` grows a `Drain` — the build fails at every `receive Signal`
that does not handle it, with the diagnostic naming the missing
variant. Adding a message type is therefore a compile-time-guided
refactor: the compiler walks you to every receive site that must
decide what `Drain` means. There is no way to forget one.

**The dynamic story: unknown messages dead-letter; the runtime never
crashes.** Sends are checked against the *handle*, not the receiving
process: raw pid bits re-typed with `Pid.of`, send-by-name (untyped by
design), and mixed-version fleets during a rolling deploy can all
deliver a message the receiver does not expect. The posture, in
increasing order of blast radius — none of which is "the program
goes down":

- A send to a dead or stale pid, or an unregistered name, returns
  `false` (dead-lettered at the send). Erlang semantics: not an error.
- A message that no `receive` arm matches is dead-lettered at the
  receive: counted in telemetry (and visible in traces), never
  silently dropped — and the *receiving process* is terminated through
  the kill path. The failure is contained to that one process; under a
  supervisor it is restarted. The scheduler and every other process
  are untouched.

**The catch-all escape for dynamic sources.** A process that accepts
messages from senders it cannot statically trust — a registered name
reachable by anything, a protocol mid-migration — opts out of
per-variant termination with a `_` arm:

```zap
command = receive Signal {
  :Ping -> handle_ping()
  :Stop -> shutdown()
  _ -> log_and_continue()   # tolerate unknown variants during a rolling deploy
}
```

That is the recommended posture for rolling deploys: ship the
catch-all in version N, add the variant's real handling in version
N+1, and old and new processes coexist safely while the fleet mixes
versions.

## Latency bounds: the preemption model

Zap's preemption is **cooperative with compiler-emitted safepoints**,
not signal-based. Knowing the bound — and the one case that escapes
it — matters for latency-sensitive services.

**The mechanism.** Every process runs with a reduction budget
(BEAM-style), spent through three layers of safepoints: one reduction
per allocation, a poll at the back-edge of every compiled loop (Zap
loops are tail calls, and both loopified and self-recursive forms are
polled), and a per-core flag-only watchdog seam — any thread can
demand preemption, and the flag is honored at the next safepoint. The
runtime's latency analyses use a 1 ms watchdog tick as the reference
unit. A process yields when its budget exhausts, when the watchdog
flag is up, or when it parks in `receive` — and the yield check is
engineered so a *sole* runnable process (a hot numeric loop with
nothing else to run) stays switch-free.

**The advertised bound.** Preemption latency is bounded by **one
reduction budget's worth of iterations of the slowest polled loop, or
one watchdog tick (1 ms), whichever is larger**. A newly-runnable peer
or a kill is observed at the next budget boundary.

**The K = 8 amortization on tight loops.** The tightest loops —
non-floating-point, allocation-free bodies made only of small leaf
calls — are unrolled 8-way with one safepoint per 8 original
iterations (per-iteration polling measurably regressed exactly these
loops). Two consequences,
both bounded: budget exhaustion can be observed up to K−1 = 7
iterations late, and a loop entry that exits in fewer than 8
iterations runs unpolled (bounded by 7 tight iterations returning into
a polled caller). At the nanoseconds-per-iteration cost that defines
this loop class, the added worst-case latency is tens of nanoseconds —
orders of magnitude inside the watchdog tick.

**The one unbounded case.** An un-splittable leaf kernel with no
safepoint in it — a single call into a long-running native routine, or
one enormous straight-line computation — cannot be preempted until it
returns. Its duration *is* the latency bound for its core. This is the
same honest caveat Go documents for un-preemptible leaf kernels; Zap
is narrower (there is no unbounded non-tail loop form — the residual
un-polled code is straight-line sequences and non-tail call chains,
each bounded by its own finite length), but a 100 ms native call is
100 ms of core occupancy. The remedy is rule 2 of the FFI contract:
put long leaves under `Process.blocking`.

**Memory managers and the bound.** Manager calls were measured against
the watchdog tick: allocation on every model — including the
lazy-commit page fault a fresh slab's first touch pays — stays tens of
microseconds or better, far under the tick, so ordinary allocation
never needs (and never pays for) a scheduler handoff. The **one
unbounded manager call** is a `Memory.GC` stop-the-world collect,
whose pause scales linearly with live-heap size (the conservative scan
was measured at roughly 1 µs/KiB in release builds): a collect over a
live heap beyond about 1 MB crosses the tick. `Memory.GC` is an opt-in
per-process model whose pauses are its documented tradeoff — treat a
GC-heavy process's long work as blocking-scale work (it is a
`Process.blocking` client), or pick ARC/ORC/Arena for
latency-sensitive processes co-scheduled with it.

## Under the hood

For contributors: the engineering record — design decisions, exit-gate
measurements, and the full implementation ledger — lives in
`docs/concurrency-implementation-plan.md` and the research briefs
(`zap-concurrency-research.md`, `research.md`, `research-round-2.md`);
this guide documents the user-facing contract only.
