pub module Test.TupleTest {
  use Zest.Case

  describe("tuples") {
    test("extract first element") {
      assert(first({1, 2}) == 1)
    }

    test("extract second element") {
      assert(second({10, 20}) == 20)
    }

    test("sum tuple elements") {
      assert(sum_tuple({3, 4}) == 7)
    }

    test("second with wildcard first") {
      assert(second_wild({10, 20}) == 20)
    }

    test("first with wildcard second") {
      assert(first_wild({10, 20}) == 10)
    }

    test("double second element") {
      assert(double_second({5, 7}) == 14)
    }
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
