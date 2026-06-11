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

    # Composed float-to-integer conversions. The compound forms
    # (`Float.floor_to_integer/1`, `_ceil_to_integer/1`,
    # `_round_to_integer/1`) were removed once `Float.to_integer/1`
    # gained its NaN / ±∞ / range-overflow panic contract — every
    # rounding policy now decomposes cleanly through the pipe.

    test("floor then to_integer positive") {
      assert(Float.floor(3.7) |> Float.to_integer() == 3)
    }

    test("floor then to_integer negative") {
      assert(Float.floor(-2.3) |> Float.to_integer() == -3)
    }

    test("floor then to_integer exact") {
      assert(Float.floor(5.0) |> Float.to_integer() == 5)
    }

    test("ceil then to_integer positive") {
      assert(Float.ceil(3.2) |> Float.to_integer() == 4)
    }

    test("ceil then to_integer negative") {
      assert(Float.ceil(-2.7) |> Float.to_integer() == -2)
    }

    test("ceil then to_integer exact") {
      assert(Float.ceil(5.0) |> Float.to_integer() == 5)
    }

    test("round then to_integer down") {
      assert(Float.round(3.2) |> Float.to_integer() == 3)
    }

    test("round then to_integer up") {
      assert(Float.round(3.7) |> Float.to_integer() == 4)
    }

    test("helper overloads preserve exact f32 and f64 widths") {
      assert(accept_f32(Float.abs(-1.5 :: f32)) == "f32")
      assert(accept_f64(Float.abs(-2.5)) == "f64")
    }

    test("f80 and f128 helpers preserve extended widths") {
      assert(accept_f80(Float.abs(-1.5 :: f80)) == "f80")
      assert(accept_f128(Float.max(1.0 :: f128, 2.0 :: f128)) == "f128")
      assert(accept_f80(Float.min(3.0 :: f80, 2.0 :: f80)) == "f80")
      assert(accept_f128(Float.round(1.5 :: f128)) == "f128")
      assert(accept_f80(Float.floor(1.9 :: f80)) == "f80")
      assert(accept_f128(Float.ceil(1.1 :: f128)) == "f128")
      assert(accept_f80((1.5 :: f80) + (2.5 :: f80)) == "f80")
      assert(accept_f128((5.0 :: f128) - (2.0 :: f128)) == "f128")
      assert(accept_f80((2.0 :: f80) * (3.0 :: f80)) == "f80")
      assert(accept_f128((6.0 :: f128) / (2.0 :: f128)) == "f128")
      assert(accept_f80((5.5 :: f80) rem (2.0 :: f80)) == "f80")
      assert(accept_f128(Float.clamp(5.0 :: f128, 1.0 :: f128, 3.0 :: f128)) == "f128")
      assert(accept_f128(Float.truncate(3.75 :: f128)) == "f128")
    }

    test("f80 and f128 helpers produce scalar conversion values") {
      assert(Float.to_integer(3.75 :: f80) == 3)
      assert(Float.to_integer(Float.floor(3.75 :: f128)) == 3)
      assert(Float.to_integer(Float.ceil(3.25 :: f80)) == 4)
      assert(Float.to_integer(Float.round(3.75 :: f128)) == 4)
      assert(accept_string(Float.to_string(1.5 :: f80)) == "String")
      assert(accept_string(Float.to_string(2.5 :: f128)) == "String")
      assert((1.0 :: f80) < (2.0 :: f80))
      assert((2.0 :: f128) >= (2.0 :: f128))
    }
  }

  fn accept_f32(value :: f32) -> String {
    "f32"
  }

  fn accept_f64(value :: f64) -> String {
    "f64"
  }

  fn accept_f80(value :: f80) -> String {
    "f80"
  }

  fn accept_f128(value :: f128) -> String {
    "f128"
  }

  fn accept_string(value :: String) -> String {
    "String"
  }
}
