pub struct TestConcurrency.TwoManagerProofTest {
  use Zest.Case

  # P3-J3 acceptance proof: TWO memory managers active in ONE running binary.
  #
  # The `:test_concurrency` manifest selects Memory.ARC (the default). This test
  # ALSO spawns a process under an explicit per-spawn Memory.Arena. The build
  # orchestration therefore linked BOTH manager backends — ARC as the manifest
  # `zap_active_manager` (registry slot 0) and Arena as a `zap_spawn_manager_1`
  # sibling module (registry slot 1) — and the gated runtime registered Arena
  # into its kernel registry before this test ran (docs/memory-manager-abi.md
  # §10.5). The two processes coexist, each dispatched to its OWN manager and
  # running its OWN reclamation-model codegen.

  describe("per-spawn memory manager: an ARC process and an Arena process coexist") {
    test("each process carries its own manager's reclamation model, and each runs on its own heap") {
      # Spawn under the manifest default (Memory.ARC) and under an explicit
      # per-spawn Memory.Arena, in the same binary.
      arc_child_bits = Process.spawn(&TestConcurrency.TwoManagerProofTest.arc_worker/0)
      arena_child_bits = Process.spawn(&TestConcurrency.TwoManagerProofTest.arena_worker/0, Memory.Arena)

      # Every pid carries a 2-bit reclamation-model field, stamped at spawn from
      # the SELECTED manager's declared capabilities (pid layout: model occupies
      # bits 54..55 — src/runtime/concurrency/pid_table.zig `model_shift`). ARC
      # declares REFCOUNT_V1 and decodes to `refcounted` (0); Arena declares no
      # capabilities and decodes to `bulk_or_never` (1). Reading the bits back
      # from each child's raw pid proves the two processes were dispatched to
      # DIFFERENT registry slots holding DIFFERENT managers — the kernel-level
      # proof that two models coexist.
      model_shift = (54 :: u64)
      model_mask = (3 :: u64)
      arc_model = Integer.band(Integer.bsr(arc_child_bits, model_shift), model_mask)
      arena_model = Integer.band(Integer.bsr(arena_child_bits, model_shift), model_mask)
      assert(arc_model == (0 :: u64))
      assert(arena_model == (1 :: u64))
      assert(arc_model != arena_model)

      # Each child ran a real 1000-cell List allocation + reduction on its OWN
      # process heap and reported the checksum (1000 = sum of 1000 ones). This is
      # the behavioral half — each context's alloc path routes to the right model:
      #
      #   * The ARC child runs the REFCOUNTED model: retain/release are emitted
      #     and its ARC context services them, reclaiming per-drop.
      #   * The Arena child runs the BULK_OR_NEVER model: the spawn-manager
      #     monomorphization ELIDED retain/release across its spawn-reachable
      #     code, so allocating a List under Arena — which services NO REFCOUNT_V1
      #     capability — does not panic on refcount dispatch. It allocates raw from
      #     the Arena and is wholesale-freed when the process tears down.
      #
      # If the per-process dispatch or the model specialization were wrong (the
      # Arena process routed through ARC's allocate, or ARC retain/release emitted
      # on Arena cells), this workload would corrupt or panic rather than return
      # the checksum.
      arc_pid = Process.pid(u64, arc_child_bits)
      _arc_ready = Process.send(arc_pid, Process.self())
      arc_checksum = Process.receive_raw(i64)
      assert(arc_checksum == 1000)

      arena_pid = Process.pid(u64, arena_child_bits)
      _arena_ready = Process.send(arena_pid, Process.self())
      arena_checksum = Process.receive_raw(i64)
      assert(arena_checksum == 1000)

      _report = IO.puts("\nPROOF two managers coexist: ARC child model=#{arc_model} (0=refcounted) heap_checksum=#{arc_checksum}; Arena child model=#{arena_model} (1=bulk_or_never) heap_checksum=#{arena_checksum}")
    }
  }

  # -- child process entries (zero-parameter; each first receives the parent's
  # -- raw pid bits as its reply channel, then reports its process-heap checksum)

  pub fn arc_worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, TestConcurrency.TwoManagerProofTest.process_heap_checksum())
    nil
  }

  pub fn arena_worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, TestConcurrency.TwoManagerProofTest.process_heap_checksum())
    nil
  }

  pub fn process_heap_checksum() -> i64 {
    numbers = List.new_filled(1000, 1)
    List.length(numbers)
  }
}
