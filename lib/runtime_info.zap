@doc = """
  Runtime observability: process listing, scheduler utilization,
  run-queue depths, and the message-flow trace ring (concurrency plan
  Phase 6, item 6.5 — the BEAM-operability surface of research §6.9).

  ## The concurrency runtime gate

  Like `Process`, every operation here requires the concurrency
  runtime (`runtime_concurrency: true` in the `Zap.Manifest`, or
  `-Druntime-concurrency=on`); calling any `RuntimeInfo` function in a
  gate-off build is a compile error.

  ## Consistency contract

  Nothing here stops the world. The process listing is captured
  per-process point-in-time (two entries from one capture may straddle
  a state change), mailbox depths are approximate under concurrency
  and exact at quiescence, and each scheduler getter is an independent
  snapshot. `capture_processes`/`trace_capture` copy into runtime-owned
  storage read by the indexed getters, so interleaved captures from
  concurrent processes overwrite each other — the intended discipline
  is one observing process per capture.

  Counts, indexes, depths, and nanosecond spans are `i64` (the stdlib
  integer idiom); raw pid bits are the full `u64` kernel encoding. A
  negative or past-the-count index is simply out of range — every
  getter is total.

  ## Message tracing

  Trace EMISSION is compile-time optional (`runtime_tracing: true` in
  the `Zap.Manifest`, or `-Druntime-tracing=on`; requires the
  concurrency gate). When OFF — the default — the kernel contains zero
  trace instructions and `trace_enabled()` is `false`; the read API
  stays callable and reports empty. When ON, every spawn / exit /
  send / receive / signal-delivery event is recorded into a bounded
  in-memory ring (the newest 4096 events), readable here.

  ## Examples

      count = RuntimeInfo.capture_processes()
      state = RuntimeInfo.process_state(0)      # :waiting
      depth = RuntimeInfo.run_queue_depth(0)
      busy = RuntimeInfo.scheduler_utilization_permille(0)

      if RuntimeInfo.trace_enabled() {
        events = RuntimeInfo.trace_capture()
        kind = RuntimeInfo.trace_kind(0)        # :spawn | :send | ...
      }

  """

pub struct RuntimeInfo {
  @doc = """
    Snapshot the live process set into runtime-owned storage and
    return how many processes were captured. The indexed `process_*`
    getters read this snapshot until the next capture.
    """

  pub fn capture_processes() -> i64 {
    :zig.RuntimeInfo.capture_processes()
  }

  @doc = """
    Raw pid bits of captured process `index` (0 past the captured
    count). Type them with `Process.pid` to build a sendable handle.
    """

  pub fn process_pid_bits(index :: i64) -> u64 {
    :zig.RuntimeInfo.process_pid_bits(index)
  }

  @doc = """
    Scheduling state of captured process `index` as an atom:
    `:embryo`, `:runnable`, `:running`, `:waiting`, `:blocking`,
    `:exiting` — or `:invalid` past the captured count.
    """

  pub fn process_state(index :: i64) -> Atom {
    case :zig.RuntimeInfo.process_state_code(index) {
      0 -> :embryo
      1 -> :runnable
      2 -> :running
      3 -> :waiting
      4 -> :blocking
      5 -> :exiting
      _ -> :invalid
    }
  }

  @doc = """
    Mailbox depth (queued, undelivered messages) of captured process
    `index`. Approximate under concurrency; exact at quiescence.
    """

  pub fn process_mailbox_depth(index :: i64) -> i64 {
    :zig.RuntimeInfo.process_mailbox_depth(index)
  }

  @doc = """
    Live heap bytes of captured process `index`, per its memory
    manager's `STAT` accounting (0 for a manager without one — the
    same source as `Process.heap_bytes` for the calling process).
    """

  pub fn process_heap_bytes(index :: i64) -> i64 {
    :zig.RuntimeInfo.process_heap_bytes(index)
  }

  @doc = """
    Number of scheduler cores the runtime is driving (the M:N pool's
    core count; 1 per logical CPU by default).
    """

  pub fn scheduler_count() -> i64 {
    :zig.RuntimeInfo.scheduler_count()
  }

  @doc = """
    Run-queue depth of scheduler core `core_index`: its local FIFO
    plus the just-woken LIFO slot. 0 for an out-of-range core.
    """

  pub fn run_queue_depth(core_index :: i64) -> i64 {
    :zig.RuntimeInfo.run_queue_depth(core_index)
  }

  @doc = """
    Depth of the shared global overflow run queue (work spilled from
    over-long core queues, served by idle cores).
    """

  pub fn global_run_queue_depth() -> i64 {
    :zig.RuntimeInfo.global_run_queue_depth()
  }

  @doc = """
    Wall nanoseconds scheduler core `core_index`'s run episodes have
    spanned so far — the denominator of the busy/idle utilization
    split, measured at the park/unpark boundaries.
    """

  pub fn scheduler_window_nanos(core_index :: i64) -> i64 {
    :zig.RuntimeInfo.scheduler_window_nanos(core_index)
  }

  @doc = """
    Nanoseconds of core `core_index`'s window spent parked (the idle
    futex wait — the scheduler had nothing to run).
    """

