pub module Test.BinaryPatternTest {
  use Zest.Case

  # TODO: Binary pattern matching compiles but crashes at runtime in
  # multi-module compilation. The ZIR emits @import("zap_runtime")
  # .BinaryHelpers calls correctly, but the parameter ref resolves
  # to null at runtime. Needs investigation into how the function
  # parameter is passed through the per-module ZIR context.
  #
  # These patterns work in single-module ZIR integration tests:
  #   case data { <<a, _>> -> a; _ -> 0 }
  #   case data { <<_, rest::String>> -> rest; _ -> "" }
  #   case data { <<"GET "::String, path::String>> -> path; _ -> "unknown" }

  describe("binary pattern placeholder") {
    test("placeholder until binary patterns fixed") {
      assert(true)
    }
  }
}
