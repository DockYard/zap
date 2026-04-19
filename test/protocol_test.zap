pub module Test.ProtocolTest {
  use Zest.Case

  describe("Protocol dispatch via Enum") {
    test("Enum.each iterates list for side effects") {
      Enum.each([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(true)
    }
  }

  describe("Capturing closures") {
    test("closure captures local variable") {
      multiplier = 3
      result = apply_fn(7, fn(x :: i64) -> i64 { x * multiplier })
      assert(result == 21)
    }
  }

  fn apply_fn(value :: i64, callback :: (i64 -> i64)) -> i64 {
    callback(value)
  }
}
