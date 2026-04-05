pub module Test.TupleTest {
  use Zest

  pub fn run() -> String {
    # Tuple pattern matching — extract elements
    assert(first({1, 2}) == 1)
    assert(second({10, 20}) == 20)
    assert(sum_tuple({3, 4}) == 7)

    # Wildcard patterns
    assert(second_wild({10, 20}) == 20)
    assert(first_wild({10, 20}) == 10)

    # Arithmetic on tuple elements
    assert(double_second({5, 7}) == 14)

    "TupleTest: passed"
  }

  fn first(t :: {i64, i64}) -> i64 {
    case t {
      {a, b} -> a
    }
  }

  fn second(t :: {i64, i64}) -> i64 {
    case t {
      {a, b} -> b
    }
  }

  fn sum_tuple(t :: {i64, i64}) -> i64 {
    case t {
      {a, b} -> a + b
    }
  }

  fn second_wild(t :: {i64, i64}) -> i64 {
    case t {
      {_, b} -> b
    }
  }

  fn first_wild(t :: {i64, i64}) -> i64 {
    case t {
      {a, _} -> a
    }
  }

  fn double_second(t :: {i64, i64}) -> i64 {
    case t {
      {_, b} -> b + b
    }
  }
}
