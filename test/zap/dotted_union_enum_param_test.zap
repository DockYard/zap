@doc = """
  Regression: a PARAMETER typed as a payloadless union / enum — a top-level
  DOTTED union (`Sample.Mode`, the exact shape of the stdlib `IO.Mode`), a
  non-dotted union (`Signal`), or the stdlib `IO.Mode` itself — must compile and
  run when threaded through direct calls AND through closures dispatched
  indirectly (the runtime bare-fn bridge).

  Payloadless unions/enums have NO nominal ZIR type: the frontend registers them
  as `enum_def`s and their variant VALUES lower to `u32` ATOM IDs (`.enum_literal`
  -> `atomIntern`); `==` compares those atoms, and the `:zig.` runtime boundary
  (`IO.set_terminal_mode(mode: u32)`) receives the atom as `u32`. The parameter's
  canonical type is therefore `u32`.

  A prior fix that emitted a CONCRETE type for a union/enum parameter (correct for
  a payload-carrying `Result(t, e)` element, whose specialization IS a nominal
  `union(enum)` module) over-fired on payloadless unions/enums and routed them
  through the nominal-type dispatcher instead. That broke every payloadless-union
  parameter: a top-level dotted enum (`IO.Mode`) emitted `@import("IO").Mode`, but
  the function-bearing `IO` file-struct never re-exports the `Mode` leaf ("root
  source file struct 'IO' has no member named 'Mode'"); a non-dotted enum
  (`Signal`) emitted the nominal `Signal.Signal`, mismatching the `u32` atom the
  caller materializes ("expected type 'Signal.Signal', found 'u32'"). No compiled
  test threaded a payloadless-union parameter, so the break stayed green. The
  documented, public `IO.mode/1` and `IO.mode/2` are the canonical victims; these
  cases pin the atom-parameter representation across every dispatch shape.

  `IO.mode(IO.Mode.Normal, ...)` is safe to run in-process: `set_terminal_mode`
  with the `Normal` atom restores line-buffered mode, and the restore is a no-op
  when raw mode was never entered — the test never enters raw mode.

  Conformance: this file declares EXACTLY ONE method-bearing struct
  (`Zap.DottedUnionEnumParamTest`) so `validateOneStructPerFile` accepts it into
  the manifest full-suite. The payloadless unions are top-level `union` decls
  (which do not count as structs); `Sample` is a FIELD-ONLY data struct that
  exists solely to anchor the dotted `Sample.Mode` leaf; the helper functions
  (`identity`, `with_mode`, `relay`) that thread the union params live INSIDE the
  single test struct alongside the `use Zest.Case` describe block, mirroring
  `test/zap/boxed_result_element_callback_test.zap`.
  """

pub union Signal {
  High,
  Low
}

pub struct Sample {
  seed :: i64
}

pub union Sample.Mode {
  On,
  Off
}

pub struct Zap.DottedUnionEnumParamTest {
  use Zest.Case

  describe("payloadless union / enum parameters lower to u32 atoms") {
    test("a top-level dotted-union parameter round-trips its atom value (Sample.Mode, IO.Mode shape)") {
      restored = identity(Sample.Mode.On)
      assert(restored == Sample.Mode.On)
      reject(restored == Sample.Mode.Off)
    }

    test("a dotted-union parameter alongside a returning callback (IO.mode/2 shape)") {
      produced = with_mode(Sample.Mode.Off, fn() -> i64 { 77 })
      assert(produced == 77)
    }

    test("a non-dotted union parameter threads through an indirectly-dispatched closure") {
      relayed = relay(fn(_signal :: Signal) -> i64 { 5 }, Signal.High)
      assert(relayed == 5)
    }

    test("the documented stdlib IO.mode/2 compiles and returns its callback result") {
      result = IO.mode(IO.Mode.Normal, fn() -> i64 { 42 })
      assert(result == 42)
    }

    test("the documented stdlib IO.mode/1 compiles and round-trips its mode value") {
      restored = IO.mode(IO.Mode.Normal)
      assert(restored == IO.Mode.Normal)
    }
  }

  fn identity(mode :: Sample.Mode) -> Sample.Mode {
    mode
  }

  fn with_mode(_mode :: Sample.Mode, callback :: fn() -> i64) -> i64 {
    callback()
  }

  fn relay(callback :: fn(Signal) -> i64, signal :: Signal) -> i64 {
    callback(signal)
  }
}
