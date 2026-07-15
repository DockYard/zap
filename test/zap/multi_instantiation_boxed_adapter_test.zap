@doc = """
  Regression coverage for GAP-C: a parametric adapter (a struct
  `Wrap(element)` carrying a boxed `Enumerable(element)` field and
  implementing `Enumerable(element)` itself) that is BOXED at MULTIPLE
  instantiations in one program — `Enumerable(i64)` AND `Enumerable(String)`
  — and both DRIVEN to `:done` (`Enum.to_list`) AND EARLY-DISPOSED
  (`Enum.take`, which pulls a prefix then disposes the remaining iterator).

  Root cause (fixed): the ARC drop-insertion box-retain rewrite
  (`rewriteProtocolBoxReleases` in `src/arc_drop_insertion.zig`) classified a
  `.persistent` box retain as a genuine new-owner SHARE
  (`.protocol_box_share`, which CLONES the inner under a clone-on-share
  manager) ONLY when the retained box was bound to a NAMED local
  (`binding_targets`). A box value that is instead MOVE-consumed — copied out
  of an owned aggregate (e.g. the `{:cont, value, next_state}` tuple returned
  by `Enumerable.next`) and then MOVED into a consuming callee such as
  `Enum`'s internal `dispose_and_return`, while the original aggregate slot is
  ALSO dropped — is EQUALLY a genuine second owner, but was wrongly downgraded
  to a transient `.protocol_box_retain` (a no-op under a no-REFCOUNT_V1
  manager). Under `Memory.Tracking` the "second owner" then aliased the
  source's inner and both the callee's free and the original slot's scope-exit
  drop reclaimed the SAME cell — a double-free (SIGSEGV). Under the default
  refcount ARC the alias corrupted the slab and a later allocation of a second
  instantiation crashed (`bus_error` in the box `clone`/`share` path). The fix
  additionally classifies a move-consumed `.persistent` box retain as a
  `.protocol_box_share`, so each owner clones an independent inner and reaches
  a single free regardless of how many instantiations coexist.

  The String instantiation is the ARC-payload case (its elements are
  heap-tracked), so it exercises the deep clone/release of a boxed adapter
  whose inner owns further ARC children. Every memory-sensitive block is
  wrapped in `assert_no_leaks` so the file also gates cleanliness under the
  default (ARC) binary; the `Memory.Tracking` no-crash/leak-free counterpart
  lives in `src/zir_integration_tests.zig` (Zest cannot select `-Dmemory`).
  """

pub struct Wrap(element) {
  source :: Enumerable(element)
}

pub impl Enumerable(element) for Wrap(element) {
  fn step(source :: unique Enumerable(element)) -> {Atom, element, Wrap(element)} {
    case Enumerable.next(source) {
      {:done, exhausted_value, exhausted} -> {:done, exhausted_value, %Wrap(element){source: exhausted}}
      {:cont, item, rest} -> {:cont, item, %Wrap(element){source: rest}}
    }
  }

  fn drop_source(source :: unique Enumerable(element)) -> Nil {
    Enumerable.dispose(source)
    nil
  }

  pub fn next(self :: unique Wrap(element)) -> {Atom, element, Wrap(element)} {
    Wrap.step(self.source)
  }

  pub fn dispose(self :: unique Wrap(element)) -> Nil {
    Wrap.drop_source(self.source)
    nil
  }
}

pub struct Zap.MultiInstantiationBoxedAdapterTest {
  use Zest.Case

  describe("parametric adapter boxed at two instantiations, driven to :done") {
    test("i64 instantiation drains fully") {
      assert_no_leaks {
        drained = Enum.to_list(wrap_i64([1, 2, 3]))
        assert(List.length(drained) == 3)
        assert(List.head(drained) == 1)
        assert(List.last(drained) == 3)
      }
    }

    test("String (ARC payload) instantiation drains fully") {
      assert_no_leaks {
        drained = Enum.to_list(wrap_str(["a", "b", "c"]))
        assert(List.length(drained) == 3)
        assert(List.head(drained) == "a")
        assert(List.last(drained) == "c")
      }
    }
  }

  describe("parametric adapter boxed at two instantiations, early-disposed") {
    test("String (ARC payload) partial take then dispose") {
      assert_no_leaks {
        taken = Enum.take(wrap_str(["a", "b", "c", "d"]), 2)
        assert(List.length(taken) == 2)
        assert(List.head(taken) == "a")
        assert(List.last(taken) == "b")
      }
    }

    test("i64 partial take then dispose") {
      assert_no_leaks {
        taken = Enum.take(wrap_i64([10, 20, 30, 40]), 2)
        assert(List.length(taken) == 2)
        assert(List.head(taken) == 10)
        assert(List.last(taken) == 20)
      }
    }
  }

  describe("both instantiations coexisting in one expression sequence") {
    test("String early-dispose followed by i64 drain (multi-instantiation slab coexistence)") {
      assert_no_leaks {
        taken = Enum.take(wrap_str(["x", "y", "z"]), 1)
        assert(List.length(taken) == 1)
        assert(List.head(taken) == "x")

        drained = Enum.to_list(wrap_i64([7, 8, 9]))
        assert(List.length(drained) == 3)
        assert(List.head(drained) == 7)
        assert(List.last(drained) == 9)
      }
    }
  }

  fn wrap_i64(source :: unique Enumerable(i64)) -> Enumerable(i64) {
    %Wrap(i64){source: source}
  }

  fn wrap_str(source :: unique Enumerable(String)) -> Enumerable(String) {
    %Wrap(String){source: source}
  }
}
