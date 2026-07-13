pub struct EnumReduceWhileTest {
  use Zest.Case

  describe("Enum.reduce_while/3 — early termination") {
    test("halts mid-collection and returns the halt accumulator") {
      result = Enum.reduce_while([1, 2, 3, 4, 5], 0, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        if accumulator + element > 5 {
          {:halt, accumulator}
        } else {
          {:cont, accumulator + element}
        }
      })
      assert(result == 3)
    }

    test("halt on the first element returns the initial accumulator") {
      result = Enum.reduce_while([10, 20, 30], -1, fn(accumulator :: i64, _element :: i64) -> {Atom, i64} {
        {:halt, accumulator}
      })
      assert(result == -1)
    }

    test("halt accumulator may differ from the running accumulator") {
      result = Enum.reduce_while([1, 2, 3], 0, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        if element == 2 {
          {:halt, accumulator * 100}
        } else {
          {:cont, accumulator + element}
        }
      })
      assert(result == 100)
    }
  }

  describe("Enum.reduce_while/3 — full traversal") {
    test("runs to completion when the callback never halts") {
      result = Enum.reduce_while([1, 2, 3, 4], 0, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        {:cont, accumulator + element}
      })
      assert(result == 10)
    }

    test("empty collection returns the initial accumulator") {
      result = Enum.reduce_while([], 42, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        {:cont, accumulator + element}
      })
      assert(result == 42)
    }

    test("matches Enum.reduce when never halting") {
      collection = [5, 6, 7]
      folded = Enum.reduce_while(collection, 0, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        {:cont, accumulator + element}
      })
      reduced = Enum.reduce(collection, 0, fn(accumulator :: i64, element :: i64) -> i64 {
        accumulator + element
      })
      assert(folded == reduced)
    }
  }

  describe("Enum.reduce_while/3 — over Range") {
    test("halts mid-range") {
      result = Enum.reduce_while(1..10, 0, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        if element > 3 {
          {:halt, accumulator}
        } else {
          {:cont, accumulator + element}
        }
      })
      assert(result == 6)
    }

    test("runs a full range to completion") {
      result = Enum.reduce_while(1..4, 0, fn(accumulator :: i64, element :: i64) -> {Atom, i64} {
        {:cont, accumulator + element}
      })
      assert(result == 10)
    }
  }

  describe("Enum.reduce_while/3 — non-integer accumulators") {
    test("accumulates a count-and-sum tuple until halting") {
      result = Enum.reduce_while([1, 2, 3, 4, 5], {0, 0}, fn(accumulator :: {i64, i64}, element :: i64) -> {Atom, {i64, i64}} {
        case accumulator {
          {count, sum} ->
            if count == 3 {
              {:halt, accumulator}
            } else {
              {:cont, {count + 1, sum + element}}
            }
        }
      })
      halted_at_three = case result {
        {count, sum} -> count == 3 and sum == 6
      }
      assert(halted_at_three)
    }

    test("builds a string accumulator across the whole collection") {
      result = Enum.reduce_while(["a", "b", "c"], "", fn(accumulator :: String, element :: String) -> {Atom, String} {
        {:cont, accumulator <> element}
      })
      assert(result == "abc")
    }
  }
}
