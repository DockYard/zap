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

# A stage that emits THREE String outputs per input. An early-halting consumer
# leaves ARC-backed outputs sitting in the Transform's `pending` buffer at
# dispose time — exercising that the driver releases un-yielded buffered
# outputs.
pub struct TriEmitStage {
}

pub impl Stage(String, String) for TriEmitStage {
  pub fn step(_stage :: unique TriEmitStage, item :: String) -> {Atom, [String], TriEmitStage} {
    {:cont, [item, item <> "!", item <> "!!"], %TriEmitStage{}}
  }

  pub fn flush(_stage :: unique TriEmitStage) -> [String] {
    ([] :: [String])
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

    test("take(0) pulls zero source elements") {
      result = Enum.to_list(Stream.take(%CountingSource{next_value: 1, budget: 0}, 0))
      assert(List.length(result) == 0)
    }

    test("take(0) after map runs the callback zero times and pulls nothing") {
      result = Enum.to_list(Stream.take(Stream.map(%CountingSource{next_value: 1, budget: 0}, fn(value :: i64) -> i64 { value * 10 }), 0))
      assert(List.length(result) == 0)
    }

    test("take with a negative count yields nothing without over-pulling") {
      result = Enum.to_list(Stream.take(%CountingSource{next_value: 1, budget: 0}, -3))
      assert(List.length(result) == 0)
    }

    test("filter then take pulls exactly enough to satisfy the take") {
      result = Enum.to_list(Stream.take(Stream.filter(%CountingSource{next_value: 1, budget: 4}, fn(value :: i64) -> Bool { value / 2 * 2 == value }), 2))
      assert(List.length(result) == 2)
      assert(List.head(result) == 2)
      assert(List.last(result) == 4)
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

    test("take(0) over a String source releases the source leak-free") {
      assert_no_leaks {
        result = Enum.to_list(Stream.take(["alpha", "beta", "gamma"], 0))
        assert(List.length(result) == 0)
      }
    }

    test("a multi-output String stage halted mid-pending is leak-free") {
      assert_no_leaks {
        taken = Enum.take(Stream.transform(["x", "y"], %TriEmitStage{}), 1)
        assert(List.length(taken) == 1)
        assert(List.head(taken) == "x")
      }
    }

    test("map with a String-capturing callback halted early is leak-free") {
      assert_no_leaks {
        suffix = "-tail"
        taken = Enum.take(Stream.map(["a", "b", "c"], fn(value :: String) -> String { value <> suffix }), 1)
        assert(List.length(taken) == 1)
        assert(List.head(taken) == "a-tail")
      }
    }

    test("dedupe over String payloads is fault-free to completion") {
      assert_no_memory_faults {
        result = Enum.to_list(Stream.dedupe(["a", "a", "b", "b", "b", "a"]))
        assert(List.length(result) == 3)
        assert(List.head(result) == "a")
        assert(List.last(result) == "a")
      }
    }

    test("unfold with a String accumulator reaching Stop is fault-free") {
      assert_no_memory_faults {
        result = Enum.to_list(Stream.unfold("", fn(accumulator :: String) -> UnfoldStep(i64, String) {
          if String.length(accumulator) >= 3 {
            UnfoldStep(i64, String).Stop
          } else {
            UnfoldStep.emit(String.length(accumulator), accumulator <> "x")
          }
        }))
        assert(List.length(result) == 3)
        assert(List.head(result) == 0)
        assert(List.last(result) == 2)
      }
    }
  }

  describe("adapter edge cases") {
    test("chunk_every with count 1 yields singletons") {
      result = Enum.to_list(Stream.chunk_every([1, 2, 3], 1))
      assert(List.length(result) == 3)
      assert(List.length(List.head(result)) == 1)
      assert(List.head(List.last(result)) == 3)
    }

    test("dedupe of an all-equal run collapses to one") {
      result = Enum.to_list(Stream.dedupe([7, 7, 7, 7]))
      assert(List.length(result) == 1)
      assert(List.head(result) == 7)
    }

    test("dedupe of an alternating run keeps every element") {
      result = Enum.to_list(Stream.dedupe([1, 2, 1, 2]))
      assert(List.length(result) == 4)
    }

    test("scan over an empty source yields nothing (no initial emitted)") {
      result = Enum.to_list(Stream.scan(([] :: [i64]), 100, fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value }))
      assert(List.length(result) == 0)
    }

    test("drop(0) keeps every element") {
      result = Enum.to_list(Stream.drop([1, 2, 3], 0))
      assert(List.length(result) == 3)
      assert(List.head(result) == 1)
    }

    test("drop beyond the source length yields nothing") {
      result = Enum.to_list(Stream.drop([1, 2, 3], 10))
      assert(List.length(result) == 0)
    }

    test("with_index after a filter numbers post-filter positions") {
      result = [1, 2, 3, 4, 5, 6]
        |> Stream.filter(fn(value :: i64) -> Bool { value > 2 })
        |> Stream.with_index()
        |> Enum.to_list()
      assert(List.length(result) == 4)
      first_ok = case List.head(result) { {value, index} -> value == 3 and index == 0 }
      last_ok = case List.last(result) { {value, index} -> value == 6 and index == 3 }
      assert(first_ok)
      assert(last_ok)
    }

    test("unfold that stops immediately is empty") {
      result = Enum.to_list(Stream.unfold(1, fn(_state :: i64) -> UnfoldStep(i64, i64) { UnfoldStep(i64, i64).Stop }))
      assert(List.length(result) == 0)
    }

    test("unfold that emits exactly once then stops") {
      result = Enum.to_list(Stream.unfold(1, fn(state :: i64) -> UnfoldStep(i64, i64) {
        if state == 1 { UnfoldStep.emit(state, state + 1) } else { UnfoldStep(i64, i64).Stop }
      }))
      assert(List.length(result) == 1)
      assert(List.head(result) == 1)
    }
  }

