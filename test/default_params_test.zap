pub struct DefaultParamsTest {
  use Zest.Case

  describe("default params") {
    test("integer default is used when arg omitted") {
      assert(add(5) == 15)
    }

    test("integer default is overridden when arg provided") {
      assert(add(5, 20) == 25)
    }

    test("string default is used when arg omitted") {
      assert(greet("World") == "Hello, World!")
    }

    test("string default is overridden when arg provided") {
      assert(greet("World", "Hi") == "Hi, World!")
    }
  }

  # Regression for audit finding zirb-2--02: name-based default-argument
  # inlining hijacked arity overloads. When a struct defines BOTH `pick/1`
  # (no defaults) and a defaults-bearing `pick/3`, a call the type checker
  # resolved to `pick/1` was silently rewritten by the ZIR default-fill scan
  # to call `pick/3` (with defaults appended) because the scan matched on the
  # arity-stripped BASE name and picked the first defaults-bearing function.
  # The fix keys the default-fill on the EXACT resolved mangled name, so the
  # type checker's overload choice is honored.
  describe("default-arg inlining respects the resolved overload (zirb-2--02)") {
    test("a 1-arg call runs the no-default arity-1 clause, not the defaults-bearing arity-3") {
      # Pre-fix this returned 10 (5 + 2 + 3 via the hijacked pick/3); the
      # type checker resolved to pick/1, whose body multiplies by 1000.
      assert(pick(5) == 5000)
    }

    test("a 3-arg call still runs the arity-3 clause") {
      assert(pick(5, 20, 30) == 55)
    }

    test("the defaults-bearing clause still applies its defaults when partially applied") {
      # pick/3 called with 1 arg is a DIFFERENT base name (`spread`) so no
      # arity-1 sibling exists; the default-fill must apply here.
      assert(spread(5) == 10)
    }

    test("the defaults-bearing clause overrides defaults when args provided") {
      assert(spread(5, 20) == 28)
    }

    test("CROSS-STRUCT a 1-arg call runs the no-default arity-1 clause") {
      assert(DefaultParamsOverloadHelper.pick(5) == 5000)
    }

    test("CROSS-STRUCT a 3-arg call runs the arity-3 clause") {
      assert(DefaultParamsOverloadHelper.pick(5, 20, 30) == 55)
    }

    test("CROSS-STRUCT a 2-arg call applies the trailing default") {
      assert(DefaultParamsOverloadHelper.pick(5, 20) == 28)
    }
  }

  fn add(a :: i64, b :: i64 = 10) -> i64 {
    a + b
  }

  fn greet(name :: String, greeting :: String = "Hello") -> String {
    greeting <> ", " <> name <> "!"
  }

  # ---- zirb-2--02 overload-vs-default fixtures ----

  # `pick/1` (no defaults) coexists with a defaults-bearing `pick/3`. A 1-arg
  # call must run THIS body (multiply by 1000), not be hijacked into pick/3.
  fn pick(a :: i64) -> i64 {
    a * 1000
  }

  fn pick(a :: i64, b :: i64 = 2, c :: i64 = 3) -> i64 {
    a + b + c
  }

  # A defaults-bearing function with NO arity-1 sibling — the legitimate
  # default-fill path must still work (1 arg -> 5 + 2 + 3 = 10).
  fn spread(a :: i64, b :: i64 = 2, c :: i64 = 3) -> i64 {
    a + b + c
  }
}
