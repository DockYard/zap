pub module Test.ProtocolTest {
  use Zest.Case

  describe("Protocol dispatch") {
    test("each via Enumerable protocol on list") {
      result = Enumerable.each([1, 2, 3], fn(x :: i64) -> i64 { x * 2 })
      assert(List.head(result) == 2)
      assert(List.last(result) == 6)
      assert(List.length(result) == 3)
    }
  }
}