  describe("flush propagation through stage chains") {
    test("chunk_every partial flush flows through a downstream map") {
      result = [1, 2, 3, 4, 5]
        |> Stream.chunk_every(2)
        |> Stream.map(fn(chunk :: [i64]) -> i64 { List.length(chunk) })
        |> Enum.to_list()
      assert(List.length(result) == 3)
      assert(List.head(result) == 2)
      assert(List.last(result) == 1)
    }

    test("a filter upstream of chunk_every: chunking counts post-filter elements") {
      result = [1, 2, 3, 4, 5, 6, 7, 8]
        |> Stream.filter(fn(value :: i64) -> Bool { value / 2 * 2 == value })
        |> Stream.chunk_every(2)
        |> Enum.to_list()
      assert(List.length(result) == 2)
      assert(List.head(List.head(result)) == 2)
      assert(List.last(List.last(result)) == 8)
    }

    test("chunk_every then a take exceeding the length still flushes the partial") {
      result = [1, 2, 3, 4, 5]
        |> Stream.chunk_every(2)
        |> Stream.take(10)
        |> Enum.to_list()
      assert(List.length(result) == 3)
      assert(List.length(List.last(result)) == 1)
    }

    test("chunk_every then a take at a full-group boundary drops the partial") {
      result = [1, 2, 3, 4, 5]
        |> Stream.chunk_every(2)
        |> Stream.take(2)
        |> Enum.to_list()
      assert(List.length(result) == 2)
      assert(List.last(List.last(result)) == 4)
    }
  }

  describe("deep composition and alternate consumers") {
    test("map filter chunk_every take fuse across four stages") {
      result = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        |> Stream.map(fn(value :: i64) -> i64 { value * value })
        |> Stream.filter(fn(value :: i64) -> Bool { value > 4 })
        |> Stream.chunk_every(2)
        |> Stream.take(2)
        |> Enum.to_list()
      assert(List.length(result) == 2)
      assert(List.head(List.head(result)) == 9)
    }

    test("Enum.find over a stream") {
      found = Enum.find(Stream.map([1, 2, 3, 4], fn(value :: i64) -> i64 { value * value }), 0, fn(value :: i64) -> Bool { value > 5 })
      assert(found == 9)
    }

    test("Enum.any? over a stream") {
      any = Enum.any?(Stream.filter([1, 2, 3], fn(value :: i64) -> Bool { value > 1 }), fn(value :: i64) -> Bool { value == 3 })
      assert(any)
    }

    test("Enum.at over a stream") {
      value = Enum.at(Stream.map([10, 20, 30], fn(item :: i64) -> i64 { item + 1 }), 1, -1)
      assert(value == 21)
    }

    test("a for comprehension over a stream") {
      collected = for value <- Stream.map([1, 2, 3], fn(item :: i64) -> i64 { item * 100 }) {
        value + 1
      }
      assert(List.length(collected) == 3)
      assert(List.head(collected) == 101)
    }
  }

