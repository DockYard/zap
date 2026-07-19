# Zap Concurrency Model: Process-Based Isolation with Message Passing

## Overview

Zap will implement an Erlang-style process model where each Zap process is fully isolated with its own memory. Processes communicate exclusively through message passing. No shared memory between processes.

This is made possible by Zig 0.16's `Io.Evented` backends which provide green threads (stackful coroutines) on io_uring (Linux), kqueue (BSD), and Grand Central Dispatch (macOS). The Zig standard library provides `Future(T)`, `Group`, `Queue(T)`, and `Select` as building blocks.

## Core Principles

1. **Complete process isolation.** Each process has its own heap. No shared references between processes. One process crashing cannot corrupt another's memory.

2. **Message passing is the only communication mechanism.** No shared state, no shared references, no cross-process reference counting.

3. **Copy by default, transfer by opt-in.** Messages are copied into the receiver's memory by default (safe, predictable). Ownership transfer via `move` is available for zero-cost passing when the sender is done with the data.

## Message Passing Semantics

### Copy (Default)

The sender keeps its data. The receiver gets an independent clone.

```zap
send(worker, my_list)
# my_list is still usable here — sender keeps its copy
# worker gets a completely independent copy in its own heap
```

This is the safe default. Same as Erlang. The developer doesn't need to think about ownership. Each process owns all of its data.

For primitive types (integers, floats, bools, atoms), this is a value copy — no heap allocation, effectively free.

For heap-allocated types (strings, lists, maps, structs), the data is serialized into the receiver's memory. The sender's original is untouched.

### Transfer (Explicit)

The sender gives up ownership. Zero allocation, zero copy.

```zap
send(worker, move(my_list))
# my_list is no longer usable here — compiler error if accessed
# worker takes ownership of the data directly
```

The compiler enforces that the sender cannot access `my_list` after the `move`. This is Zap's existing ownership system — `move` marks the binding as moved, and any subsequent access is a compile-time error.

This is the performance escape hatch for fire-and-forget patterns: passing a request to a worker, forwarding a message to the next pipeline stage, handing off a large data structure.

### Why Not Shared References

Shared references between processes were considered and rejected. Even with immutable data:

- One process's lifetime would affect another's memory (invisible coupling)
- You lose the ability to reason about each process independently
- Reference counting across process boundaries adds coordination overhead
- A crashed process could hold references that prevent cleanup in other processes
- It breaks the fundamental isolation guarantee

Complete isolation means: if a process crashes, nothing leaks into other processes. Each process lives and dies with its own heap.

## Process Architecture

### What a Zap Process Is

A Zap process is a green thread (Zig stackful coroutine) with:

- Its own memory arena (bump allocator or similar)
- A mailbox (`Queue(Message)`) for receiving messages
- A process ID for addressing
- Lifecycle managed by a supervisor or group

### Spawning

```zap
pid = spawn(fn() {
  receive {
    {:hello, name} -> IO.puts("Hello " <> name)
    :stop -> exit(:normal)
  }
})
```

Under the hood, `spawn` creates a green thread via `io.async()` or `io.concurrent()` with its own arena allocator.

### Receiving Messages

`Select` lets a process wait on its mailbox with pattern matching — this is Erlang's `receive`:

```zap
receive {
  {:request, data} -> handle_request(data)
  {:shutdown, reason} -> cleanup(reason)
  after 5000 -> handle_timeout()
}
```

The `after` clause maps to `Select`'s timeout capability.

### Sending Messages

```zap
send(pid, {:response, result})          # copy (default)
send(pid, move({:response, result}))    # transfer
```

## Supervision

Erlang's "let it crash" philosophy applies. Processes are cheap. If one crashes, a supervisor restarts it.

```zap
supervisor = Supervisor.start([
  {Worker, restart: :permanent},
  {Cache, restart: :transient},
])
```

`Group` from Zig's async primitives provides the lifecycle management foundation — spawn many tasks, monitor for failures, restart on crash.

## Implementation Building Blocks from Zig 0.16

