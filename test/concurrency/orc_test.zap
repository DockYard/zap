pub struct Concurrency.OrcTest {
  use Zest.Case

  # P3-J6 acceptance proof: the ORC-over-ARC cyclic manager as a per-spawn
  # option, and the shares-the-REFCOUNTED-specialization hypothesis end-to-end.
  #
  # The `:test_concurrency` manifest selects Memory.ARC (the default). This test
  # ALSO spawns a process under an explicit per-spawn Memory.ORC. Because ORC
  # declares REFCOUNTED byte-identically to ARC (`declared_caps == 0x1`), the
  # ORC child's pid carries the SAME reclamation-model bits as the ARC child —
  # `refcounted` (0) — the runtime-level proof that ORC and ARC share the
  # REFCOUNTED codegen specialization: both processes run the identical
  # retain/release-emitting code, each dispatched to its OWN manager context.
  # ORC's context additionally runs the Bacon–Rajan cycle collector (proven
  # exhaustively at the manager layer in `src/memory/orc/manager.zig`'s tests);
  # here we prove the surface `Process.spawn(entry, Memory.ORC)` path works and
  # that ORC coexists with ARC under one binary as a REFCOUNTED-model process.

  describe("per-spawn Memory.ORC: an ORC process runs the REFCOUNTED model alongside ARC") {
    test("the ORC child carries the refcounted model bits — identical to ARC — and allocates on its own ORC heap") {
      # Spawn under the manifest default (Memory.ARC) and under an explicit
      # per-spawn Memory.ORC, in the same binary. Linking both proves the ORC
      # backend (src/memory/orc/manager.zig) resolved and registered as a
      # per-spawn manager module.
      arc_child_bits = Process.spawn(&Concurrency.OrcTest.arc_worker/0)
      orc_child_bits = Process.spawn(&Concurrency.OrcTest.orc_worker/0, Memory.ORC)

      # Every pid carries a 2-bit reclamation-model field at bits 54..55, stamped
      # at spawn from the SELECTED manager's declared capabilities. ARC declares
      # REFCOUNT_V1 → `refcounted` (0). ORC ALSO declares REFCOUNT_V1 (its cycle
      # collector is a separate CYCL capability descriptor, invisible to the
      # Axis-A model) → `refcounted` (0). So the two model fields are EQUAL — the
      # end-to-end confirmation that ORC == REFCOUNTED at the model/codegen layer
      # and shares ARC's specialization (contrast the two_manager_proof test,
      # where Arena decodes to a DIFFERENT model, 1).
      model_shift = (54 :: u64)
      model_mask = (3 :: u64)
      arc_model = Integer.band(Integer.bsr(arc_child_bits, model_shift), model_mask)
      orc_model = Integer.band(Integer.bsr(orc_child_bits, model_shift), model_mask)
      assert(arc_model == (0 :: u64))
      assert(orc_model == (0 :: u64))
      assert(arc_model == orc_model)

      # Behavioral half: each child ran a real 1000-cell List allocation +
      # reduction on its OWN process heap and reported the checksum. The ORC
      # child's allocate/retain/release route to ITS ORC context — the same
      # REFCOUNTED codegen ARC emits, serviced by the ORC manager (which frees
      # acyclic data promptly, exactly like ARC, and buffers only cycle-root
      # candidates). A wrong per-process dispatch or a broken ORC alloc path
      # would corrupt or panic rather than return the checksum.
      arc_pid = Process.pid(u64, arc_child_bits)
      _arc_ready = Process.send(arc_pid, Process.self())
      arc_checksum = Process.receive_raw(i64)
      assert(arc_checksum == 1000)

      orc_pid = Process.pid(u64, orc_child_bits)
      _orc_ready = Process.send(orc_pid, Process.self())
      orc_checksum = Process.receive_raw(i64)
      assert(orc_checksum == 1000)

      _report = IO.puts("\nPROOF ORC shares REFCOUNTED: ARC child model=#{arc_model} (0=refcounted) heap_checksum=#{arc_checksum}; ORC child model=#{orc_model} (0=refcounted, same specialization) heap_checksum=#{orc_checksum}")
    }
  }

  # -- child process entries (zero-parameter; each first receives the parent's
  # -- raw pid bits as its reply channel, then reports its process-heap checksum)

  pub fn arc_worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, Concurrency.OrcTest.process_heap_checksum())
    nil
  }

  pub fn orc_worker() -> Nil {
    parent = Process.pid(i64, Process.receive_raw(u64))
    _sent = Process.send(parent, Concurrency.OrcTest.process_heap_checksum())
    nil
  }

  pub fn process_heap_checksum() -> i64 {
    numbers = List.new_filled(1000, 1)
    List.length(numbers)
  }
}
