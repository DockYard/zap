pub module Test.BinaryPatternTest {
  use Zest.Case
  pub fn run() -> String {
    describe("binary") {
      test("extract byte") {
        assert(first_byte("AB") == 65)
      }
    }
  }
  fn first_byte(data :: String) -> i64 {
    case data {
      <<a, _>> -> a
      _ -> 0
    }
  }
}
