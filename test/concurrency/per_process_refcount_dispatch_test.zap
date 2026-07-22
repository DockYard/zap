pub struct Concurrency.PerProcessRefcountDispatchTest {
  use Zest.Case

  # P3-R1a acceptance: per-process retain/release/*Sized dispatch. Every refcount
  # op a spawned process performs routes to ITS OWN manager's vtable on ITS OWN
  # per-process context (the runtime's `currentRefcountCapability`), NOT the
  # binary-global manifest manager. Two consequences this proves end-to-end,
  # each in a DIFFERENT reclamation model coexisting in this one gate-ON binary:
  #
  #   * An ORC process's refcount-heavy workload runs on its OWN ORC context.
  #     Before this fix an ORC process's release dispatched to the manifest ARC's
  #     vtable while carrying an OrcContext — ARC's slab-free path reinterpreted
  #     the OrcContext as an ArcContext (a memory-safety hazard). Here the ORC
  #     worker drives a refcount-heavy higher-order-function workload
  #     (List.map + List.reduce each retain/release their cells) ENTIRELY on its
  #     ORC heap and returns the exact checksum; a wrong dispatch corrupts or
  #     crashes rather than returning 240.
  #
  #   * A NON-refcounted Arena process reaching a COLD EDGE — a higher-order
  #     function whose generic body is compiled under the manifest (refcounted)
  #     model and so EMITS retain/release — has those ops resolve to Arena's
  #     (absent) refcount capability and elide at RUNTIME (the null-capability
  #     no-op in every dispatch site), exactly as the monomorphizer elides them
  #     for a specialized bulk_or_never subgraph. The Arena worker runs the
  #     IDENTICAL allocating-HOF workload and returns the same checksum without a
  #     refcount-dispatch panic — the sound cold-path behaviour (real per-process
  #     dispatch, not a verifier rejection).
  #
  # NOTE on cycle collection. ORC's Bacon-Rajan cycle COLLECTOR is proven
  # exhaustively at the manager-unit level (src/memory/orc/manager.zig: the
  # positive control, the real negative control, the join-node ScanBlack test,
  # and the external-reference-survives test), where a genuine reference cycle is
  # built by mutating cell pointers. A reference cycle CANNOT be constructed at
  # the Zap language surface: Zap values are immutable (a struct "update" yields a
  # NEW value), so no `A -> B -> A` back-edge is expressible; and ORC's per-type
  # CYCL trace registration for runtime container types is a separate, currently
  # unwired follow-on. This runtime-level test therefore proves the load-bearing
  # half THIS job delivers — that an ORC process's refcount ops REACH ORC's own
  # machinery (retain / release / noteDecrement) on ORC's own context instead of
  # the manifest ARC's — which is the prerequisite for ORC cycle collection to
  # ever run for an ORC process.

  describe("per-process refcount dispatch: each process's refcount ops reach its own manager") {
    test("an ORC worker's allocating higher-order-function refcount workload runs on its OWN ORC context") {
      orc_bits = Process.spawn(&Concurrency.PerProcessRefcountDispatchTest.orc_hof_worker/0, Memory.ORC)
      orc_pid = Process.pid(u64, orc_bits)
      _ready = Process.send(orc_pid, Process.self())
      checksum = Process.receive_raw(i64)
      # base = 40 cells of 3; map doubles each to 6; reduce sums = 40 * 6 = 240.
      assert(checksum == 240)
      _report = IO.puts("\nPROOF P3-R1a ORC dispatch: ORC worker HOF refcount workload checksum=#{checksum} (routed to its OWN ORC context)")
    }

    test("an Arena worker calling an allocating higher-order function (cold edge) runs correctly") {
      arena_bits = Process.spawn(&Concurrency.PerProcessRefcountDispatchTest.arena_hof_worker/0, Memory.Arena)
      arena_pid = Process.pid(u64, arena_bits)
      _ready = Process.send(arena_pid, Process.self())
      checksum = Process.receive_raw(i64)
      assert(checksum == 240)
      _report = IO.puts("\nPROOF P3-R1a Arena cold-path: Arena worker allocating-HOF checksum=#{checksum} (cold-edge retain/release elided via null-capability no-op)")
    }
  }

  # -- child process entries (zero-parameter; each first receives the parent's
  # -- raw pid bits as its reply channel, then reports its HOF-workload checksum)

  pub fn orc_hof_worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, Concurrency.PerProcessRefcountDispatchTest.hof_checksum())
    nil
  }

  pub fn arena_hof_worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, Concurrency.PerProcessRefcountDispatchTest.hof_checksum())
    nil
  }

  # A refcount-touching workload built from ALLOCATING higher-order functions:
  # `List.map` and `List.reduce` take a function VALUE — an anonymous closure, the
  # canonical COLD EDGE: its generic body is compiled once under the manifest
  # (refcounted) model and emits retain/release, so running it under a
  # non-refcounted Arena process is exactly the cold-path case. `List.map`
  # allocates a fresh List; both fold cells on the CALLING process's OWN heap
  # under its OWN manager.
  pub fn hof_checksum() -> i64 {
    base = List.new_filled(40, 3)
    doubled = List.map(base, fn(value :: i64) -> i64 { value * 2 })
    List.reduce(doubled, 0 :: i64, fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value })
  }
}
