pub module Test.ForComprehensionTest {
  use Zest

  pub fn run() -> String {
    # Basic for comprehension — double each element
    doubled = for x <- [1, 2, 3] {
      x * 2
    }
    assert(sum(doubled) == 12)

    # For with filter — only even numbers
    evens = for x <- [1, 2, 3, 4, 5, 6], x rem 2 == 0 {
      x
    }
    assert(sum(evens) == 12)

    # For over empty list
    empty = for x <- [] {
      x * 2
    }
    assert(sum(empty) == 0)

    # For with transformation and filter
    big = for x <- [1, 2, 3, 4, 5], x > 3 {
      x * 10
    }
    assert(sum(big) == 90)

    # List cons expression [h | t]
    consed = [10 | [20, 30]]
    assert(sum(consed) == 60)

    "ForComprehensionTest: passed"
  }

  fn sum([] :: [i64]) -> i64 {
    0
  }

  fn sum([h | t] :: [i64]) -> i64 {
    h + sum(t)
  }
}
