@doc = """
  Behavioural tests for the `Stream` module: every lazy adapter over a `List`
  source, chunk-flush edges, demand-driven laziness with exact source-pull
  counts, multi-stage composition, per-adapter edge cases, and ARC (`String`)
  payloads streamed to completion and through an early-halt disposal — the
  latter wrapped so they verify clean under both the default (ARC) and
  `Memory.Tracking` binaries.
  """

# A source that yields an increasing counter and panics if pulled more than
# `budget` times — turns "exactly N pulls" into a checkable property.
pub struct CountingSource {
  next_value :: i64
  budget :: i64
}

pub impl Enumerable(i64) for CountingSource {
  pub fn next(self :: unique CountingSource) -> {Atom, i64, CountingSource} {
    if self.budget <= 0 {
      panic("CountingSource over-pulled")
    } else {
      {:cont, self.next_value, %CountingSource{next_value: self.next_value + 1, budget: self.budget - 1}}
    }
  }

  pub fn dispose(_self :: unique CountingSource) -> Nil {
    nil
  }
}

pub struct StreamTest {
  use Zest.Case

  describe("adapter happy paths") {
    test("map") {
      result = Enum.to_list(Stream.map([1, 2, 3], fn(value :: i64) -> i64 { value * 10 }))
      assert(List.length(result) == 3)
      assert(List.head(result) == 10)
      assert(List.last(result) == 30)
    }

    test("filter") {
      result = Enum.to_list(Stream.filter([1, 2, 3, 4, 5], fn(value :: i64) -> Bool { value > 2 }))
      assert(List.length(result) == 3)
      assert(List.head(result) == 3)
    }

    test("reject") {
      result = Enum.to_list(Stream.reject([1, 2, 3, 4], fn(value :: i64) -> Bool { value > 2 }))
      assert(List.length(result) == 2)
      assert(List.last(result) == 2)
    }

    test("take") {
      result = Enum.to_list(Stream.take([1, 2, 3, 4, 5], 3))
      assert(List.length(result) == 3)
      assert(List.last(result) == 3)
    }

    test("take more than available yields all") {
      result = Enum.to_list(Stream.take([1, 2], 10))
      assert(List.length(result) == 2)
    }

    test("drop") {
      result = Enum.to_list(Stream.drop([1, 2, 3, 4, 5], 2))
      assert(List.length(result) == 3)
      assert(List.head(result) == 3)
    }
  }

