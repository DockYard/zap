pub struct Concurrency.RegistryTest {
  use Zest.Case

  # The local process registry + spawn_link/spawn_monitor + send-by-name (P5-J2):
  # the ergonomic layer over the P5-J1 signal primitives. Every registering child
  # sends its parent a `:ready` ack once it has registered its name, so the parent
  # never races the registration (the tests are robust to the M:N production
  # scheduler's real cross-core concurrency). The two atomicity tests deliberately
  # spawn a child that exits IMMEDIATELY (no handshake) — only an ATOMIC
  # spawn_link/spawn_monitor (relationship established before the child can run)
  # catches the exit; a racy spawn-then-link/monitor would miss it and see
  # `:noproc` instead of the child's real reason.

  describe("register / whereis / unregister") {
    test("a registered process is found by whereis under its name") {
      server = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, server), Process.self())
      _name_to_child = Process.send(Process.pid(Atom, server), :find_me_server)
      _ready = receive Atom { :ready -> :ready }

      # The child registered :find_me_server before acking, so it resolves to it.
      assert(Process.whereis(:find_me_server) == server)

      # Clean up: kill it so its name is released (avoids cross-test leakage).
      _ref = Process.monitor(server)
      _killed = Process.kill(server)
      _down = Process.await_signal()
    }

    test("whereis of an unregistered name is 0") {
      assert(Process.whereis(:never_registered_name) == 0)
    }

    test("registering a name held by a live process fails") {
      server = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, server), Process.self())
      _name_to_child = Process.send(Process.pid(Atom, server), :taken_name)
      _ready = receive Atom { :ready -> :ready }

      # :taken_name is held by the live child, so our own registration is refused.
      assert(Process.register(:taken_name) == false)
      # The child's registration is intact.
      assert(Process.whereis(:taken_name) == server)

      _ref = Process.monitor(server)
      _killed = Process.kill(server)
      _down = Process.await_signal()
    }

    test("unregister frees a name the calling process holds") {
      _reg = Process.register(:root_owned_name)
      assert(Process.whereis(:root_owned_name) == Process.self())
      _unreg = Process.unregister(:root_owned_name)
      assert(Process.whereis(:root_owned_name) == 0)
    }
  }

  describe("register-then-crash") {
    test("a crashed registered process auto-unregisters its name") {
      server = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _self_to_child = Process.send(Process.pid(u64, server), Process.self())
      _name_to_child = Process.send(Process.pid(Atom, server), :crash_and_free)
      _ready = receive Atom { :ready -> :ready }
      assert(Process.whereis(:crash_and_free) == server)   # registered while alive

      # Crash it and wait for its teardown to complete (the DOWN fires AFTER the
      # name is released — teardown releases the name before propagating signals).
      _ref = Process.monitor(server)
      _killed = Process.kill(server)
      _down = Process.await_signal()
      assert(Process.last_signal_kind() == 2)              # DOWN — the child is gone

      # The register-then-crash race is resolved: the name is free again.
      assert(Process.whereis(:crash_and_free) == 0)
      # And it is genuinely re-registrable (the entry was physically released, not
      # merely liveness-masked) — a fresh server claims the same name.
      successor = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _self_to_successor = Process.send(Process.pid(u64, successor), Process.self())
      _name_to_successor = Process.send(Process.pid(Atom, successor), :crash_and_free)
      _successor_ready = receive Atom { :ready -> :ready }
      assert(Process.whereis(:crash_and_free) == successor)

      _successor_ref = Process.monitor(successor)
      _kill_successor = Process.kill(successor)
      _successor_down = Process.await_signal()
    }
  }

  describe("spawn_link / spawn_monitor atomicity") {
    test("spawn_link is atomic — an immediately-exiting child still delivers EXIT") {
      _trap = Process.trap_exit(true)
      # The child exits abnormally the instant it runs — no ack handshake. Only an
      # atomic spawn_link (link established BEFORE the child can run) delivers the
      # child's REAL reason; a racy link-after-spawn would see :noproc.
      child = Process.spawn_link(&Concurrency.RegistryTest.immediate_crash_entry/0)

      reason = Process.await_signal()
      assert(reason == :immediate_boom)                    # the real reason, not :noproc
      assert(Process.last_signal_kind() == 1)              # EXIT (trapped)
      assert(Process.last_signal_from() == child)
    }

    test("spawn_monitor returns a working {pid, ref} that fires DOWN with the real reason") {
      # The child exits NORMALLY the instant it runs. An atomic spawn_monitor
      # still delivers a DOWN carrying :normal (a racy monitor-after-spawn would
      # fire :noproc for a child that already exited).
      {child, ref} = Process.spawn_monitor(&Concurrency.RegistryTest.immediate_normal_exit_entry/0)

      reason = Process.await_signal()
      assert(reason == :normal)                            # the real reason, not :noproc
      assert(Process.last_signal_kind() == 2)              # DOWN
      assert(Process.last_signal_ref() == ref)             # the ref spawn_monitor returned
      assert(Process.last_signal_from() == child)
    }
  }

  describe("send-by-name") {
    test("send-by-name reaches a live registered process") {
      server = Process.spawn(&Concurrency.RegistryTest.echo_by_name_entry/0)
      _self_to_child = Process.send(Process.pid(u64, server), Process.self())
      _name_to_child = Process.send(Process.pid(Atom, server), :echo_by_name)
      _ready = receive Atom { :ready -> :ready }

      # Send by NAME (not pid): resolves :echo_by_name then delivers.
      delivered = Process.send(:echo_by_name, 99)
      assert(delivered == true)
      echoed = receive i64 { n -> n }
      assert(echoed == 99)
    }

    test("send-by-name to an unregistered name is dead-lettered, not an error") {
      # No process is registered under :nobody_home; the send dead-letters and
      # returns false (Erlang semantics — not a crash).
      assert(Process.send(:nobody_home, 7) == false)
    }
  }

  describe("cross-core registry (M:N)") {
    test("concurrent self-registering children resolve, then free their names on teardown") {
      # Three children register three distinct names on (up to) three cores —
      # cross-core registrations the root's whereis (also cross-core) must see.
      first = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _first_self = Process.send(Process.pid(u64, first), Process.self())
      _first_name = Process.send(Process.pid(Atom, first), :core_race_one)
      _first_ready = receive Atom { :ready -> :ready }

      second = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _second_self = Process.send(Process.pid(u64, second), Process.self())
      _second_name = Process.send(Process.pid(Atom, second), :core_race_two)
      _second_ready = receive Atom { :ready -> :ready }

      third = Process.spawn(&Concurrency.RegistryTest.registering_blocker_entry/0)
      _third_self = Process.send(Process.pid(u64, third), Process.self())
      _third_name = Process.send(Process.pid(Atom, third), :core_race_three)
      _third_ready = receive Atom { :ready -> :ready }

      # All three cross-core registrations are visible to the root's lookups.
      assert(Process.whereis(:core_race_one) == first)
      assert(Process.whereis(:core_race_two) == second)
      assert(Process.whereis(:core_race_three) == third)

      # Tear all three down (their teardowns run on their own cores, releasing
      # their names cross-core), and monitor so we know when each has completed.
      _first_ref = Process.monitor(first)
      _second_ref = Process.monitor(second)
      _third_ref = Process.monitor(third)
      _kill_first = Process.kill(first)
      _kill_second = Process.kill(second)
      _kill_third = Process.kill(third)
      _down_a = Process.await_signal()
      _down_b = Process.await_signal()
      _down_c = Process.await_signal()

      # Every name is freed by its owner's cross-core teardown.
      assert(Process.whereis(:core_race_one) == 0)
      assert(Process.whereis(:core_race_two) == 0)
      assert(Process.whereis(:core_race_three) == 0)
    }
  }

  # -- child process entries -------------------------------------------------

  # Receives the parent pid then a name atom, REGISTERS itself under the name,
  # acks :ready, then blocks forever (until the parent kills it). The workhorse
  # for the register/whereis/crash/cross-core tests.
  pub fn registering_blocker_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    name = Process.receive_raw(Atom)
    _registered = Process.register(name)
    _ready = Process.send(parent, :ready)
    _block = receive Atom { :never -> :never }
    nil
  }

  # Exits ABNORMALLY the instant it runs, with no handshake — the spawn_link
  # atomicity probe (a racy link-after-spawn would miss this immediate exit).
  pub fn immediate_crash_entry() -> Nil {
    Process.exit_with(:immediate_boom)
  }

  # Returns (a NORMAL exit) the instant it runs — the spawn_monitor atomicity
  # probe (a racy monitor-after-spawn would fire :noproc for this immediate exit).
  pub fn immediate_normal_exit_entry() -> Nil {
    nil
  }

  # Receives the parent pid then a name, registers under it, acks, then echoes one
  # i64 back to the parent — the send-by-name target (reached via its NAME).
  pub fn echo_by_name_entry() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    name = Process.receive_raw(Atom)
    _registered = Process.register(name)
    _ready = Process.send(Process.pid(Atom, parent.raw), :ready)
    value = receive i64 { n -> n }
    _echoed = Process.send(parent, value)
    nil
  }
}
