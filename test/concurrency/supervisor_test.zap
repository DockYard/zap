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

pub struct Concurrency.SupervisorTest {
  use Zest.Case

  describe("restart strategies") {
    test("one_for_one restarts only the crashed child") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.ofo_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
      a0 = Process.whereis(:ofo_a)
      b0 = Process.whereis(:ofo_b)
      _kill = Process.exit_signal(a0, :boom)
      _r = receive Atom { :ofo_a -> :ok }
      a1 = Process.whereis(:ofo_a)
      b1 = Process.whereis(:ofo_b)
      assert(a1 != a0)
      assert(a1 != 0)
      assert(b1 == b0)
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("rest_for_one restarts the crashed child and every child started after it") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.rfo_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
      _s3 = Concurrency.SupervisorTest.recv()
      a0 = Process.whereis(:rfo_a)
      b0 = Process.whereis(:rfo_b)
      c0 = Process.whereis(:rfo_c)
      _kill = Process.exit_signal(b0, :boom)
      _r1 = Concurrency.SupervisorTest.recv()
      _r2 = Concurrency.SupervisorTest.recv()
      a1 = Process.whereis(:rfo_a)
      b1 = Process.whereis(:rfo_b)
      c1 = Process.whereis(:rfo_c)
      assert(a1 == a0)
      assert(b1 != b0)
      assert(c1 != c0)
      assert(b1 != 0)
      assert(c1 != 0)
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("one_for_all restarts every child when any child crashes") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.ofa_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
      _s3 = Concurrency.SupervisorTest.recv()
      a0 = Process.whereis(:ofa_a)
      b0 = Process.whereis(:ofa_b)
      c0 = Process.whereis(:ofa_c)
      _kill = Process.exit_signal(b0, :boom)
      _r1 = Concurrency.SupervisorTest.recv()
      _r2 = Concurrency.SupervisorTest.recv()
      _r3 = Concurrency.SupervisorTest.recv()
      a1 = Process.whereis(:ofa_a)
      b1 = Process.whereis(:ofa_b)
      c1 = Process.whereis(:ofa_c)
      assert(a1 != a0)
      assert(b1 != b0)
      assert(c1 != c0)
      assert(a1 != 0)
      assert(b1 != 0)
      assert(c1 != 0)
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("simple_one_for_one restarts only the crashed homogeneous instance") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.sofo_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
      _s3 = Concurrency.SupervisorTest.recv()
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
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("restart types") {
    test("a permanent child is always restarted") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.perm_sup/0)
      _s = Concurrency.SupervisorTest.recv()
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
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("a temporary child is never restarted") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.temp_sup/0)
      _s = Concurrency.SupervisorTest.recv()
      t0 = Process.whereis(:temp)
      _k = Process.exit_signal(t0, :boom)
      not_restarted = receive Atom { :temp -> false after 200 -> true }
      assert(not_restarted)
      assert(Process.whereis(:temp) == 0)
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("a transient child restarts on an abnormal exit but not a normal one") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.trans_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
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
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("restart intensity (the crash-loop breaker)") {
    test("more restarts than the intensity within the period terminates the supervisor") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.intensity_sup/0)
      _s = Concurrency.SupervisorTest.recv()
      c0 = Process.whereis(:ic)
      _k1 = Process.exit_signal(c0, :boom)
      _r = Concurrency.SupervisorTest.recv()
      c1 = Process.whereis(:ic)
      assert(c1 != c0)
      _k2 = Process.exit_signal(c1, :boom)
      # Intensity 1 tolerates one restart; the second crash within the period
      # trips the breaker: no third start arrives and the supervisor terminates.
      no_third = receive Atom { :ic -> false after 400 -> true }
      assert(no_third)
      assert(Concurrency.SupervisorTest.wait_gone(:ic_sup, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:ic, 100))
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("stray signals during teardown (P5-R1 S1)") {
    test("one_for_all collects a stray sibling crash during a timeout shutdown without hanging") {
      # THE hang scenario: one_for_all A,B,C; C crashes; during the
      # right-to-left shutdown sweep B (a trapping child that ignores its
      # shutdown request) holds the sweep open for its :timeout window; A
      # crashes spontaneously inside that window. The supervisor must
      # COLLECT A's exit (not discard it), skip A in the sweep (no reap of
      # an already-collected pid — the old discard-then-reap path hung
      # forever here), and restart all three children.
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.ofa_stray_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
      _s3 = Concurrency.SupervisorTest.recv()
      a0 = Process.whereis(:osa_a)
      b0 = Process.whereis(:osa_b)
      c0 = Process.whereis(:osa_c)
      _kill = Process.exit_signal(c0, :boom)
      # B acknowledged its shutdown request: the sweep is now parked inside
      # B's :timeout window — the widest stray window.
      asked = Concurrency.SupervisorTest.recv()
      assert(asked == :osa_b_asked)
      # A crashes spontaneously mid-sweep.
      _stray = Process.exit_signal(a0, :boom_too)
      # No hang: every child is restarted with a fresh pid.
      assert(Concurrency.SupervisorTest.wait_fresh(:osa_a, a0, 200))
      assert(Concurrency.SupervisorTest.wait_fresh(:osa_b, b0, 200))
      assert(Concurrency.SupervisorTest.wait_fresh(:osa_c, c0, 200))
      Concurrency.SupervisorTest.cleanup(sup)
      # The restarted :osa_b traps exits, so the cleanup kill's cascade does
      # not stop it — kill the orphan directly (untrappable).
      _kb = Process.kill(Process.whereis(:osa_b))
    }

    test("rest_for_one restarts an out-of-scope child that crashes during scope teardown") {
      # rest_for_one A,B,C; B crashes (scope B..C); while C (a trapping
      # child ignoring its shutdown request) holds the sweep open, A — OUT
      # of the restart scope — crashes. The old code popped and discarded
      # A's exit, leaving a stale live_pids slot: a PERMANENT child was
      # silently never restarted. The fix folds the collected stray back in
      # as a fresh child death, so A is restarted per the strategy.
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.rfo_stray_sup/0)
      _s1 = Concurrency.SupervisorTest.recv()
      _s2 = Concurrency.SupervisorTest.recv()
      _s3 = Concurrency.SupervisorTest.recv()
      a0 = Process.whereis(:rsa_a)
      b0 = Process.whereis(:rsa_b)
      c0 = Process.whereis(:rsa_c)
      _kill = Process.exit_signal(b0, :boom)
      asked = Concurrency.SupervisorTest.recv()
      assert(asked == :rsa_c_asked)
      # A (out of the B..C scope) crashes during the sweep.
      _stray = Process.exit_signal(a0, :boom_too)
      # A is permanent: it MUST come back — the acceptance point.
      assert(Concurrency.SupervisorTest.wait_fresh(:rsa_a, a0, 200))
      assert(Concurrency.SupervisorTest.wait_fresh(:rsa_b, b0, 200))
      assert(Concurrency.SupervisorTest.wait_fresh(:rsa_c, c0, 200))
      Concurrency.SupervisorTest.cleanup(sup)
      # The restarted :rsa_c traps exits, so the cleanup kill's cascade does
      # not stop it — kill the orphan directly (untrappable).
      _kc = Process.kill(Process.whereis(:rsa_c))
    }