  describe("stateful adapter edges") {
    test("take_while stops at the first failing element") {
      result = Enum.to_list(Stream.take_while([1, 2, 3, 1], fn(value :: i64) -> Bool { value < 3 }))
      assert(List.length(result) == 2)
      assert(List.last(result) == 2)
    }

    test("take_while that never fails yields all") {
      result = Enum.to_list(Stream.take_while([1, 2, 3], fn(value :: i64) -> Bool { value < 100 }))
      assert(List.length(result) == 3)
    }

    test("take_while that fails immediately yields nothing") {
      result = Enum.to_list(Stream.take_while([5, 1, 2], fn(value :: i64) -> Bool { value < 3 }))
      assert(List.length(result) == 0)
    }

    test("drop_while drops the leading run then yields the rest") {
      result = Enum.to_list(Stream.drop_while([1, 2, 3, 1], fn(value :: i64) -> Bool { value < 3 }))
      assert(List.length(result) == 2)
      assert(List.head(result) == 3)
      assert(List.last(result) == 1)
    }

    test("drop_while that matches everything yields nothing") {
      result = Enum.to_list(Stream.drop_while([1, 2, 1], fn(value :: i64) -> Bool { value < 100 }))
      assert(List.length(result) == 0)
    }

    test("scan emits the running accumulator") {
      result = Enum.to_list(Stream.scan([1, 2, 3, 4], 0, fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value }))
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == 10)
    }

    test("scan over strings") {
      result = Enum.to_list(Stream.scan(["a", "b", "c"], "", fn(accumulator :: String, value :: String) -> String { accumulator <> value }))
      assert(List.length(result) == 3)
      assert(List.head(result) == "a")
      assert(List.last(result) == "abc")
    }

    test("dedupe collapses consecutive duplicates only") {
      result = Enum.to_list(Stream.dedupe([1, 1, 2, 2, 2, 3, 1]))
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == 1)
    }

    test("dedupe of an empty stream is empty") {
      result = Enum.to_list(Stream.dedupe(([] :: [i64])))
      assert(List.length(result) == 0)
    }

    test("with_index pairs elements with positions") {
      result = Enum.to_list(Stream.with_index([10, 20, 30]))
      assert(List.length(result) == 3)
      first_ok = case List.head(result) { {value, index} -> value == 10 and index == 0 }
      last_ok = case List.last(result) { {value, index} -> value == 30 and index == 2 }
      assert(first_ok)
      assert(last_ok)
    }
  }

  describe("chunk_every flush edges") {
    test("chunk_every over 5 with a partial final group") {
      result = Enum.to_list(Stream.chunk_every([1, 2, 3, 4, 5], 3))
      assert(List.length(result) == 2)
      assert(List.length(List.head(result)) == 3)
      assert(List.length(List.last(result)) == 2)
      assert(List.head(List.last(result)) == 4)
    }

    test("chunk_every over an exact multiple has no partial group") {
      result = Enum.to_list(Stream.chunk_every([1, 2, 3, 4, 5, 6], 3))
      assert(List.length(result) == 2)
      assert(List.length(List.last(result)) == 3)
    }

    test("chunk_every over an empty source is empty") {
      result = Enum.to_list(Stream.chunk_every(([] :: [i64]), 3))
      assert(List.length(result) == 0)
    }
  }

  describe("laziness and exact source-pull counts") {
    test("take pulls no more than requested (source over-pull panics)") {
      result = Enum.to_list(Stream.take(%CountingSource{next_value: 1, budget: 2}, 2))
      assert(List.length(result) == 2)
      assert(List.head(result) == 1)
      assert(List.last(result) == 2)
    }

    test("map then take pulls exactly three source elements") {
      result = Enum.to_list(Stream.take(Stream.map(%CountingSource{next_value: 1, budget: 3}, fn(value :: i64) -> i64 { value * 10 }), 3))
      assert(List.length(result) == 3)
      assert(List.head(result) == 10)
      assert(List.last(result) == 30)
    }

    test("map then chunk_every then take stays lazy on pull count") {
      pipeline = %CountingSource{next_value: 1, budget: 4}
        |> Stream.map(fn(value :: i64) -> i64 { value + 100 })
        |> Stream.chunk_every(2)
        |> Stream.take(2)
      result = Enum.to_list(pipeline)
      assert(List.length(result) == 2)
      assert(List.length(List.head(result)) == 2)
      assert(List.head(List.head(result)) == 101)
    }
  }

  describe("composition") {
    test("map filter take fuse in one pass") {
      result = [1, 2, 3, 4, 5, 6]
        |> Stream.map(fn(value :: i64) -> i64 { value * value })
        |> Stream.filter(fn(value :: i64) -> Bool { value > 4 })
        |> Stream.take(2)
        |> Enum.to_list()
      assert(List.length(result) == 2)
      assert(List.head(result) == 9)
      assert(List.last(result) == 16)
    }

    test("a stream folds with Enum.reduce") {
      total = Enum.reduce(Stream.map([1, 2, 3, 4], fn(value :: i64) -> i64 { value * 2 }), 0, fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value })
      assert(total == 20)
    }
  }

  describe("unfold") {
    test("finite unfold ends on Stop") {
      result = Enum.to_list(Stream.unfold(1, fn(state :: i64) -> UnfoldStep(i64, i64) {
        if state > 4 { UnfoldStep(i64, i64).Stop } else { UnfoldStep.emit(state, state + 1) }
      }))
      assert(List.length(result) == 4)
      assert(List.head(result) == 1)
      assert(List.last(result) == 4)
    }

    test("an infinite unfold is safe under a bounded consumer") {
      result = Enum.to_list(Stream.take(Stream.unfold(1, fn(state :: i64) -> UnfoldStep(i64, i64) { UnfoldStep.emit(state, state * 2) }), 5))
      assert(List.length(result) == 5)
      assert(List.head(result) == 1)
      assert(List.last(result) == 16)
    }

    test("unfold can change element and accumulator types") {
      result = Enum.to_list(Stream.unfold(1, fn(state :: i64) -> UnfoldStep(String, i64) {
        if state > 3 { UnfoldStep(String, i64).Stop } else { UnfoldStep.emit(Integer.to_string(state), state + 1) }
      }))
      assert(List.length(result) == 3)
      assert(List.head(result) == "1")
      assert(List.last(result) == "3")
    }
  }

  describe("ARC String payloads are clean under both managers") {
    test("a String stream driven to completion is fault-free") {
      assert_no_memory_faults {
        result = Enum.to_list(Stream.map([1, 2, 3], fn(value :: i64) -> String { Integer.to_string(value) <> "!" }))
        assert(List.length(result) == 3)
        assert(List.head(result) == "1!")
        assert(List.last(result) == "3!")
      }
    }

    test("a String stream disposed after an early halt is fault-free") {
      assert_no_memory_faults {
        taken = Enum.take(Stream.map(["alpha", "beta", "gamma"], fn(value :: String) -> String { value <> "?" }), 2)
        assert(List.length(taken) == 2)
        assert(List.head(taken) == "alpha?")
        assert(List.last(taken) == "beta?")
      }
    }

    test("a filtered String stream is leak-free") {
      assert_no_leaks {
        result = Enum.to_list(Stream.filter(["a", "bb", "ccc", "dddd"], fn(value :: String) -> Bool { String.length(value) > 2 }))
        assert(List.length(result) == 2)
        assert(List.head(result) == "ccc")
      }
    }
  }
}