| Zig 0.16 Primitive | Zap Process Model Use |
|---|---|
| `Io.Evented` green threads | Each Zap process is a green thread |
| `Queue(T)` | Process mailbox (many-producer, single-consumer per process) |
| `Future(T)` | Spawn + await for request/response patterns |
| `Group` | Supervisor managing child process lifecycles |
| `Select` | `receive` with multiple mailbox/timer sources |
| `error.Canceled` + `io.cancel()` | Process shutdown / kill signals |
| Arena allocator (per-thread) | Process-local heap isolation |

## Ownership System Integration

Zap's existing ownership annotations enforce the message passing rules at compile time:

| Annotation | Meaning for Messages |
|---|---|
| (none / default) | Value is copied into message. Sender keeps original. |
| `move` | Ownership transferred. Sender loses access. Compiler enforces. |
| `unique` | Only one owner. Can be moved into a message. |
| `shared` | **Not allowed across process boundaries.** Shared references break isolation. |
| `borrowed` | **Not allowed across process boundaries.** Borrows cannot outlive the lender's scope, and processes have independent lifetimes. |

The compiler rejects `send(pid, borrowed_ref)` and `send(pid, shared_ref)` at compile time.

## Memory Model

Each process has its own allocator. Options:

1. **Bump allocator per process** — fast allocation, freed all at once when the process exits. Simple. Works well for short-lived processes.

2. **Arena allocator per process** — same as bump but with reset capability. Good for long-lived processes that periodically clean up.

3. **General-purpose allocator per process** — standard alloc/free. For processes that need fine-grained memory control.

When a message is **copied**, the data is allocated in the receiver's arena. When a message is **moved**, the data pointer is transferred directly (the sender's arena gives up the allocation to the receiver's arena — implementation detail to work out, may require arena-to-arena transfer or a shared backing allocator).

## What Needs to Happen

### Prerequisites

1. **Upgrade Zig fork to 0.16.** Required for `Io.Evented`, green threads, `Queue`, `Select`, `Group`, `Future`.

2. **Implement `send` and `receive` as Zap language constructs.** These desugar to mailbox queue operations. `receive` with pattern matching desugars to `Select` + case expression.

3. **Implement `spawn` as a Zap language construct.** Desugars to green thread creation with arena allocation.

4. **Add compile-time enforcement** that `shared` and `borrowed` values cannot cross process boundaries via `send`.

5. **Implement message serialization/deserialization** for the copy path. Primitives are trivial. Heap types need deep copy into the receiver's arena.

6. **Implement ownership transfer** for the `move` path. The moved value's memory must become owned by the receiver's process.

### Nice to Have (Later)

- **Distributed processes** — send messages across machines (network). Requires serialization format. Can build on `Io.Evented` networking when it matures.
- **Process registry** — name processes for lookup instead of holding PIDs.
- **Supervisor trees** — hierarchical supervision with restart strategies.
- **Process linking and monitoring** — Erlang's link/monitor for crash propagation.
- **Selective receive** — receive only messages matching a pattern, leaving others in the mailbox.

## Design Decisions Still Open

1. **Mailbox ordering.** FIFO (Erlang default) or priority-based? FIFO is simpler and predictable.

2. **Mailbox overflow.** What happens when a process's mailbox is full? Block the sender? Drop messages? Signal backpressure? Erlang has unbounded mailboxes (which can cause memory issues).

3. **Message format.** Are messages always tuples/atoms (Erlang-style)? Or any Zap value? Restricting to a `Message` union type would simplify serialization.

4. **Process heap size.** Fixed initial size with growth? Or configurable per-process? Erlang starts with a small heap and grows.

5. **Move across arenas.** When `move` transfers a heap value, does the memory physically move? Or does the receiver get a pointer into the sender's arena (which breaks isolation when the sender dies)? Probably needs a copy-on-move for heap data, making `move` a zero-overhead optimization only for values that fit in registers/stack.

6. **GC per process.** Does each process have its own garbage collector? Or is the arena/bump approach sufficient? Erlang has per-process GC. Zap's ownership system may eliminate the need for GC entirely if all values have clear owners.
