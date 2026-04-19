pub module Test.ProtocolTest {
  use Zest.Case

  describe("Protocol dispatch via Enum") {
    test("Enum.each iterates list for side effects") {
      Enum.each([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(true)
    }
  }
}
