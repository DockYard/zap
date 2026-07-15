@doc = """
  Regression tests for `Stream.with_index/1` over a source whose element type
  is itself a `List`. When `element = [i64]`, the stage's `output` is the
  tuple `{[i64], i64}` — a tuple that EMBEDS a list — and the demand-driven
  `Transform` monomorphizes methods whose return type is
  `{Atom, {[i64], i64}, Transform(...)}`: a tuple whose nested element is a
  tuple embedding a list.

  Emitting that return type used to append the inner tuple's `tuple_decl`
  ahead of the `List(i64)` support instructions it references inside the
  ret-ty body, so the fork's `Sema.resolveInst` found the `List(i64)` `typeof`
  unmapped and panicked on `inst_map.get(i).?` while resolving the generic
  return type. Driving the pipeline to completion (which also instantiates the
  terminal `EmptyStage`) is what surfaced it, so every test here drives with
  `Enum.to_list`.

  The nested `[i64]` payloads are heap-allocated flat buffers, so the
  memory-wrapped cases also exercise ARC release of the inner lists (and the
  tuples that carry them) under both the default (ARC) and `Memory.Tracking`
  binaries.
  """

pub struct WithIndexListElementTest {
  use Zest.Case

  describe("with_index over a list-of-lists source") {
    test("pairs each inner list with its zero-based position") {
      result = Enum.to_list(Stream.with_index([[1, 2], [3, 4]]))
      assert(List.length(result) == 2)
      first_ok = case List.head(result) {
        {item, index} -> List.head(item) == 1 and List.length(item) == 2 and index == 0
      }
      last_ok = case List.last(result) {
        {item, index} -> List.head(item) == 3 and List.length(item) == 2 and index == 1
      }
      assert(first_ok)
      assert(last_ok)
    }

    test("a single inner list is indexed at position zero") {
      result = Enum.to_list(Stream.with_index([[7, 8, 9]]))
      assert(List.length(result) == 1)
      ok = case List.head(result) {
        {item, index} -> List.length(item) == 3 and List.last(item) == 9 and index == 0
      }
      assert(ok)
    }

    test("an empty list-of-lists source yields nothing") {
      result = Enum.to_list(Stream.with_index(([] :: [[i64]])))
      assert(List.length(result) == 0)
    }

    test("with_index preserves the inner-list contents element-for-element") {
      result = Enum.to_list(Stream.with_index([[10], [20, 21], [30, 31, 32]]))
      assert(List.length(result) == 3)
      mid_ok = case List.at(result, 1) {
        {item, index} -> List.head(item) == 20 and List.last(item) == 21 and index == 1
      }
      last_ok = case List.last(result) {
        {item, index} -> List.length(item) == 3 and List.last(item) == 32 and index == 2
      }
      assert(mid_ok)
      assert(last_ok)
    }
  }

  describe("driving list-of-lists to completion is memory-clean") {
    test("a fully-drained list-of-lists stream is fault-free") {
      assert_no_memory_faults {
        result = Enum.to_list(Stream.with_index([[1, 2], [3, 4], [5, 6]]))
        assert(List.length(result) == 3)
        ok = case List.last(result) {
          {item, index} -> List.head(item) == 5 and index == 2
        }
        assert(ok)
      }
    }

    test("an early-halted list-of-lists stream releases un-yielded pairs leak-free") {
      assert_no_leaks {
        taken = Enum.take(Stream.with_index([[1, 2], [3, 4], [5, 6], [7, 8]]), 2)
        assert(List.length(taken) == 2)
        ok = case List.head(taken) {
          {item, index} -> List.head(item) == 1 and index == 0
        }
        assert(ok)
      }
    }
  }
}
