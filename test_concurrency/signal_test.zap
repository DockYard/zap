pub struct TestConcurrency.SignalTest {
  use Zest.Case

  # Erlang-fidelity semantics for the kernel signal primitives (P5-J1): links,
  # monitors, exit signals, trap_exit. Every child is set up to send its parent a
  # `:ready` ack once it has installed its links/monitors/trap flag, so the parent
  # never triggers a death before the relationship is in place (the tests are
  # robust to the M:N production scheduler's real cross-core concurrency). The
  # parent observes deaths either by TRAPPING (an `{'EXIT', …}` via `await_signal`)
  # or by MONITORING (a `{'DOWN', …}` via `await_signal`).

  describe("links and trap_exit") {
    test("trap_exit converts a linked abnormal exit into an EXIT message with the reason") {
      target = Process.spawn(&TestConcurrency.SignalTest.blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      _trap = Process.trap_exit(true)
      _linked = Process.link(target)
      # Trigger the (non-trapping) target's abnormal death; its exit propagates
      # back to us over the link. Because we trap, it arrives as a message.
      _killed = Process.exit_signal(target, :boom)

      reason = Process.await_signal()
      assert(reason == :boom)
      assert(Process.last_signal_kind() == 1)     # 1 = exit
      assert(Process.last_signal_from() == target)
    }

    test("a non-trapping linked process DIES with the propagated reason (cascade)") {
      victim = Process.spawn(&TestConcurrency.SignalTest.blocker_entry/0)
      _victim_self = Process.send(Process.pid(u64, victim), Process.self())
      _victim_ready = receive Atom { :ready -> :ready }

      # A worker that links the victim (non-trapping) and then blocks.
      worker = Process.spawn(&TestConcurrency.SignalTest.linker_entry/0)
      _worker_self = Process.send(Process.pid(u64, worker), Process.self())
      _worker_victim = Process.send(Process.pid(u64, worker), victim)
      _worker_ready = receive Atom { :ready -> :ready }

      # We monitor the worker so we observe its death.
      _ref = Process.monitor(worker)
      # Kill the victim abnormally; :boom cascades to the linked non-trapping
      # worker, which dies with :boom, firing our DOWN.
      _killed = Process.exit_signal(victim, :boom)

      reason = Process.await_signal()
      assert(reason == :boom)
      assert(Process.last_signal_kind() == 2)     # 2 = down
      assert(Process.last_signal_from() == worker)
    }

    test("a NORMAL exit does not kill a non-trapping linked process") {
      # The worker links a victim that will exit NORMALLY; the worker must
      # survive (normal exits do not propagate a kill).
      victim = Process.spawn(&TestConcurrency.SignalTest.normal_exit_after_go_entry/0)
      _victim_self = Process.send(Process.pid(u64, victim), Process.self())
      _victim_ready = receive Atom { :ready -> :ready }

      worker = Process.spawn(&TestConcurrency.SignalTest.ping_linker_entry/0)
      _worker_self = Process.send(Process.pid(u64, worker), Process.self())
      _worker_victim = Process.send(Process.pid(u64, worker), victim)
      _worker_ready = receive Atom { :ready -> :ready }

      # Let the victim exit normally.
      _go = Process.send(Process.pid(Atom, victim), :go)
      # The worker is still alive: it answers a ping (a dead worker would
      # dead-letter the ping and never reply).
      _ping = Process.send(Process.pid(Atom, worker), :ping)
      pong = receive Atom { :pong -> :pong }
      assert(pong == :pong)
    }

    test("link is idempotent — a linked abnormal exit delivers exactly one EXIT") {
      target = Process.spawn(&TestConcurrency.SignalTest.blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      _trap = Process.trap_exit(true)
      _l1 = Process.link(target)
      _l2 = Process.link(target)     # idempotent — one-per-pair
      _ref = Process.monitor(target) # also monitor, so a DOWN follows the EXIT

      _killed = Process.exit_signal(target, :boom)

      # The dying process propagates links BEFORE monitors, and both are from the
      # same sender (FIFO), so the sequence is exactly [EXIT, DOWN]. If the link
      # were duplicated, a SECOND EXIT would precede the DOWN and the second
      # signal below would be an exit, not a down.
      first = Process.await_signal()
      assert(first == :boom)
      assert(Process.last_signal_kind() == 1)     # exit
      second = Process.await_signal()
      assert(second == :boom)
      assert(Process.last_signal_kind() == 2)     # down — proves only one EXIT
    }

    test("unlink stops link propagation (the monitor DOWN still fires)") {
      target = Process.spawn(&TestConcurrency.SignalTest.blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      _trap = Process.trap_exit(true)
      _linked = Process.link(target)
      _unlinked = Process.unlink(target)
      _ref = Process.monitor(target)

      _killed = Process.exit_signal(target, :boom)

      # With the link broken, no EXIT precedes the DOWN (links propagate before
      # monitors, same sender FIFO): the first — and only — signal is the DOWN.
      down_reason = Process.await_signal()
      assert(down_reason == :boom)
      assert(Process.last_signal_kind() == 2)     # down, not exit
    }
  }

  describe("monitors") {
    test("monitor delivers a DOWN with the exit reason") {
      target = Process.spawn(&TestConcurrency.SignalTest.normal_exit_after_go_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      _ref = Process.monitor(target)
      _go = Process.send(Process.pid(Atom, target), :go)   # target exits normally

      reason = Process.await_signal()
      assert(reason == :normal)
      assert(Process.last_signal_kind() == 2)              # down
      assert(Process.last_signal_from() == target)
    }

    test("monitors are stackable — two monitors deliver two distinct DOWNs") {
      target = Process.spawn(&TestConcurrency.SignalTest.normal_exit_after_go_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      ref_one = Process.monitor(target)
      ref_two = Process.monitor(target)
      assert(ref_one != ref_two)                           # unique refs
      _go = Process.send(Process.pid(Atom, target), :go)

      _first_reason = Process.await_signal()
      got_one = Process.last_signal_ref()
      _second_reason = Process.await_signal()
      got_two = Process.last_signal_ref()
      # Two independent DOWNs arrived, one per ref (order unspecified).
      assert(got_one != got_two)
      matched = (got_one == ref_one and got_two == ref_two) or (got_one == ref_two and got_two == ref_one)
      assert(matched)
    }

    test("monitoring an already-dead process fires noproc immediately") {
      target = Process.spawn(&TestConcurrency.SignalTest.normal_exit_after_go_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      # First monitor while alive: let it exit, then observe the DOWN — after
      # which the target is DEFINITIVELY dead (the DOWN fired at its teardown).
      _ref_live = Process.monitor(target)
      _go = Process.send(Process.pid(Atom, target), :go)
      alive_reason = Process.await_signal()
      assert(alive_reason == :normal)

      # The target is now dead; a fresh monitor fires noproc at once.
      _ref_dead = Process.monitor(target)
      dead_reason = Process.await_signal()
      assert(dead_reason == :noproc)
      assert(Process.last_signal_kind() == 2)              # down
    }

    test("demonitor drops a monitor so no DOWN arrives (a live monitor still fires)") {
      target = Process.spawn(&TestConcurrency.SignalTest.normal_exit_after_go_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      dropped_ref = Process.monitor(target)
      kept_ref = Process.monitor(target)
      _demonitored = Process.demonitor(dropped_ref)
      _go = Process.send(Process.pid(Atom, target), :go)

      # Only the kept monitor fires; its ref is the one we get.
      _reason = Process.await_signal()
      assert(Process.last_signal_ref() == kept_ref)
    }
  }

  describe("kill and reason rules") {
    test("kill is untrappable — a trapping process still dies, reason killed") {
      target = Process.spawn(&TestConcurrency.SignalTest.trap_blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      _ref = Process.monitor(target)
      _killed = Process.kill(target)   # untrappable, even though the target traps

      reason = Process.await_signal()
      assert(reason == :killed)
      assert(Process.last_signal_kind() == 2)   # down, target died despite trapping
      assert(Process.last_signal_from() == target)
    }

    test("exit_with self-terminates abnormally, delivering the reason to a monitor") {
      target = Process.spawn(&TestConcurrency.SignalTest.self_exit_after_go_entry/0)
      _self_to_child = Process.send(Process.pid(u64, target), Process.self())
      _ready = receive Atom { :ready -> :ready }

      _ref = Process.monitor(target)
      _go = Process.send(Process.pid(Atom, target), :go)   # target calls exit_with(:mycrash)

      reason = Process.await_signal()
      assert(reason == :mycrash)
      assert(Process.last_signal_from() == target)
    }
  }

  describe("exit-signal ordering") {
    test("an exit signal preserves pairwise FIFO with the sender's messages") {
      # The sender links us, sends 100 then 200, then exits normally. Because we
      # trap and are linked, its exit arrives as an {'EXIT', …} MERGED after its
      # two messages in strict per-sender FIFO order.
      _trap = Process.trap_exit(true)
      sender = Process.spawn(&TestConcurrency.SignalTest.fifo_sender_entry/0)
      _linked = Process.link(sender)
      _self_to_child = Process.send(Process.pid(u64, sender), Process.self())

      first = receive i64 { n -> n }
      second = receive i64 { n -> n }
      exit_reason = Process.await_signal()
      assert(first == 100)
      assert(second == 200)
      assert(exit_reason == :normal)
      assert(Process.last_signal_from() == sender)
    }
  }

  # -- child process entries -------------------------------------------------

  # Receives the parent pid, acks :ready, then blocks forever (until the parent
  # kills or exit-signals it).
  pub fn blocker_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _ready = Process.send(parent, :ready)
    _block = receive Atom { :never -> :never }
    nil
  }

  # As `blocker_entry`, but traps exits first — used to prove `kill` is
  # untrappable (this process still dies on `Process.kill`).
  pub fn trap_blocker_entry() -> Nil {
    _trap = Process.trap_exit(true)
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _ready = Process.send(parent, :ready)
    _block = receive Atom { :never -> :never }
    nil
  }

  # Receives the parent pid then a victim pid, LINKS the victim, acks, and blocks
  # (so it dies when the victim's abnormal exit cascades over the link).
  pub fn linker_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    victim = Process.receive_raw(u64)
    _linked = Process.link(victim)
    _ready = Process.send(parent, :ready)
    _block = receive Atom { :never -> :never }
    nil
  }

  # Links a victim, acks, then serves pings — used to prove a NORMAL exit of the
  # linked victim leaves this (non-trapping) process alive and responsive.
  pub fn ping_linker_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    victim = Process.receive_raw(u64)
    _linked = Process.link(victim)
    _ready = Process.send(parent, :ready)
    reply_to = receive Atom { :ping -> parent }
    _pong = Process.send(reply_to, :pong)
    nil
  }

  # Acks, waits for :go, then returns (a NORMAL exit).
  pub fn normal_exit_after_go_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _ready = Process.send(parent, :ready)
    _go = receive Atom { :go -> :go }
    nil
  }

  # Acks, waits for :go, then self-terminates ABNORMALLY with :mycrash.
  pub fn self_exit_after_go_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _ready = Process.send(parent, :ready)
    _go = receive Atom { :go -> :go }
    Process.exit_with(:mycrash)
  }

  # Receives the parent pid, sends 100 then 200, and returns normally — the exit
  # of this (linked) sender merges after its two messages for a trapping parent.
  pub fn fifo_sender_entry() -> Nil {
    parent = Process.receive_raw(u64)
    _first = Process.send(Process.pid(i64, parent), 100)
    _second = Process.send(Process.pid(i64, parent), 200)
    nil
  }
}
