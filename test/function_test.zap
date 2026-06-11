pub struct FunctionTest {
  use Zest.Case

  describe("functions") {
    test("multi-clause dispatch matches zero") {
      assert(classify(0) == "zero")
    }

    test("multi-clause dispatch matches one") {
      assert(classify(1) == "one")
    }

    test("multi-clause dispatch falls through to other") {
      assert(classify(42) == "other")
    }

    test("string function greets correctly") {
      assert(greet("World") == "Hello, World!")
    }

    test("generic identity with integer") {
      assert(identity(42) == 42)
    }

    test("generic identity with bool") {
      assert(identity(true) == true)
    }

    test("generic identity with string") {
      assert(identity("hello") == "hello")
    }

    test("assignment shadows parameter with rebind") {
      ## Elixir-style shadowing: `x = expr` rebinds the name `x` so
      ## every later reference resolves to the new value, not the
      ## parameter slot. Without this, `values = List.set(values, ...)`
      ## patterns silently miscompile once `List(T)` becomes
      ## ARC-managed (the COW clone path produces a new buffer for
      ## the rebinding while every later use of `arr` still observes
      ## the pre-call parameter).
      assert(rebind_param(5) == 105)
    }

    test("chained shadow rebinds compose left-to-right") {
      assert(rebind_chain(5) == 106)
    }

    test("non-shadow binding still resolves to its own local") {
      ## Sanity baseline: a fresh name (`y`) should not be confused
      ## with the parameter (`x`) by the most-recent-wins resolution.
      assert(add100(5) == 105)
    }

    test("assignment chain reuses previous bindings") {
      assert(assignment_chain() == 60)
    }

    test("multi-clause string patterns dispatch by literal") {
      assert(parse_word("one") == "1")
      assert(parse_word("two") == "2")
      assert(parse_word("three") == "?")
    }

    test("atom literal patterns dispatch in function heads") {
      assert(status(:ok) == "success")
      assert(status(:error) == "failure")
    }
  }

  fn rebind_param(x :: i64) -> i64 {
    x = x + 100
    x
  }

  fn rebind_chain(x :: i64) -> i64 {
    x = x + 100
    x = x + 1
    x
  }

  fn add100(x :: i64) -> i64 {
    y = x + 100
    y
  }

  fn assignment_chain() -> i64 {
    a = 10
    b = a + 20
    b * 2
  }

  fn classify(0 :: i64) -> String {
    "zero"
  }

  fn classify(1 :: i64) -> String {
    "one"
  }

  fn classify(_ :: i64) -> String {
    "other"
  }

  fn greet(name :: String) -> String {
    "Hello, " <> name <> "!"
  }

  fn parse_word("one" :: String) -> String {
    "1"
  }

  fn parse_word("two" :: String) -> String {
    "2"
  }

  fn parse_word(_ :: String) -> String {
    "?"
  }

  fn status(:ok :: Atom) -> String {
    "success"
  }

  fn status(:error :: Atom) -> String {
    "failure"
  }

  fn identity(x :: element) -> element {
    x
  }
}