  describe("demand exactness across combinators") {
    test("drop then take pulls exactly drop+take elements") {
      result = Enum.to_list(Stream.take(Stream.drop(%CountingSource{next_value: 1, budget: 4}, 2), 2))
      assert(List.length(result) == 2)
      assert(List.head(result) == 3)
      assert(List.last(result) == 4)
    }

    test("unfold then take invokes the generator exactly take times") {
      result = Enum.to_list(Stream.take(Stream.unfold(1, fn(state :: i64) -> UnfoldStep(i64, i64) { UnfoldStep.emit(state, state + 1) }), 3))
      assert(List.length(result) == 3)
      assert(List.last(result) == 3)
    }
  }

  describe("zip") {
    test("equal-length sources pair element-wise") {
      result = Enum.to_list(Stream.zip([1, 2, 3], [10, 20, 30]))
      assert(List.length(result) == 3)
      first_ok = case List.head(result) { {left, right} -> left == 1 and right == 10 }
      last_ok = case List.last(result) { {left, right} -> left == 3 and right == 30 }
      assert(first_ok)
      assert(last_ok)
    }

    test("a shorter left source ends the zip at the left's length") {
      result = Enum.to_list(Stream.zip([1, 2], [10, 20, 30]))
      assert(List.length(result) == 2)
      last_ok = case List.last(result) { {left, right} -> left == 2 and right == 20 }
      assert(last_ok)
    }

    test("a shorter right source ends the zip at the right's length") {
      result = Enum.to_list(Stream.zip([1, 2, 3], [10, 20]))
      assert(List.length(result) == 2)
      last_ok = case List.last(result) { {left, right} -> left == 2 and right == 20 }
      assert(last_ok)
    }

    test("an empty left source yields nothing") {
      result = Enum.to_list(Stream.zip(([] :: [i64]), [10, 20]))
      assert(List.length(result) == 0)
    }

    test("an empty right source yields nothing") {
      result = Enum.to_list(Stream.zip([1, 2], ([] :: [i64])))
      assert(List.length(result) == 0)
    }

    test("zip can pair different element types") {
      result = Enum.to_list(Stream.zip([1, 2, 3], ["a", "b", "c"]))
      assert(List.length(result) == 3)
      first_ok = case List.head(result) { {index, label} -> index == 1 and label == "a" }
      assert(first_ok)
    }

    test("zip then take pulls exactly the requested pairs from both sources") {
      result = Enum.take(Stream.zip(%CountingSource{next_value: 1, budget: 2}, %CountingSource{next_value: 100, budget: 2}), 2)
      assert(List.length(result) == 2)
      first_ok = case List.head(result) { {left, right} -> left == 1 and right == 100 }
      last_ok = case List.last(result) { {left, right} -> left == 2 and right == 101 }
      assert(first_ok)
      assert(last_ok)
    }
  }

  describe("zip disposes both sources exactly once") {
    test("a completed String zip is leak-free") {
      assert_no_leaks {
        result = Enum.to_list(Stream.zip(["a", "b", "c"], ["x", "y", "z"]))
        assert(List.length(result) == 3)
        last_ok = case List.last(result) { {left, right} -> left == "c" and right == "z" }
        assert(last_ok)
      }
    }

    test("a left-terminated zip disposes the still-live right source leak-free") {
      assert_no_leaks {
        result = Enum.to_list(Stream.zip(["a", "b"], ["x", "y", "z"]))
        assert(List.length(result) == 2)
      }
    }

    test("a right-terminated zip disposes the still-live left source and drops the pulled value leak-free") {
      assert_no_leaks {
        result = Enum.to_list(Stream.zip(["a", "b", "c"], ["x", "y"]))
        assert(List.length(result) == 2)
      }
    }

    test("zip then an early take disposes both sources leak-free") {
      assert_no_leaks {
        taken = Enum.take(Stream.zip(["a", "b", "c"], ["x", "y", "z"]), 1)
        assert(List.length(taken) == 1)
        head_ok = case List.head(taken) { {left, right} -> left == "a" and right == "x" }
        assert(head_ok)
      }
    }

    test("a String zip driven to completion is fault-free under both managers") {
      assert_no_memory_faults {
        result = Enum.to_list(Stream.zip(["one", "two"], ["uno", "dos"]))
        assert(List.length(result) == 2)
        last_ok = case List.last(result) { {left, right} -> left == "two" and right == "dos" }
        assert(last_ok)
      }
    }
  }
}
