pub module Test.ProtocolTest {
  use Zest.Case

  describe("Protocol dispatch via Enum") {
    test("Enum.each works on list via protocol") {
      result = Enum.each([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(List.length(result) == 3)
      assert(List.head(result) == 2)
    }
  }
}
