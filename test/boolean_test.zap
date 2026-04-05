pub module Test.BooleanTest {
  use Zest
  pub fn run() -> String {
    # Boolean literals
    assert(true == true)
    reject(false == true)
    assert(false == false)

    # Boolean expressions
    assert((5 > 3) == true)
    assert((3 > 5) == false)
    assert((5 == 5) == true)
    assert((5 != 3) == true)

    # Short-circuit and/or
    assert(true and true)
    reject(true and false)
    reject(false and true)
    assert(true or false)
    assert(false or true)
    reject(false or false)

    # If-else
    assert(check_positive(5) == "positive")
    assert(check_positive(-3) == "not positive")

    "BooleanTest: passed"
  }

  fn check_positive(x :: i64) -> String {
    case x > 0 {
      true -> "positive"
      false -> "not positive"
    }
  }
}
