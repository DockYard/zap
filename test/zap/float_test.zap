pub struct Zap.FloatTest {
  use Zest.Case

  describe("Float struct") {
    test("to_string positive") {
      assert(Float.to_string(3.14) == "3.14")
    }

    test("to_string negative") {
      assert(Float.to_string(-0.5) == "-0.5")
    }

    test("abs positive") {
      assert(Float.abs(3.14) == 3.14)
    }

    test("abs negative") {
      assert(Float.abs(-3.14) == 3.14)
    }

    test("abs zero") {
      assert(Float.abs(0.0) == 0.0)
    }

    test("max returns larger") {
      assert(Float.max(3.0, 7.0) == 7.0)
    }

    test("max returns first when larger") {
      assert(Float.max(10.5, 2.3) == 10.5)
    }

    test("min returns smaller") {
      assert(Float.min(3.0, 7.0) == 3.0)
    }

    test("min returns first when smaller") {
      assert(Float.min(2.3, 10.5) == 2.3)
    }

    test("parse valid") {
      assert(Float.parse("3.14") == 3.14)
    }

    test("parse negative") {
      assert(Float.parse("-0.5") == -0.5)
    }

    test("parse invalid") {
      assert(Float.parse("hello") == 0.0)
    }

    test("round down") {
      assert(Float.round(3.2) == 3.0)
    }

    test("round up") {
      assert(Float.round(3.7) == 4.0)
    }

    test("floor positive") {
      assert(Float.floor(3.7) == 3.0)
    }

    test("floor negative") {
      assert(Float.floor(-2.3) == -3.0)
    }

    test("floor exact") {
      assert(Float.floor(3.0) == 3.0)
    }

    test("ceil positive") {
      assert(Float.ceil(3.2) == 4.0)
    }

    test("ceil negative") {
      assert(Float.ceil(-2.7) == -2.0)
    }

    test("ceil exact") {
      assert(Float.ceil(3.0) == 3.0)
    }

    test("truncate positive") {
      assert(Float.truncate(3.7) == 3.0)
    }

    test("truncate negative") {
      assert(Float.truncate(-2.9) == -2.0)
    }

    test("truncate exact") {
      assert(Float.truncate(5.0) == 5.0)
    }

    test("to_integer positive") {
      assert(Float.to_integer(3.7) == 3)
    }

    test("to_integer negative") {
      assert(Float.to_integer(-2.9) == -2)
    }

    test("to_integer exact") {
      assert(Float.to_integer(5.0) == 5)
    }

    test("clamp within range") {
      assert(Float.clamp(5.0, 0.0, 10.0) == 5.0)
    }

    test("clamp below range") {
      assert(Float.clamp(-5.0, 0.0, 10.0) == 0.0)
    }

    test("clamp above range") {
      assert(Float.clamp(15.0, 0.0, 10.0) == 10.0)
    }

    # Direct float-to-integer conversions (Zig 0.16)

    test("floor_to_integer positive") {
      assert(Float.floor_to_integer(3.7) == 3)
    }

    test("floor_to_integer negative") {
      assert(Float.floor_to_integer(-2.3) == -3)
    }

    test("floor_to_integer exact") {
      assert(Float.floor_to_integer(5.0) == 5)
    }

    test("ceil_to_integer positive") {
      assert(Float.ceil_to_integer(3.2) == 4)
    }

    test("ceil_to_integer negative") {
      assert(Float.ceil_to_integer(-2.7) == -2)
    }

    test("ceil_to_integer exact") {
      assert(Float.ceil_to_integer(5.0) == 5)
    }

    test("round_to_integer down") {
      assert(Float.round_to_integer(3.2) == 3)
    }

    test("round_to_integer up") {
      assert(Float.round_to_integer(3.7) == 4)
    }
  }
}