  pub fn scheduler_parked_nanos(core_index :: i64) -> i64 {
    :zig.RuntimeInfo.scheduler_parked_nanos(core_index)
  }

  @doc = """
    Nanoseconds of core `core_index`'s window spent busy: quanta,
    queue service, steal scans, and the bounded pre-park spin (the
    BEAM "active" notion of scheduler utilization).
    """

  pub fn scheduler_busy_nanos(core_index :: i64) -> i64 {
    :zig.RuntimeInfo.scheduler_busy_nanos(core_index)
  }

  @doc = """
    Utilization of core `core_index` in permille (0–1000): busy time
    over the run window. 0 when the core has not run a window yet.
    Each underlying getter is an independent snapshot, so a LIVE
    core's ratio is approximate; it is exact once the run has ended.
    """

  pub fn scheduler_utilization_permille(core_index :: i64) -> i64 {
    window = RuntimeInfo.scheduler_window_nanos(core_index)
    busy = RuntimeInfo.scheduler_busy_nanos(core_index)
    if window == 0 {
      0
    } else {
      busy * 1000 / window
    }
  }

  @doc = """
    Futex parks core `core_index` has entered (how many times the
    core genuinely slept while idle).
    """

  pub fn scheduler_park_count(core_index :: i64) -> i64 {
    :zig.RuntimeInfo.scheduler_park_count(core_index)
  }

  @doc = """
    Whether the message-flow trace instrumentation was compiled into
    this binary (`runtime_tracing: true` in the `Zap.Manifest`, or
    `-Druntime-tracing=on`). When `false`, the trace read API is
    callable but always empty.
    """

  pub fn trace_enabled() -> Bool {
    :zig.RuntimeInfo.trace_enabled()
  }

  @doc = """
    Snapshot the trace ring (oldest first, the newest 4096 events)
    into runtime-owned storage and return how many events were
    captured. Always 0 when tracing is compiled OFF. Exact at
    quiescence; a capture racing active senders may skip the oldest
    entries being overwritten in that instant.
    """

  pub fn trace_capture() -> i64 {
    :zig.RuntimeInfo.trace_capture()
  }

  @doc = """
    Global emission sequence number of captured trace event `index` —
    strictly increasing across every scheduler core, so two events
    from one capture compare by sequence.
    """

  pub fn trace_sequence(index :: i64) -> i64 {
    :zig.RuntimeInfo.trace_sequence(index)
  }

  @doc = """
    Monotonic-nanosecond timestamp of captured trace event `index`.
    """

  pub fn trace_timestamp_nanos(index :: i64) -> i64 {
    :zig.RuntimeInfo.trace_timestamp_nanos(index)
  }

  @doc = """
    Kind of captured trace event `index` as an atom: `:spawn`,
    `:exit`, `:send`, `:receive`, `:signal` — or `:invalid` past the
    captured count.
    """

  pub fn trace_kind(index :: i64) -> Atom {
    case :zig.RuntimeInfo.trace_kind_code(index) {
      1 -> :spawn
      2 -> :exit
      3 -> :send
      4 -> :receive
      5 -> :signal
      _ -> :invalid
    }
  }

  @doc = """
    Acting process's raw pid bits of captured trace event `index`
    (the spawned/exited/sending/receiving process, or the signal's
    origin).
    """

  pub fn trace_pid_bits(index :: i64) -> u64 {
    :zig.RuntimeInfo.trace_pid_bits(index)
  }

  @doc = """
    Counterparty raw pid bits of captured trace event `index`: the
    send target or the signal target; 0 when the event has none.
    """

  pub fn trace_peer_bits(index :: i64) -> u64 {
    :zig.RuntimeInfo.trace_peer_bits(index)
  }

  @doc = """
    Kind-specific detail of captured trace event `index`. Exit events:
    0 normal, 1 killed. Send events: 0 delivered, 1 dead-lettered.
    Signal events: the kernel signal kind.
    """

  pub fn trace_detail(index :: i64) -> i64 {
    :zig.RuntimeInfo.trace_detail(index)
  }

  @doc = """
    Discard every retained trace event and restart sequencing. A
    test/diagnostic aid — call at a quiescent point (concurrent
    senders may race a reset). Returns `true`.
    """

  pub fn trace_reset() -> Bool {
    :zig.RuntimeInfo.trace_reset()
  }

  @doc = """
    Total same-model O(1) region-move sends DELIVERED so far
    (binary-wide, monotone). Together with `region_move_adopt_count`
    this is the observable move-vs-copy discriminator: a `send_move`
    that fell back to the deep-copy send bumps neither counter, so a
    test expecting the move path asserts this count incremented
    across the send.
    """

  pub fn region_move_send_count() -> i64 {
    :zig.RuntimeInfo.region_move_send_count()
  }

  @doc = """
    Total moved value graphs ADOPTED by receivers so far
    (binary-wide, monotone): the receive half of the region-move
    discriminator — the payload was re-parented in place, never
    reconstructed.
    """

  pub fn region_move_adopt_count() -> i64 {
    :zig.RuntimeInfo.region_move_adopt_count()
  }
}
