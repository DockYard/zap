pub struct Zap.MathTest {
  use Zest.Case

  describe("Math struct") {
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

    test("sqrt preserves exact float type") {
      assert(float_type(Math.sqrt(9.0 :: f16)) == "f16")
      assert(float_type(Math.sqrt(9.0 :: f32)) == "f32")
      assert(float_type(Math.sqrt(9.0 :: f64)) == "f64")
      assert(float_type(Math.sqrt(9.0 :: f80)) == "f80")
      assert(float_type(Math.sqrt(9.0 :: f128)) == "f128")
    }

    test("sqrt accepts exact integer input types") {
      assert(float_type(Math.sqrt(9 :: i8)) == "f64")
      assert(float_type(Math.sqrt(9 :: i16)) == "f64")
      assert(float_type(Math.sqrt(9 :: i32)) == "f64")
      assert(float_type(Math.sqrt(9 :: i64)) == "f64")
      assert(float_type(Math.sqrt(9 :: i128)) == "f128")
      assert(float_type(Math.sqrt(9 :: u8)) == "f64")
      assert(float_type(Math.sqrt(9 :: u16)) == "f64")
      assert(float_type(Math.sqrt(9 :: u32)) == "f64")
      assert(float_type(Math.sqrt(9 :: u64)) == "f64")
      assert(float_type(Math.sqrt(9 :: u128)) == "f128")
    }

    test("sin preserves exact float type") {
      assert(float_type(Math.sin(0.0 :: f16)) == "f16")
      assert(float_type(Math.sin(0.0 :: f32)) == "f32")
      assert(float_type(Math.sin(0.0 :: f64)) == "f64")
      assert(float_type(Math.sin(0.0 :: f80)) == "f80")
      assert(float_type(Math.sin(0.0 :: f128)) == "f128")
    }

    test("sin accepts exact integer input types") {
      assert(float_type(Math.sin(0 :: i8)) == "f64")
      assert(float_type(Math.sin(0 :: i16)) == "f64")
      assert(float_type(Math.sin(0 :: i32)) == "f64")
      assert(float_type(Math.sin(0 :: i64)) == "f64")
      assert(float_type(Math.sin(0 :: i128)) == "f128")
      assert(float_type(Math.sin(0 :: u8)) == "f64")
      assert(float_type(Math.sin(0 :: u16)) == "f64")
      assert(float_type(Math.sin(0 :: u32)) == "f64")
      assert(float_type(Math.sin(0 :: u64)) == "f64")
      assert(float_type(Math.sin(0 :: u128)) == "f128")
    }

    test("cos preserves exact float type") {
      assert(float_type(Math.cos(0.0 :: f16)) == "f16")
      assert(float_type(Math.cos(0.0 :: f32)) == "f32")
      assert(float_type(Math.cos(0.0 :: f64)) == "f64")
      assert(float_type(Math.cos(0.0 :: f80)) == "f80")
      assert(float_type(Math.cos(0.0 :: f128)) == "f128")
    }

    test("cos accepts exact integer input types") {
      assert(float_type(Math.cos(0 :: i8)) == "f64")
      assert(float_type(Math.cos(0 :: i16)) == "f64")
      assert(float_type(Math.cos(0 :: i32)) == "f64")
      assert(float_type(Math.cos(0 :: i64)) == "f64")
      assert(float_type(Math.cos(0 :: i128)) == "f128")
      assert(float_type(Math.cos(0 :: u8)) == "f64")
      assert(float_type(Math.cos(0 :: u16)) == "f64")
      assert(float_type(Math.cos(0 :: u32)) == "f64")
      assert(float_type(Math.cos(0 :: u64)) == "f64")
      assert(float_type(Math.cos(0 :: u128)) == "f128")
    }

    test("tan preserves exact float type") {
      assert(float_type(Math.tan(0.0 :: f16)) == "f16")
      assert(float_type(Math.tan(0.0 :: f32)) == "f32")
      assert(float_type(Math.tan(0.0 :: f64)) == "f64")
      assert(float_type(Math.tan(0.0 :: f80)) == "f80")
      assert(float_type(Math.tan(0.0 :: f128)) == "f128")
    }

    test("tan accepts exact integer input types") {
      assert(float_type(Math.tan(0 :: i8)) == "f64")
      assert(float_type(Math.tan(0 :: i16)) == "f64")
      assert(float_type(Math.tan(0 :: i32)) == "f64")
      assert(float_type(Math.tan(0 :: i64)) == "f64")
      assert(float_type(Math.tan(0 :: i128)) == "f128")
      assert(float_type(Math.tan(0 :: u8)) == "f64")
      assert(float_type(Math.tan(0 :: u16)) == "f64")
      assert(float_type(Math.tan(0 :: u32)) == "f64")
      assert(float_type(Math.tan(0 :: u64)) == "f64")
      assert(float_type(Math.tan(0 :: u128)) == "f128")
    }

    test("exp preserves exact float type") {
      assert(float_type(Math.exp(0.0 :: f16)) == "f16")
      assert(float_type(Math.exp(0.0 :: f32)) == "f32")
      assert(float_type(Math.exp(0.0 :: f64)) == "f64")
      assert(float_type(Math.exp(0.0 :: f80)) == "f80")
      assert(float_type(Math.exp(0.0 :: f128)) == "f128")
    }

    test("exp accepts exact integer input types") {
      assert(float_type(Math.exp(0 :: i8)) == "f64")
      assert(float_type(Math.exp(0 :: i16)) == "f64")
      assert(float_type(Math.exp(0 :: i32)) == "f64")
      assert(float_type(Math.exp(0 :: i64)) == "f64")
      assert(float_type(Math.exp(0 :: i128)) == "f128")
      assert(float_type(Math.exp(0 :: u8)) == "f64")
      assert(float_type(Math.exp(0 :: u16)) == "f64")
      assert(float_type(Math.exp(0 :: u32)) == "f64")
      assert(float_type(Math.exp(0 :: u64)) == "f64")
      assert(float_type(Math.exp(0 :: u128)) == "f128")
    }

    test("exp2 preserves exact float type") {
      assert(float_type(Math.exp2(3.0 :: f16)) == "f16")
      assert(float_type(Math.exp2(3.0 :: f32)) == "f32")
      assert(float_type(Math.exp2(3.0 :: f64)) == "f64")
      assert(float_type(Math.exp2(3.0 :: f80)) == "f80")
      assert(float_type(Math.exp2(3.0 :: f128)) == "f128")
    }

    test("exp2 accepts exact integer input types") {
      assert(float_type(Math.exp2(3 :: i8)) == "f64")
      assert(float_type(Math.exp2(3 :: i16)) == "f64")
      assert(float_type(Math.exp2(3 :: i32)) == "f64")
      assert(float_type(Math.exp2(3 :: i64)) == "f64")
      assert(float_type(Math.exp2(3 :: i128)) == "f128")
      assert(float_type(Math.exp2(3 :: u8)) == "f64")
      assert(float_type(Math.exp2(3 :: u16)) == "f64")
      assert(float_type(Math.exp2(3 :: u32)) == "f64")
      assert(float_type(Math.exp2(3 :: u64)) == "f64")
      assert(float_type(Math.exp2(3 :: u128)) == "f128")
    }

    test("log preserves exact float type") {
      assert(float_type(Math.log(1.0 :: f16)) == "f16")
      assert(float_type(Math.log(1.0 :: f32)) == "f32")
      assert(float_type(Math.log(1.0 :: f64)) == "f64")
      assert(float_type(Math.log(1.0 :: f80)) == "f80")
      assert(float_type(Math.log(1.0 :: f128)) == "f128")
    }

    test("log accepts exact integer input types") {
      assert(float_type(Math.log(1 :: i8)) == "f64")
      assert(float_type(Math.log(1 :: i16)) == "f64")
      assert(float_type(Math.log(1 :: i32)) == "f64")
      assert(float_type(Math.log(1 :: i64)) == "f64")
      assert(float_type(Math.log(1 :: i128)) == "f128")
      assert(float_type(Math.log(1 :: u8)) == "f64")
      assert(float_type(Math.log(1 :: u16)) == "f64")
      assert(float_type(Math.log(1 :: u32)) == "f64")
      assert(float_type(Math.log(1 :: u64)) == "f64")
      assert(float_type(Math.log(1 :: u128)) == "f128")
    }

    test("log2 preserves exact float type") {
      assert(float_type(Math.log2(1.0 :: f16)) == "f16")
      assert(float_type(Math.log2(1.0 :: f32)) == "f32")
      assert(float_type(Math.log2(1.0 :: f64)) == "f64")
      assert(float_type(Math.log2(1.0 :: f80)) == "f80")
      assert(float_type(Math.log2(1.0 :: f128)) == "f128")
    }

    test("log2 accepts exact integer input types") {
      assert(float_type(Math.log2(1 :: i8)) == "f64")
      assert(float_type(Math.log2(1 :: i16)) == "f64")
      assert(float_type(Math.log2(1 :: i32)) == "f64")
      assert(float_type(Math.log2(1 :: i64)) == "f64")
      assert(float_type(Math.log2(1 :: i128)) == "f128")
      assert(float_type(Math.log2(1 :: u8)) == "f64")
      assert(float_type(Math.log2(1 :: u16)) == "f64")
      assert(float_type(Math.log2(1 :: u32)) == "f64")
      assert(float_type(Math.log2(1 :: u64)) == "f64")
      assert(float_type(Math.log2(1 :: u128)) == "f128")
    }

    test("log10 preserves exact float type") {
      assert(float_type(Math.log10(1.0 :: f16)) == "f16")
      assert(float_type(Math.log10(1.0 :: f32)) == "f32")
      assert(float_type(Math.log10(1.0 :: f64)) == "f64")
      assert(float_type(Math.log10(1.0 :: f80)) == "f80")
      assert(float_type(Math.log10(1.0 :: f128)) == "f128")
    }

    test("log10 accepts exact integer input types") {
      assert(float_type(Math.log10(1 :: i8)) == "f64")
      assert(float_type(Math.log10(1 :: i16)) == "f64")
      assert(float_type(Math.log10(1 :: i32)) == "f64")
      assert(float_type(Math.log10(1 :: i64)) == "f64")
      assert(float_type(Math.log10(1 :: i128)) == "f128")
      assert(float_type(Math.log10(1 :: u8)) == "f64")
      assert(float_type(Math.log10(1 :: u16)) == "f64")
      assert(float_type(Math.log10(1 :: u32)) == "f64")
      assert(float_type(Math.log10(1 :: u64)) == "f64")
      assert(float_type(Math.log10(1 :: u128)) == "f128")
    }
  }

  fn float_type(_value :: f16) -> String { "f16" }
  fn float_type(_value :: f32) -> String { "f32" }
  fn float_type(_value :: f64) -> String { "f64" }
  fn float_type(_value :: f80) -> String { "f80" }
  fn float_type(_value :: f128) -> String { "f128" }
}
