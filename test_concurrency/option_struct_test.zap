pub struct TestConcurrency.OptionStructTest {
  use Zest.Case

  # Regression pin for the pre-existing `Option(<user struct>)` gate-ON
  # defect (concurrency plan item 6.2 follow-on, bisected by P6-J2 to
  # `never = Option(BlobProbeMarker).None` in a gate-ON test): the
  # parametric-union specialization's synthetic Zig module rendered the
  # struct payload as a bare identifier, which failed AstGen; the
  # ZIR-injection pipeline swallowed the failure (empty injected-ZIR
  # imports table -> the failed file never became alive), so cold
  # builds ICE'd in the fork's LLVM bitcode emitter and warm suite
  # builds surfaced spurious whole-binary gate-OFF compile errors.
  # These tests must compile AND run correctly in the gate-ON suite.
  pub struct ProbeMarker {
    value :: i64
  }

  describe("Option over a user struct in a gate-ON binary") {
    test("Option(ProbeMarker).None constructs and matches the nullary arm") {
      never = Option(ProbeMarker).None
      result = case never {
        Option.Some(_marker) -> 1
        Option.None -> 0
      }
      assert(result == 0)
    }

    test("Option(ProbeMarker).Some round-trips the struct payload") {
      some = Option(ProbeMarker).Some(%ProbeMarker{value: 41})
      result = case some {
        Option.Some(marker) -> marker.value + 1
        Option.None -> 0
      }
      assert(result == 42)
    }

    test("Option predicates observe Option(struct) variants") {
      assert(Option.is_none?(Option(ProbeMarker).None) == true)
      assert(Option.is_some?(Option(ProbeMarker).Some(%ProbeMarker{value: 1})) == true)
    }
  }
}
