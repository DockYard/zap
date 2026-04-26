pub struct Test.ForComprehensionTest {
  use Zest.Case

  fn double_all([] :: [i64]) -> [i64] {
    []
  }

  fn double_all([h | t] :: [i64]) -> [i64] {
    [h * 2 | double_all(t)]
  }

  describe("cons pattern dispatch") {
    test("double_all doubles each element") {
      result = double_all([1, 2, 3])
      assert(List.length(result) == 3)
      assert(List.head(result) == 2)
    }

    test("handles empty list") {
      assert(List.length(double_all([])) == 0)
    }
  }

  describe("for comprehension") {
    test("maps with multiplication") {
      result = for x <- [1, 2, 3] { x * 2 }
      assert(List.length(result) == 3)
      assert(List.head(result) == 2)
    }

    test("maps with addition") {
      result = for x <- [10, 20, 30] { x + 1 }
      assert(List.length(result) == 3)
      assert(List.head(result) == 11)
    }

    test("handles single element") {
      result = for x <- [42] { x + 8 }
      assert(List.length(result) == 1)
      assert(List.head(result) == 50)
    }

    test("identity transformation") {
      result = for x <- [5, 10, 15] { x }
      assert(List.length(result) == 3)
      assert(List.head(result) == 5)
    }
  }

  describe("for comprehension destructuring") {
    test("type annotation on bare bind") {
      result = for x :: i64 <- [1, 2, 3] { x + 100 }
      assert(List.length(result) == 3)
      assert(List.head(result) == 101)
    }
  }
}