    test("a supervisor skips a stray user message sent to its registered name") {
      # A registered supervisor can be sent ordinary user messages by anyone.
      # Its signal waits must SKIP them (left queued), never abort — and a
      # child crash arriving behind the noise must still be handled.
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.stray_msg_sup/0)
      _s = Concurrency.SupervisorTest.recv()
      w0 = Process.whereis(:smw)
      _noise = Process.send(:stray_msg_sup, :noise)
      # Yield so the parked supervisor observes (and must survive) the noise.
      _park = receive Atom { _ -> :message after 30 -> :waited }
      _kill = Process.exit_signal(w0, :boom)
      _r = Concurrency.SupervisorTest.recv()
      w1 = Process.whereis(:smw)
      assert(w1 != w0)
      assert(w1 != 0)
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("child order") {
    test("children start left-to-right and terminate right-to-left") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.order_sup/0)
      start_one = Concurrency.SupervisorTest.recv()
      start_two = Concurrency.SupervisorTest.recv()
      start_three = Concurrency.SupervisorTest.recv()
      assert(start_one == :ord_a)
      assert(start_two == :ord_b)
      assert(start_three == :ord_c)
      _term = Process.exit_signal(sup, :shutdown)
      term_one = Concurrency.SupervisorTest.recv()
      term_two = Concurrency.SupervisorTest.recv()
      term_three = Concurrency.SupervisorTest.recv()
      assert(term_one == :ord_c_down)
      assert(term_two == :ord_b_down)
      assert(term_three == :ord_a_down)
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("shutdown protocols") {
    test("brutal_kill terminates even a trapping child immediately") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.brutal_sup/0)
      _s = Concurrency.SupervisorTest.recv()
      _term = Process.exit_signal(sup, :shutdown)
      assert(Concurrency.SupervisorTest.wait_gone(:bk, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:bk_sup, 100))
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("a timeout shutdown kills a child that ignores the shutdown request") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.timeout_sup/0)
      _s = Concurrency.SupervisorTest.recv()
      _term = Process.exit_signal(sup, :shutdown)
      got_shutdown = Concurrency.SupervisorTest.recv()
      assert(got_shutdown == :to_asked)
      assert(Concurrency.SupervisorTest.wait_gone(:to, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:to_sup, 100))
      Concurrency.SupervisorTest.cleanup(sup)
    }

    test("an infinity shutdown waits for the child to exit gracefully") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.infinity_sup/0)
      _s = Concurrency.SupervisorTest.recv()
      _term = Process.exit_signal(sup, :shutdown)
      graceful = Concurrency.SupervisorTest.recv()
      assert(graceful == :inf_graceful)
      assert(Concurrency.SupervisorTest.wait_gone(:inf, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:inf_sup, 100))
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  describe("supervision trees") {
    test("a nested supervisor tree tears its whole subtree down") {
      sup = Concurrency.SupervisorTest.start(&Concurrency.SupervisorTest.parent_sup/0)
      _n1 = Concurrency.SupervisorTest.recv()
      _n2 = Concurrency.SupervisorTest.recv()
      _n3 = Concurrency.SupervisorTest.recv()
      assert(Process.whereis(:child_sup) != 0)
      assert(Process.whereis(:nest_w1) != 0)
      assert(Process.whereis(:nest_w2) != 0)
      _term = Process.exit_signal(sup, :shutdown)
      assert(Concurrency.SupervisorTest.wait_gone(:nest_w1, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:nest_w2, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:child_sup, 100))
      assert(Concurrency.SupervisorTest.wait_gone(:parent_sup, 100))
      Concurrency.SupervisorTest.cleanup(sup)
    }
  }

  # -- the inverted-control supervisor loop: init, then drive Supervisor.step,
  # -- calling the LOCAL dispatch for each child to (re)start (no function value
  # -- threaded through the library) and feeding the pid back with installed --

  fn run(children :: List(SupervisorChildSpec), options :: SupervisorOptions) -> Nil {
    state = Supervisor.init(children, options)
    Concurrency.SupervisorTest.sup_loop(state)
  }

  fn sup_loop(state :: SupervisorState) -> Nil {
    current = Supervisor.step(state)
    case current.action {
      :start ->
        Concurrency.SupervisorTest.sup_loop(Supervisor.installed(current.state, current.child_id, Concurrency.SupervisorTest.dispatch(current.child_id)))
      :stop ->
        Process.exit_with(current.reason)
      _ ->
        Concurrency.SupervisorTest.sup_loop(current.state)
    }
  }

  # -- the child starter: start every child by id, notifying the observer AFTER
  # -- the readiness handshake so a notification is a safe-to-kill signal --

  pub fn dispatch(child_id :: Atom) -> u64 {
    child = case child_id {
      :ofo_a -> Process.spawn_link(&Concurrency.SupervisorTest.ofo_a_entry/0)
      :ofo_b -> Process.spawn_link(&Concurrency.SupervisorTest.ofo_b_entry/0)
      :rfo_a -> Process.spawn_link(&Concurrency.SupervisorTest.rfo_a_entry/0)
      :rfo_b -> Process.spawn_link(&Concurrency.SupervisorTest.rfo_b_entry/0)
      :rfo_c -> Process.spawn_link(&Concurrency.SupervisorTest.rfo_c_entry/0)
      :ofa_a -> Process.spawn_link(&Concurrency.SupervisorTest.ofa_a_entry/0)
      :ofa_b -> Process.spawn_link(&Concurrency.SupervisorTest.ofa_b_entry/0)
      :ofa_c -> Process.spawn_link(&Concurrency.SupervisorTest.ofa_c_entry/0)
      :sofo_0 -> Process.spawn_link(&Concurrency.SupervisorTest.sofo_0_entry/0)
      :sofo_1 -> Process.spawn_link(&Concurrency.SupervisorTest.sofo_1_entry/0)
      :sofo_2 -> Process.spawn_link(&Concurrency.SupervisorTest.sofo_2_entry/0)
      :perm -> Process.spawn_link(&Concurrency.SupervisorTest.perm_entry/0)
      :temp -> Process.spawn_link(&Concurrency.SupervisorTest.temp_entry/0)
      :trans -> Process.spawn_link(&Concurrency.SupervisorTest.trans_entry/0)
      :transn -> Process.spawn_link(&Concurrency.SupervisorTest.transn_entry/0)
      :ic -> Process.spawn_link(&Concurrency.SupervisorTest.ic_entry/0)
      :ord_a -> Process.spawn_link(&Concurrency.SupervisorTest.ord_a_entry/0)
      :ord_b -> Process.spawn_link(&Concurrency.SupervisorTest.ord_b_entry/0)
      :ord_c -> Process.spawn_link(&Concurrency.SupervisorTest.ord_c_entry/0)
      :bk -> Process.spawn_link(&Concurrency.SupervisorTest.bk_entry/0)
      :to -> Process.spawn_link(&Concurrency.SupervisorTest.to_entry/0)
      :inf -> Process.spawn_link(&Concurrency.SupervisorTest.inf_entry/0)
      :osa_a -> Process.spawn_link(&Concurrency.SupervisorTest.osa_a_entry/0)
      :osa_b -> Process.spawn_link(&Concurrency.SupervisorTest.osa_b_entry/0)
      :osa_c -> Process.spawn_link(&Concurrency.SupervisorTest.osa_c_entry/0)
      :rsa_a -> Process.spawn_link(&Concurrency.SupervisorTest.rsa_a_entry/0)
      :rsa_b -> Process.spawn_link(&Concurrency.SupervisorTest.rsa_b_entry/0)
      :rsa_c -> Process.spawn_link(&Concurrency.SupervisorTest.rsa_c_entry/0)
      :smw -> Process.spawn_link(&Concurrency.SupervisorTest.smw_entry/0)
      :nest_w1 -> Process.spawn_link(&Concurrency.SupervisorTest.nest_w1_entry/0)
      :nest_w2 -> Process.spawn_link(&Concurrency.SupervisorTest.nest_w2_entry/0)
      _ -> Process.spawn_link(&Concurrency.SupervisorTest.child_sup_entry/0)
    }
    _give = Process.send(Process.pid(u64, child), Process.self())
    _ready = Concurrency.SupervisorTest.await_ready()
    _notify = Process.send(:sup_observer, child_id)
    child
  }

  # Wait for the child's readiness ack, DROPPING any other user message that
  # arrives first (a stray message sent to the supervisor's registered name):
  # OTP supervisors log-and-drop unknown messages; a bare `receive :ready`
  # would route the stray into the dead-letter catch-all and kill the
  # supervisor process instead.
  fn await_ready() -> Atom {
    got = receive Atom {
      :ready -> :ready
      _ -> :other_message
    }
    case got {
      :ready -> :ready
      _ -> Concurrency.SupervisorTest.await_ready()
    }
  }

  # -- supervisor entry points (each registers a name for liveness observation) --

  pub fn ofo_sup() -> Nil {
    _reg = Process.register(:ofo_sup)
    children = [Supervisor.worker(:ofo_a), Supervisor.worker(:ofo_b)]
    Concurrency.SupervisorTest.run(children, Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn rfo_sup() -> Nil {
    _reg = Process.register(:rfo_sup)
    children = [Supervisor.worker(:rfo_a), Supervisor.worker(:rfo_b), Supervisor.worker(:rfo_c)]
    Concurrency.SupervisorTest.run(children, Supervisor.options(:rest_for_one, 9, 5000))
  }

  pub fn ofa_sup() -> Nil {
    _reg = Process.register(:ofa_sup)
    children = [Supervisor.worker(:ofa_a), Supervisor.worker(:ofa_b), Supervisor.worker(:ofa_c)]
    Concurrency.SupervisorTest.run(children, Supervisor.options(:one_for_all, 9, 5000))
  }

  pub fn sofo_sup() -> Nil {
    _reg = Process.register(:sofo_sup)
    zero = Supervisor.child_spec(:sofo_0, :permanent, :timeout, 5000, :worker)
    one = Supervisor.child_spec(:sofo_1, :permanent, :timeout, 5000, :worker)
    two = Supervisor.child_spec(:sofo_2, :permanent, :timeout, 5000, :worker)
    Concurrency.SupervisorTest.run([zero, one, two], Supervisor.options(:simple_one_for_one, 9, 5000))
  }

  pub fn perm_sup() -> Nil {
    _reg = Process.register(:perm_sup)
    Concurrency.SupervisorTest.run([Supervisor.worker(:perm)], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn temp_sup() -> Nil {
    _reg = Process.register(:temp_sup)
    Concurrency.SupervisorTest.run([Supervisor.worker(:temp, :temporary)], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn trans_sup() -> Nil {
    _reg = Process.register(:trans_sup)
    children = [Supervisor.worker(:trans, :transient), Supervisor.worker(:transn, :transient)]
    Concurrency.SupervisorTest.run(children, Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn intensity_sup() -> Nil {
    _reg = Process.register(:ic_sup)
    Concurrency.SupervisorTest.run([Supervisor.worker(:ic)], Supervisor.options(:one_for_one, 1, 5000))
  }

  pub fn order_sup() -> Nil {
    _reg = Process.register(:ord_sup)
    a = Supervisor.child_spec(:ord_a, :permanent, :infinity, 0, :worker)
    b = Supervisor.child_spec(:ord_b, :permanent, :infinity, 0, :worker)
    c = Supervisor.child_spec(:ord_c, :permanent, :infinity, 0, :worker)
    Concurrency.SupervisorTest.run([a, b, c], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn brutal_sup() -> Nil {
    _reg = Process.register(:bk_sup)
    Concurrency.SupervisorTest.run([Supervisor.brutal_worker(:bk)], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn timeout_sup() -> Nil {
    _reg = Process.register(:to_sup)
    spec = Supervisor.child_spec(:to, :permanent, :timeout, 50, :worker)
    Concurrency.SupervisorTest.run([spec], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn infinity_sup() -> Nil {
    _reg = Process.register(:inf_sup)
    spec = Supervisor.child_spec(:inf, :permanent, :infinity, 0, :worker)
    Concurrency.SupervisorTest.run([spec], Supervisor.options(:one_for_one, 9, 5000))
  }

  pub fn parent_sup() -> Nil {
    _reg = Process.register(:parent_sup)
    Concurrency.SupervisorTest.run([Supervisor.supervisor(:child_sup)], Supervisor.options(:one_for_one, 9, 5000))
  }

  # one_for_all with a middle child whose :timeout shutdown window (400 ms,
  # held open by a trapping ignorer) gives a sibling crash a wide window to
  # land as a stray during the teardown sweep (P5-R1 S1 acceptance a).
  pub fn ofa_stray_sup() -> Nil {
    _reg = Process.register(:osa_sup)
    a = Supervisor.worker(:osa_a)
    b = Supervisor.child_spec(:osa_b, :permanent, :timeout, 400, :worker)
    c = Supervisor.worker(:osa_c)
    Concurrency.SupervisorTest.run([a, b, c], Supervisor.options(:one_for_all, 9, 5000))
  }

  # rest_for_one whose LAST child holds the sweep open (trapping ignorer,
  # 400 ms :timeout) so an OUT-OF-SCOPE crash of the first child lands as a
  # stray during the scope teardown (P5-R1 S1 acceptance b).
  pub fn rfo_stray_sup() -> Nil {
    _reg = Process.register(:rsa_sup)
    a = Supervisor.worker(:rsa_a)
    b = Supervisor.worker(:rsa_b)
    c = Supervisor.child_spec(:rsa_c, :permanent, :timeout, 400, :worker)
    Concurrency.SupervisorTest.run([a, b, c], Supervisor.options(:rest_for_one, 9, 5000))
  }

  # A registered supervisor whose mailbox receives ordinary user messages
  # from outside — its signal waits must skip (not abort on) them (S2×S1).
  pub fn stray_msg_sup() -> Nil {
    _reg = Process.register(:stray_msg_sup)
    Concurrency.SupervisorTest.run([Supervisor.worker(:smw)], Supervisor.options(:one_for_one, 9, 5000))
  }

  # A nested child supervisor: ack the parent's handshake, then run its own
  # subtree of two workers.
  pub fn child_sup_entry() -> Nil {
    parent = Process.pid(Atom, Process.receive_raw(u64))
    _reg = Process.register(:child_sup)
    _ready = Process.send(parent, :ready)
    children = [Supervisor.worker(:nest_w1), Supervisor.worker(:nest_w2)]
    Concurrency.SupervisorTest.run(children, Supervisor.options(:one_for_one, 9, 5000))
  }

  # -- child process entries ------------------------------------------------

  pub fn ofo_a_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:ofo_a) }
  pub fn ofo_b_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:ofo_b) }
  pub fn rfo_a_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:rfo_a) }
  pub fn rfo_b_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:rfo_b) }
  pub fn rfo_c_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:rfo_c) }
  pub fn ofa_a_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:ofa_a) }
  pub fn ofa_b_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:ofa_b) }
  pub fn ofa_c_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:ofa_c) }
  pub fn sofo_0_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:sofo_0) }
  pub fn sofo_1_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:sofo_1) }
  pub fn sofo_2_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:sofo_2) }
  pub fn perm_entry() -> Nil { Concurrency.SupervisorTest.exit_on_go_body(:perm) }
  pub fn temp_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:temp) }
  pub fn trans_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:trans) }
  pub fn ic_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:ic) }
  pub fn nest_w1_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:nest_w1) }
  pub fn nest_w2_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:nest_w2) }

  pub fn transn_entry() -> Nil { Concurrency.SupervisorTest.exit_on_go_body(:transn) }

  pub fn ord_a_entry() -> Nil { Concurrency.SupervisorTest.terminating_body(:ord_a, :ord_a_down) }
  pub fn ord_b_entry() -> Nil { Concurrency.SupervisorTest.terminating_body(:ord_b, :ord_b_down) }
  pub fn ord_c_entry() -> Nil { Concurrency.SupervisorTest.terminating_body(:ord_c, :ord_c_down) }

  pub fn bk_entry() -> Nil { Concurrency.SupervisorTest.trapping_blocker_body(:bk) }
  pub fn to_entry() -> Nil { Concurrency.SupervisorTest.ignore_shutdown_body(:to, :to_asked) }
  pub fn inf_entry() -> Nil { Concurrency.SupervisorTest.graceful_shutdown_body(:inf, :inf_graceful) }

  pub fn osa_a_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:osa_a) }
  pub fn osa_b_entry() -> Nil { Concurrency.SupervisorTest.ignore_shutdown_body(:osa_b, :osa_b_asked) }
  pub fn osa_c_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:osa_c) }
  pub fn rsa_a_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:rsa_a) }
  pub fn rsa_b_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:rsa_b) }
  pub fn rsa_c_entry() -> Nil { Concurrency.SupervisorTest.ignore_shutdown_body(:rsa_c, :rsa_c_asked) }
  pub fn smw_entry() -> Nil { Concurrency.SupervisorTest.worker_body(:smw) }

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
    Concurrency.SupervisorTest.consume_signals_forever()
  }

  fn consume_signals_forever() -> Nil {
    _signal = Process.await_signal()
    Concurrency.SupervisorTest.consume_signals_forever()
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
    Concurrency.SupervisorTest.consume_signals_forever()
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
    assert(Process.register(:sup_observer))
    Supervisor.start(entry)
  }

  # Block for the next observer notification (a child id or a down atom).
  fn recv() -> Atom {
    receive Atom { notification -> notification }
  }

  # Poll `whereis(name)` until it resolves to a LIVE pid that differs from
  # `old_pid` (a restart is observable as a changed registration), parking
  # between checks so the supervisor can run. Consumes and ignores observer
  # notifications while polling (start notifications are asserted by pid
  # freshness here, not by arrival order — stray-driven restarts may batch).
  fn wait_fresh(name :: Atom, old_pid :: u64, tries :: i64) -> Bool {
    current = Process.whereis(name)
    case current != 0 and current != old_pid {
      true -> true
      false ->
        case tries <= 0 {
          true -> false
          _ ->
            {
              _park = receive Atom { _ -> :message after 10 -> :timeout }
              Concurrency.SupervisorTest.wait_fresh(name, old_pid, tries - 1)
            }
        }
    }
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
              Concurrency.SupervisorTest.wait_gone(name, tries - 1)
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
      _ -> Concurrency.SupervisorTest.drain()
    }
  }

  # End-of-test cleanup: kill the supervisor (cascading to its non-trapping
  # children over their links), yield so the teardown runs, then drain stragglers.
  fn cleanup(sup :: u64) -> Nil {
    _kill = Process.kill(sup)
    _park = receive Atom { _ -> :message after 20 -> :timeout }
    _drained = Concurrency.SupervisorTest.drain()
    # Release `:sup_observer` from the shared root process so it holds no name
    # between tests — Erlang allows at most one registered name per process, so
    # leaving it registered would fail a sibling test that registers the root
    # under its own name (cross-test hygiene in Zest's shared root process).
    _unregistered = Process.unregister(:sup_observer)
    nil
  }
}
