pub module Test.MathTest {
  use Zest.Case

  describe("Math module") {
    test("pi value") {
      assert(Math.pi() == 3.141592653589793)
    }

    test("e value") {
      assert(Math.e() == 2.718281828459045)
    }

    test("sqrt of 9") {
      assert(Math.sqrt(9.0) == 3.0)
    }

    test("sqrt of 0") {
      assert(Math.sqrt(0.0) == 0.0)
    }

    test("sqrt of 1") {
      assert(Math.sqrt(1.0) == 1.0)
    }

    test("sin of 0") {
      assert(Math.sin(0.0) == 0.0)
    }

    test("cos of 0") {
      assert(Math.cos(0.0) == 1.0)
    }

    test("tan of 0") {
      assert(Math.tan(0.0) == 0.0)
    }

    test("exp of 0") {
      assert(Math.exp(0.0) == 1.0)
    }

    test("exp2 of 3") {
      assert(Math.exp2(3.0) == 8.0)
    }

    test("exp2 of 0") {
      assert(Math.exp2(0.0) == 1.0)
    }

    test("log of 1") {
      assert(Math.log(1.0) == 0.0)
    }

    test("log2 of 8") {
      assert(Math.log2(8.0) == 3.0)
    }

    test("log2 of 1") {
      assert(Math.log2(1.0) == 0.0)
    }

    test("log10 of 1000") {
      assert(Math.log10(1000.0) == 3.0)
    }

    test("log10 of 1") {
      assert(Math.log10(1.0) == 0.0)
    }
  }
}
