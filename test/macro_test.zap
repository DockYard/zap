pub module Test.MacroTest {
  use Zest
  pub fn run() -> String {
    # if macro
    assert(if_true() == "yes")
    assert(if_false() == "no")

    "MacroTest: passed"
  }

  fn if_true() -> String {
    case true {
      true -> "yes"
      false -> "no"
    }
  }

  fn if_false() -> String {
    case false {
      true -> "yes"
      false -> "no"
    }
  }
}
