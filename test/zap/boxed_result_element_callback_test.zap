@doc = """
  Regression: the `Enum` higher-order functions that thread a USER callback
  over an `Enumerable` whose ELEMENT is a `Result(t, e)` union — the exact
  shape of `Socket.chunks`' `Enumerable(Result(String, SocketError))`.

  `reduce_next`/`each_next`/`reduce_while_next` (lib/enum.zap) pass the element
  materialized out of `Enumerable.next` straight into the fn-typed parameter
  (`callback(accumulator, value)`), which lowers through
  `Kernel.callCallableN` → `runtime.callBareN`. No existing test drove that
  path with a user callback over a custom `impl Enumerable(Result(...))`: the
  boxed-element corpus (`test/zap/combinator_map_boxed_test.zap`) covers a
  boxed `Callable` element out of a plain `[fn]` List, and the box-only
  fixture (`src/zir_integration_tests.zig`) uses `Enum.to_list` with NO
  callback. Both the callback-dispatch shape AND constant-stack behaviour are
  covered here.

  The self-recursive `_next` helpers sit in a `case`/`union_switch` leaf, so
  they only became tail-recursive once the frontend tail-call rewriter learned
  to descend `case_block`/`union_switch` decision trees (S1 Pass 2c). Before
  that, `reduce`/`each`/`reduce_while` over this stream grew the stack
  per element and overflowed at a few hundred elements — a peer-triggerable
  crash on the streaming `Socket.chunks` flagship. The large-count cases below
  guard that constant-stack behaviour.

  `StreamError` mirrors `SocketError` being a struct-shaped (non-primitive)
  error arm; the `Ok` payload is a heap-allocated `String`, so the ARC/Tracking
  leak surface matches the production element. Leak-cleanliness under the
  `-Dmemory`-selected `Memory.Tracking` manager (which Zest cannot set) is
  covered by the companion fixture in `src/zir_integration_tests.zig`.
  """

pub struct StreamError {
  reason :: Atom
}

pub struct ResultElementStream {
  remaining :: i64
}

pub impl Enumerable(Result(String, StreamError)) for ResultElementStream {
  pub fn next(self :: unique ResultElementStream) -> {Atom, Result(String, StreamError), ResultElementStream} {
    case self.remaining > 0 {
      true  -> {:cont, Result(String, StreamError).Ok("chunk"), %ResultElementStream{remaining: self.remaining - 1}}
      false -> {:done, Result(String, StreamError).Ok(""), self}
    }
  }

  pub fn dispose(_self :: unique ResultElementStream) -> Nil {
    nil
  }
}

pub struct Zap.BoxedResultElementCallbackTest {
  use Zest.Case

  describe("Enum HOFs threading a user callback over a Result-element Enumerable") {
    test("reduce accumulates over every Ok element, driven to :done") {
      count = Enum.reduce(%ResultElementStream{remaining: 4}, 0, fn(accumulator :: i64, chunk :: Result(String, StreamError)) -> i64 {
        case chunk {
          Result.Ok(_bytes) -> accumulator + 1
          Result.Error(_error) -> accumulator
        }
      })
      assert(count == 4)
    }

    test("reduce reconstructs a value from the boxed element payload") {
      total_bytes = Enum.reduce(%ResultElementStream{remaining: 5}, 0, fn(accumulator :: i64, chunk :: Result(String, StreamError)) -> i64 {
        case chunk {
          Result.Ok(bytes) -> accumulator + String.length(bytes)
          Result.Error(_error) -> accumulator
        }
      })
      assert(total_bytes == 25)
    }

    test("reduce_while halts early on the boxed element") {
      halted = Enum.reduce_while(%ResultElementStream{remaining: 10}, 0, fn(accumulator :: i64, chunk :: Result(String, StreamError)) -> {Atom, i64} {
        case chunk {
          Result.Ok(_bytes) ->
            if accumulator >= 3 {
              {:halt, accumulator}
            } else {
              {:cont, accumulator + 1}
            }
          Result.Error(_error) -> {:cont, accumulator}
        }
      })
      assert(halted == 3)
    }

    test("each visits every boxed element (asserting per-element) and returns nil at :done") {
      outcome = Enum.each(%ResultElementStream{remaining: 4}, assert_chunk_is_ok)
      assert(each_returned_nil(outcome))
    }

    test("take short-circuits the boxed stream after the requested count") {
      taken = Enum.take(%ResultElementStream{remaining: 8}, 3)
      assert(List.length(taken) == 3)
    }

    test("reduce stays constant-stack over a large boxed stream") {
      count = Enum.reduce(%ResultElementStream{remaining: 5000}, 0, fn(accumulator :: i64, chunk :: Result(String, StreamError)) -> i64 {
        case chunk {
          Result.Ok(_bytes) -> accumulator + 1
          Result.Error(_error) -> accumulator
        }
      })
      assert(count == 5000)
    }

    test("reduce_while stays constant-stack before its early halt over a large boxed stream") {
      halted = Enum.reduce_while(%ResultElementStream{remaining: 5000}, 0, fn(accumulator :: i64, chunk :: Result(String, StreamError)) -> {Atom, i64} {
        case chunk {
          Result.Ok(_bytes) ->
            if accumulator >= 4000 {
              {:halt, accumulator}
            } else {
              {:cont, accumulator + 1}
            }
          Result.Error(_error) -> {:cont, accumulator}
        }
      })
      assert(halted == 4000)
    }

    test("each stays constant-stack over a large boxed stream") {
      outcome = Enum.each(%ResultElementStream{remaining: 5000}, assert_chunk_is_ok)
      assert(each_returned_nil(outcome))
    }
  }

  fn assert_chunk_is_ok(chunk :: Result(String, StreamError)) -> Nil {
    case chunk {
      Result.Ok(_bytes) -> assert(true)
      Result.Error(_error) -> assert(false)
    }
    nil
  }

  # `Enum.each` returns `Nil`; binding its result to a `Nil`-typed parameter
  # compile-time-confirms the each drove to `:done` and yielded `Nil` (the same
  # idiom the stdlib `enum_test.zap` uses — `is_nil?` boxes the void-like `Nil`
  # into `any` and does not report it as nil).
  fn each_returned_nil(_outcome :: Nil) -> Bool {
    true
  }
}
