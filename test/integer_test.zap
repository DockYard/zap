pub module Test.IntegerTest {
  use Zest.Case

  describe("Integer module") {
    test("to_string positive") {
      assert(Integer.to_string(42) == "42")
    }

    test("to_string negative") {
      assert(Integer.to_string(-7) == "-7")
    }

    test("to_string zero") {
      assert(Integer.to_string(0) == "0")
    }

    test("abs positive") {
      assert(Integer.abs(42) == 42)
    }

    test("abs negative") {
      assert(Integer.abs(-42) == 42)
    }

    test("abs zero") {
      assert(Integer.abs(0) == 0)
    }

    test("max returns larger") {
      assert(Integer.max(3, 7) == 7)
    }

    test("max returns first when larger") {
      assert(Integer.max(10, 2) == 10)
    }

    test("max equal") {
      assert(Integer.max(5, 5) == 5)
    }

    test("max negatives") {
      assert(Integer.max(-3, -7) == -3)
    }

    test("min returns smaller") {
      assert(Integer.min(3, 7) == 3)
    }

    test("min returns first when smaller") {
      assert(Integer.min(2, 10) == 2)
    }

    test("min equal") {
      assert(Integer.min(5, 5) == 5)
    }

    test("min negatives") {
      assert(Integer.min(-3, -7) == -7)
    }

    test("parse positive") {
      assert(Integer.parse("42") == 42)
    }

    test("parse negative") {
      assert(Integer.parse("-7") == -7)
    }

    test("parse invalid") {
      assert(Integer.parse("hello") == 0)
    }

    test("parse zero") {
      assert(Integer.parse("0") == 0)
    }

    test("remainder basic") {
      assert(Integer.remainder(10, 3) == 1)
    }

    test("remainder even division") {
      assert(Integer.remainder(6, 3) == 0)
    }

    test("remainder odd") {
      assert(Integer.remainder(7, 2) == 1)
    }

    test("pow base case") {
      assert(Integer.pow(5, 0) == 1)
    }

    test("pow identity") {
      assert(Integer.pow(7, 1) == 7)
    }

    test("pow of 2") {
      assert(Integer.pow(2, 10) == 1024)
    }

    test("pow of 3") {
      assert(Integer.pow(3, 3) == 27)
    }

    test("clamp within range") {
      assert(Integer.clamp(5, 0, 10) == 5)
    }

    test("clamp below range") {
      assert(Integer.clamp(-5, 0, 10) == 0)
    }

    test("clamp above range") {
      assert(Integer.clamp(15, 0, 10) == 10)
    }

    test("clamp at lower bound") {
      assert(Integer.clamp(0, 0, 10) == 0)
    }

    test("clamp at upper bound") {
      assert(Integer.clamp(10, 0, 10) == 10)
    }

    test("digits single") {
      assert(Integer.digits(0) == 1)
    }

    test("digits two") {
      assert(Integer.digits(42) == 2)
    }

    test("digits negative") {
      assert(Integer.digits(-123) == 3)
    }

    test("digits large") {
      assert(Integer.digits(10000) == 5)
    }

    test("to_float positive") {
      assert(Integer.to_float(42) == 42.0)
    }

    test("to_float negative") {
      assert(Integer.to_float(-7) == -7.0)
    }

    test("to_float zero") {
      assert(Integer.to_float(0) == 0.0)
    }
  }
}
