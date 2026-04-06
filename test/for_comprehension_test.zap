pub module Test.ForComprehensionTest {
  use Zest

  pub fn run() -> String {
    # Basic for comprehension — double each element
    assert(sum(for x <- [1, 2, 3] { x * 2 }) == 12)

    # For with filter — only even numbers
    assert(sum(for x <- [1, 2, 3, 4, 5, 6], x rem 2 == 0 { x }) == 12)

    # For over empty list
    assert(sum(for x <- [] { x * 2 }) == 0)

    # For with transformation and filter
    assert(sum(for x <- [1, 2, 3, 4, 5], x > 3 { x * 10 }) == 90)

    # List cons expression [h | t]
    assert(sum([10 | [20, 30]]) == 60)

    "ForComprehensionTest: passed"
  }

  fn sum([] :: [i64]) -> i64 {
    0
  }

  fn sum([h | t] :: [i64]) -> i64 {
    h + sum(t)
  }
}
