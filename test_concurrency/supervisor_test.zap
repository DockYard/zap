@doc = """
  Erlang/OTP-fidelity semantics for the PURE-ZAP `Supervisor` (`lib/supervisor.zap`),
  built over the P5-J1/J2 signal intrinsics. Every child registers a name so a
  restart is observable as a CHANGED pid (a fresh process), and the supervisor's
  child-start callback (`dispatch`) sends the test — registered as
  `:sup_observer` — the child's id AFTER the readiness handshake completes, so a
  notification means the supervisor is past the handshake and the child is safe
  to kill without racing it.

  Teardown is observed by parking on `receive … after` (which yields the fiber to
  the scheduler so the supervisor can run) rather than a thread-blocking sleep.
  """

pub struct TestConcurrency.SupervisorTest {
  use Zest.Case

  describe("restart strategies") {
    test("one_for_one restarts only the crashed child") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.ofo_sup/0)
      _s1 = TestConcurrency.SupervisorTest.recv()
      _s2 = TestConcurrency.SupervisorTest.recv()
      a0 = Process.whereis(:ofo_a)
      b0 = Process.whereis(:ofo_b)
      _kill = Process.exit_signal(a0, :boom)
      _r = receive Atom { :ofo_a -> :ok }
      a1 = Process.whereis(:ofo_a)
      b1 = Process.whereis(:ofo_b)
      assert(a1 != a0)
      assert(a1 != 0)
      assert(b1 == b0)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("rest_for_one restarts the crashed child and every child started after it") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.rfo_sup/0)
      _s1 = TestConcurrency.SupervisorTest.recv()
      _s2 = TestConcurrency.SupervisorTest.recv()
      _s3 = TestConcurrency.SupervisorTest.recv()
      a0 = Process.whereis(:rfo_a)
      b0 = Process.whereis(:rfo_b)
      c0 = Process.whereis(:rfo_c)
      _kill = Process.exit_signal(b0, :boom)
      _r1 = TestConcurrency.SupervisorTest.recv()
      _r2 = TestConcurrency.SupervisorTest.recv()
      a1 = Process.whereis(:rfo_a)
      b1 = Process.whereis(:rfo_b)
      c1 = Process.whereis(:rfo_c)
      assert(a1 == a0)
      assert(b1 != b0)
      assert(c1 != c0)
      assert(b1 != 0)
      assert(c1 != 0)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("one_for_all restarts every child when any child crashes") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.ofa_sup/0)
      _s1 = TestConcurrency.SupervisorTest.recv()
      _s2 = TestConcurrency.SupervisorTest.recv()
      _s3 = TestConcurrency.SupervisorTest.recv()
      a0 = Process.whereis(:ofa_a)
      b0 = Process.whereis(:ofa_b)
      c0 = Process.whereis(:ofa_c)
      _kill = Process.exit_signal(b0, :boom)
      _r1 = TestConcurrency.SupervisorTest.recv()
      _r2 = TestConcurrency.SupervisorTest.recv()
      _r3 = TestConcurrency.SupervisorTest.recv()
      a1 = Process.whereis(:ofa_a)
      b1 = Process.whereis(:ofa_b)
      c1 = Process.whereis(:ofa_c)
      assert(a1 != a0)
      assert(b1 != b0)
      assert(c1 != c0)
      assert(a1 != 0)
      assert(b1 != 0)
      assert(c1 != 0)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("simple_one_for_one restarts only the crashed homogeneous instance") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.sofo_sup/0)
      _s1 = TestConcurrency.SupervisorTest.recv()
      _s2 = TestConcurrency.SupervisorTest.recv()
      _s3 = TestConcurrency.SupervisorTest.recv()
      i0 = Process.whereis(:sofo_0)
      i1 = Process.whereis(:sofo_1)
      i2 = Process.whereis(:sofo_2)
      _kill = Process.exit_signal(i1, :boom)
      _r = receive Atom { :sofo_1 -> :ok }
      j0 = Process.whereis(:sofo_0)
      j1 = Process.whereis(:sofo_1)
      j2 = Process.whereis(:sofo_2)
      assert(j1 != i1)
      assert(j1 != 0)
      assert(j0 == i0)
      assert(j2 == i2)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("restart types") {
    test("a permanent child is always restarted") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.perm_sup/0)
      _s = TestConcurrency.SupervisorTest.recv()
      p0 = Process.whereis(:perm)
      _k1 = Process.exit_signal(p0, :boom)
      _r1 = receive Atom { :perm -> :ok }
      p1 = Process.whereis(:perm)
      _k2 = Process.send(Process.pid(Atom, p1), :go)
      _r2 = receive Atom { :perm -> :ok }
      p2 = Process.whereis(:perm)
      assert(p1 != p0)
      assert(p2 != p1)
      assert(p2 != 0)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("a temporary child is never restarted") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.temp_sup/0)
      _s = TestConcurrency.SupervisorTest.recv()
      t0 = Process.whereis(:temp)
      _k = Process.exit_signal(t0, :boom)
      not_restarted = receive Atom { :temp -> false after 200 -> true }
      assert(not_restarted)
      assert(Process.whereis(:temp) == 0)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("a transient child restarts on an abnormal exit but not a normal one") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.trans_sup/0)
      _s1 = TestConcurrency.SupervisorTest.recv()
      _s2 = TestConcurrency.SupervisorTest.recv()
      abnormal0 = Process.whereis(:trans)
      normal0 = Process.whereis(:transn)
      _kill = Process.exit_signal(abnormal0, :boom)
      _r = receive Atom { :trans -> :ok }
      abnormal1 = Process.whereis(:trans)
      assert(abnormal1 != abnormal0)
      assert(abnormal1 != 0)
      _go = Process.send(Process.pid(Atom, normal0), :go)
      normal_not_restarted = receive Atom { :transn -> false after 200 -> true }
      assert(normal_not_restarted)
      assert(Process.whereis(:transn) == 0)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("restart intensity (the crash-loop breaker)") {
    test("more restarts than the intensity within the period terminates the supervisor") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.intensity_sup/0)
      _s = TestConcurrency.SupervisorTest.recv()
      c0 = Process.whereis(:ic)
      _k1 = Process.exit_signal(c0, :boom)
      _r = TestConcurrency.SupervisorTest.recv()
      c1 = Process.whereis(:ic)
      assert(c1 != c0)
      _k2 = Process.exit_signal(c1, :boom)
      # Intensity 1 tolerates one restart; the second crash within the period
      # trips the breaker: no third start arrives and the supervisor terminates.
      no_third = receive Atom { :ic -> false after 400 -> true }
      assert(no_third)
      assert(TestConcurrency.SupervisorTest.wait_gone(:ic_sup, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:ic, 100))
      TestConcurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("child order") {
    test("children start left-to-right and terminate right-to-left") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.order_sup/0)
      start_one = TestConcurrency.SupervisorTest.recv()
      start_two = TestConcurrency.SupervisorTest.recv()
      start_three = TestConcurrency.SupervisorTest.recv()
      assert(start_one == :ord_a)
      assert(start_two == :ord_b)
      assert(start_three == :ord_c)
      _term = Process.exit_signal(sup, :shutdown)
      term_one = TestConcurrency.SupervisorTest.recv()
      term_two = TestConcurrency.SupervisorTest.recv()
      term_three = TestConcurrency.SupervisorTest.recv()
      assert(term_one == :ord_c_down)
      assert(term_two == :ord_b_down)
      assert(term_three == :ord_a_down)
      TestConcurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("shutdown protocols") {
    test("brutal_kill terminates even a trapping child immediately") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.brutal_sup/0)
      _s = TestConcurrency.SupervisorTest.recv()
      _term = Process.exit_signal(sup, :shutdown)
      assert(TestConcurrency.SupervisorTest.wait_gone(:bk, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:bk_sup, 100))
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("a timeout shutdown kills a child that ignores the shutdown request") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.timeout_sup/0)
      _s = TestConcurrency.SupervisorTest.recv()
      _term = Process.exit_signal(sup, :shutdown)
      got_shutdown = TestConcurrency.SupervisorTest.recv()
      assert(got_shutdown == :to_asked)
      assert(TestConcurrency.SupervisorTest.wait_gone(:to, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:to_sup, 100))
      TestConcurrency.SupervisorTest.cleanup(sup)
    }

    test("an infinity shutdown waits for the child to exit gracefully") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.infinity_sup/0)
      _s = TestConcurrency.SupervisorTest.recv()
      _term = Process.exit_signal(sup, :shutdown)
      graceful = TestConcurrency.SupervisorTest.recv()
      assert(graceful == :inf_graceful)
      assert(TestConcurrency.SupervisorTest.wait_gone(:inf, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:inf_sup, 100))
      TestConcurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("supervision trees") {
    test("a nested supervisor tree tears its whole subtree down") {
      sup = TestConcurrency.SupervisorTest.start(&TestConcurrency.SupervisorTest.parent_sup/0)
      _n1 = TestConcurrency.SupervisorTest.recv()
      _n2 = TestConcurrency.SupervisorTest.recv()
      _n3 = TestConcurrency.SupervisorTest.recv()
      assert(Process.whereis(:child_sup) != 0)
      assert(Process.whereis(:nest_w1) != 0)
      assert(Process.whereis(:nest_w2) != 0)
      _term = Process.exit_signal(sup, :shutdown)
      assert(TestConcurrency.SupervisorTest.wait_gone(:nest_w1, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:nest_w2, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:child_sup, 100))
      assert(TestConcurrency.SupervisorTest.wait_gone(:parent_sup, 100))
      TestConcurrency.SupervisorTest.cleanup(sup)
    }
  }

  # -- the inverted-control supervisor loop: init, then drive Supervisor.step,
  # -- calling the LOCAL dispatch for each child to (re)start (no function value
  # -- threaded through the library) and feeding the pid back with installed --

  fn run(children :: List(SupervisorChildSpec), options :: SupervisorOptions) -> Nil {
    state = Supervisor.init(children, options)
    TestConcurrency.SupervisorTest.sup_loop(state)
  }

  fn sup_loop(state :: SupervisorState) -> Nil {
    current = Supervisor.step(state)
    case current.action {
      :start ->
        TestConcurrency.SupervisorTest.sup_loop(Supervisor.installed(current.state, current.child_id, TestConcurrency.SupervisorTest.dispatch(current.child_id)))
      :stop ->
        Process.exit_with(current.reason)
      _ ->
        TestConcurrency.SupervisorTest.sup_loop(current.state)
    }
  }

  # -- the child starter: start every child by id, notifying the observer AFTER
  # -- the readiness handshake so a notification is a safe-to-kill signal --

  pub fn dispatch(child_id :: Atom) -> u64 {
    child = case child_id {
      :ofo_a -> Process.spawn_link(&TestConcurrency.SupervisorTest.ofo_a_entry/0)
      :ofo_b -> Process.spawn_link(&TestConcurrency.SupervisorTest.ofo_b_entry/0)
      :rfo_a -> Process.spawn_link(&TestConcurrency.SupervisorTest.rfo_a_entry/0)
      :rfo_b -> Process.spawn_link(&TestConcurrency.SupervisorTest.rfo_b_entry/0)
      :rfo_c -> Process.spawn_link(&TestConcurrency.SupervisorTest.rfo_c_entry/0)
      :ofa_a -> Process.spawn_link(&TestConcurrency.SupervisorTest.ofa_a_entry/0)
      :ofa_b -> Process.spawn_link(&TestConcurrency.SupervisorTest.ofa_b_entry/0)
      :ofa_c -> Process.spawn_link(&TestConcurrency.SupervisorTest.ofa_c_entry/0)
      :sofo_0 -> Process.spawn_link(&TestConcurrency.SupervisorTest.sofo_0_entry/0)
      :sofo_1 -> Process.spawn_link(&TestConcurrency.SupervisorTest.sofo_1_entry/0)
      :sofo_2 -> Process.spawn_link(&TestConcurrency.SupervisorTest.sofo_2_entry/0)
      :perm -> Process.spawn_link(&TestConcurrency.SupervisorTest.perm_entry/0)
      :temp -> Process.spawn_link(&TestConcurrency.SupervisorTest.temp_entry/0)
      :trans -> Process.spawn_link(&TestConcurrency.SupervisorTest.trans_entry/0)
      :transn -> Process.spawn_link(&TestConcurrency.SupervisorTest.transn_entry/0)
      :ic -> Process.spawn_link(&TestConcurrency.SupervisorTest.ic_entry/0)
      :ord_a -> Process.spawn_link(&TestConcurrency.SupervisorTest.ord_a_entry/0)
      :ord_b -> Process.spawn_link(&TestConcurrency.SupervisorTest.ord_b_entry/0)
      :ord_c -> Process.spawn_link(&TestConcurrency.SupervisorTest.ord_c_entry/0)
      :bk -> Process.spawn_link(&TestConcurrency.SupervisorTest.bk_entry/0)
      :to -> Process.spawn_link(&TestConcurrency.SupervisorTest.to_entry/0)
      :inf -> Process.spawn_link(&TestConcurrency.SupervisorTest.inf_entry/0)
      :nest_w1 -> Process.spawn_link(&TestConcurrency.SupervisorTest.nest_w1_entry/0)
      :nest_w2 -> Process.spawn_link(&TestConcurrency.SupervisorTest.nest_w2_entry/0)
      _ -> Process.spawn_link(&TestConcurrency.SupervisorTest.child_sup_entry/0)
    }
    _give = Process.send(Process.pid(u64, child), Process.self())
    _ready = receive Atom { :ready -> :ready }
    _notify = Process.send(:sup_observer, child_id)
    child
  }

  # -- supervisor entry points (each registers a name for liveness observation) --

  pub fn ofo_sup() -> Nil {
    _reg = Process.register(:ofo_sup)
    children = [Supervisor.worker(:ofo_a), Supervisor.worker(:ofo_b)]
    TestConcurrency.SupervisorTest.run(children, Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn rfo_sup() -> Nil {
    _reg = Process.register(:rfo_sup)
    children = [Supervisor.worker(:rfo_a), Supervisor.worker(:rfo_b), Supervisor.worker(:rfo_c)]
    TestConcurrency.SupervisorTest.run(children, Supervisor.options(:rest_for_one, 9, 5000))
  }

  pub fn ofa_sup() -> Nil {
    _reg = Process.register(:ofa_sup)
    children = [Supervisor.worker(:ofa_a), Supervisor.worker(:ofa_b), Supervisor.worker(:ofa_c)]
    TestConcurrency.SupervisorTest.run(children, Supervisor.options(:one_for_all, 9, 5000))
  }

  pub fn sofo_sup() -> Nil {
    _reg = Process.register(:sofo_sup)
    zero = Supervisor.child_spec(:sofo_0, :permanent, :timeout, 5000, :worker)
    one = Supervisor.child_spec(:sofo_1, :permanent, :timeout, 5000, :worker)
    two = Supervisor.child_spec(:sofo_2, :permanent, :timeout, 5000, :worker)
    TestConcurrency.SupervisorTest.run([zero, one, two], Supervisor.options(:simple_one_for_one, 9, 5000))
  }

  pub fn perm_sup() -> Nil {
    _reg = Process.register(:perm_sup)
    TestConcurrency.SupervisorTest.run([Supervisor.worker(:perm)], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn temp_sup() -> Nil {
    _reg = Process.register(:temp_sup)
    TestConcurrency.SupervisorTest.run([Supervisor.worker(:temp, :temporary)], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn trans_sup() -> Nil {
    _reg = Process.register(:trans_sup)
    children = [Supervisor.worker(:trans, :transient), Supervisor.worker(:transn, :transient)]
    TestConcurrency.SupervisorTest.run(children, Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn intensity_sup() -> Nil {
    _reg = Process.register(:ic_sup)
    TestConcurrency.SupervisorTest.run([Supervisor.worker(:ic)], Supervisor.options(:one_for_one, 1, 5000))
  }

  pub fn order_sup() -> Nil {
    _reg = Process.register(:ord_sup)
    a = Supervisor.child_spec(:ord_a, :permanent, :infinity, 0, :worker)
    b = Supervisor.child_spec(:ord_b, :permanent, :infinity, 0, :worker)
    c = Supervisor.child_spec(:ord_c, :permanent, :infinity, 0, :worker)
    TestConcurrency.SupervisorTest.run([a, b, c], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn brutal_sup() -> Nil {
    _reg = Process.register(:bk_sup)
    TestConcurrency.SupervisorTest.run([Supervisor.brutal_worker(:bk)], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn timeout_sup() -> Nil {
    _reg = Process.register(:to_sup)
    spec = Supervisor.child_spec(:to, :permanent, :timeout, 50, :worker)
    TestConcurrency.SupervisorTest.run([spec], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn infinity_sup() -> Nil {
    _reg = Process.register(:inf_sup)
    spec = Supervisor.child_spec(:inf, :permanent, :infinity, 0, :worker)
    TestConcurrency.SupervisorTest.run([spec], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn parent_sup() -> Nil {
    _reg = Process.register(:parent_sup)
    TestConcurrency.SupervisorTest.run([Supervisor.supervisor(:child_sup)], Supervisor.options(:one_for_one, 9, 5000))
  }

  # A nested child supervisor: ack the parent's handshake, then run its own
  # subtree of two workers.
  pub fn child_sup_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _reg = Process.register(:child_sup)
    _ready = Process.send(parent, :ready)
    children = [Supervisor.worker(:nest_w1), Supervisor.worker(:nest_w2)]
    TestConcurrency.SupervisorTest.run(children, Supervisor.options(:one_for_one, 9, 5000))
  }

  # -- child process entries ------------------------------------------------

  pub fn ofo_a_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:ofo_a) }
  pub fn ofo_b_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:ofo_b) }
  pub fn rfo_a_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:rfo_a) }
  pub fn rfo_b_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:rfo_b) }
  pub fn rfo_c_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:rfo_c) }
  pub fn ofa_a_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:ofa_a) }
  pub fn ofa_b_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:ofa_b) }
  pub fn ofa_c_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:ofa_c) }
  pub fn sofo_0_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:sofo_0) }
  pub fn sofo_1_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:sofo_1) }
  pub fn sofo_2_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:sofo_2) }
  pub fn perm_entry() -> Nil { TestConcurrency.SupervisorTest.exit_on_go_body(:perm) }
  pub fn temp_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:temp) }
  pub fn trans_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:trans) }
  pub fn ic_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:ic) }
  pub fn nest_w1_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:nest_w1) }
  pub fn nest_w2_entry() -> Nil { TestConcurrency.SupervisorTest.worker_body(:nest_w2) }

  pub fn transn_entry() -> Nil { TestConcurrency.SupervisorTest.exit_on_go_body(:transn) }

  pub fn ord_a_entry() -> Nil { TestConcurrency.SupervisorTest.terminating_body(:ord_a, :ord_a_down) }
  pub fn ord_b_entry() -> Nil { TestConcurrency.SupervisorTest.terminating_body(:ord_b, :ord_b_down) }
  pub fn ord_c_entry() -> Nil { TestConcurrency.SupervisorTest.terminating_body(:ord_c, :ord_c_down) }

  pub fn bk_entry() -> Nil { TestConcurrency.SupervisorTest.trapping_blocker_body(:bk) }
  pub fn to_entry() -> Nil { TestConcurrency.SupervisorTest.ignore_shutdown_body(:to, :to_asked) }
  pub fn inf_entry() -> Nil { TestConcurrency.SupervisorTest.graceful_shutdown_body(:inf, :inf_graceful) }

  # A plain worker: receive the supervisor pid, register `name`, ack readiness,
  # then block forever (an abnormal exit signal from outside kills it, its exit
  # reaching the linked supervisor).
  fn worker_body(name :: Atom) -> Nil {
    sup = Process.pid(Atom, Process.receive_raw(u64))
    _reg = Process.register(name)
    _ready = Process.send(sup, :ready)
    _block = receive Atom { :never -> :never }
    nil
  }

  # A worker that exits NORMALLY when told `:go` — the transient normal-exit case.
  fn exit_on_go_body(name :: Atom) -> Nil {
    sup = Process.pid(Atom, Process.receive_raw(u64))
    _reg = Process.register(name)
    _ready = Process.send(sup, :ready)
    _go = receive Atom { :go -> :go }
    nil
  }

  # A trapping worker that, on its shutdown signal, notifies the observer with
  # `down` and exits gracefully — makes right-to-left termination observable.
  fn terminating_body(name :: Atom, down :: Atom) -> Nil {
    sup = Process.pid(Atom, Process.receive_raw(u64))
    _trap = Process.trap_exit(true)
    _reg = Process.register(name)
    _ready = Process.send(sup, :ready)
    _shutdown = Process.await_signal()
    _down = Process.send(:sup_observer, down)
    Process.exit()
  }

  # A trapping worker that consumes signals forever — only an untrappable
  # `brutal_kill` can stop it.
  fn trapping_blocker_body(name :: Atom) -> Nil {
    sup = Process.pid(Atom, Process.receive_raw(u64))
    _trap = Process.trap_exit(true)
    _reg = Process.register(name)
    _ready = Process.send(sup, :ready)
    TestConcurrency.SupervisorTest.consume_signals_forever()
  }

  fn consume_signals_forever() -> Nil {
    _signal = Process.await_signal()
    TestConcurrency.SupervisorTest.consume_signals_forever()
  }

  # A trapping worker that acknowledges the shutdown request (notifies `asked`)
  # but then IGNORES it, so a timeout shutdown must fall back to killing it.
  fn ignore_shutdown_body(name :: Atom, asked :: Atom) -> Nil {
    sup = Process.pid(Atom, Process.receive_raw(u64))
    _trap = Process.trap_exit(true)
    _reg = Process.register(name)
    _ready = Process.send(sup, :ready)
    _shutdown = Process.await_signal()
    _asked = Process.send(:sup_observer, asked)
    TestConcurrency.SupervisorTest.consume_signals_forever()
  }

  # A trapping worker that exits gracefully on its shutdown signal, notifying
  # `graceful` first — an infinity shutdown waits for exactly this exit.
  fn graceful_shutdown_body(name :: Atom, graceful :: Atom) -> Nil {
    sup = Process.pid(Atom, Process.receive_raw(u64))
    _trap = Process.trap_exit(true)
    _reg = Process.register(name)
    _ready = Process.send(sup, :ready)
    _shutdown = Process.await_signal()
    _graceful = Process.send(:sup_observer, graceful)
    Process.exit()
  }

  # -- test helpers ---------------------------------------------------------

  # Start a supervisor process UNLINKED (so the test observes the tree from
  # outside it), first ensuring the test is registered as `:sup_observer` so the
  # dispatcher's notifications reach it.
  fn start(entry :: fn() -> Nil) -> u64 {
    _observer = Process.register(:sup_observer)
    Supervisor.start(entry)
  }

  # Block for the next observer notification (a child id or a down atom).
  fn recv() -> Atom {
    receive Atom { notification -> notification }
  }

  # Poll `whereis(name)` for the name to become free, PARKING (yielding to the
  # scheduler via `receive … after`) between checks so the supervisor can run its
  # teardown — a thread-blocking sleep would starve it.
  fn wait_gone(name :: Atom, tries :: i64) -> Bool {
    case Process.whereis(name) == 0 {
      true -> true
      false ->
        case tries <= 0 {
          true -> false
          _ ->
            {
              _park = receive Atom { _ -> :message after 10 -> :timeout }
              TestConcurrency.SupervisorTest.wait_gone(name, tries - 1)
            }
        }
    }
  }

  # Drain any pending observer notifications (between tests, sharing the root
  # process's mailbox).
  fn drain() -> Nil {
    drained = receive Atom { _ -> :got after 0 -> :empty }
    case drained {
      :empty -> nil
      _ -> TestConcurrency.SupervisorTest.drain()
    }
  }

  # End-of-test cleanup: kill the supervisor (cascading to its non-trapping
  # children over their links), yield so the teardown runs, then drain stragglers.
  fn cleanup(sup :: u64) -> Nil {
    _kill = Process.kill(sup)
    _park = receive Atom { _ -> :message after 20 -> :timeout }
    _drained = TestConcurrency.SupervisorTest.drain()
    # Release `:sup_observer` from the shared root process so it holds no name
    # between tests — Erlang allows at most one registered name per process, so
    # leaving it registered would fail a sibling test that registers the root
    # under its own name (cross-test hygiene in Zest's shared root process).
    _unregistered = Process.unregister(:sup_observer)
    nil
  }
}
