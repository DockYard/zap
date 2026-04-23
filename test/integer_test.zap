pub struct Test.IntegerTest {
  use Zest.Case

  describe("Integer struct") {
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

    # Bit operations

    test("count_leading_zeros of 1") {
      assert(Integer.count_leading_zeros(1) == 63)
    }

    test("count_trailing_zeros of 8") {
      assert(Integer.count_trailing_zeros(8) == 3)
    }

    test("count_trailing_zeros of 1") {
      assert(Integer.count_trailing_zeros(1) == 0)
    }

    test("popcount of 7") {
      assert(Integer.popcount(7) == 3)
    }

    test("popcount of 0") {
      assert(Integer.popcount(0) == 0)
    }

    test("popcount of 255") {
      assert(Integer.popcount(255) == 8)
    }

    test("byte_swap round trip") {
      assert(Integer.byte_swap(Integer.byte_swap(42)) == 42)
    }

    test("bit_reverse round trip") {
      assert(Integer.bit_reverse(Integer.bit_reverse(42)) == 42)
    }

    # Saturating arithmetic

    test("add_sat normal") {
      assert(Integer.add_sat(3, 4) == 7)
    }

    test("sub_sat normal") {
      assert(Integer.sub_sat(10, 3) == 7)
    }

    test("mul_sat normal") {
      assert(Integer.mul_sat(3, 4) == 12)
    }

    # Bitwise operations

    test("band basic") {
      assert(Integer.band(7, 5) == 5)
    }

    test("band with zero") {
      assert(Integer.band(0, 42) == 0)
    }

    test("bor basic") {
      assert(Integer.bor(5, 3) == 7)
    }

    test("bor with zero") {
      assert(Integer.bor(0, 42) == 42)
    }

    test("bxor basic") {
      assert(Integer.bxor(7, 5) == 2)
    }

    test("bxor self is zero") {
      assert(Integer.bxor(255, 255) == 0)
    }

    test("bnot zero") {
      assert(Integer.bnot(0) == -1)
    }

    test("bnot negative one") {
      assert(Integer.bnot(-1) == 0)
    }

    test("bsl by 3") {
      assert(Integer.bsl(1, 3) == 8)
    }

    test("bsr by 3") {
      assert(Integer.bsr(8, 3) == 1)
    }

    # Predicates

    test("sign positive") {
      assert(Integer.sign(42) == 1)
    }

    test("sign zero") {
      assert(Integer.sign(0) == 0)
    }

    test("sign negative") {
      assert(Integer.sign(-7) == -1)
    }

    test("even? true") {
      assert(Integer.even?(4) == true)
    }

    test("even? false") {
      assert(Integer.even?(3) == false)
    }

    test("even? zero") {
      assert(Integer.even?(0) == true)
    }

    test("odd? true") {
      assert(Integer.odd?(3) == true)
    }

    test("odd? false") {
      assert(Integer.odd?(4) == false)
    }

    test("gcd basic") {
      assert(Integer.gcd(12, 8) == 4)
    }

    test("gcd coprime") {
      assert(Integer.gcd(7, 5) == 1)
    }

    test("gcd with larger") {
      assert(Integer.gcd(54, 24) == 6)
    }

    test("lcm basic") {
      assert(Integer.lcm(4, 6) == 12)
    }

    test("lcm coprime") {
      assert(Integer.lcm(3, 5) == 15)
    }

    test("lcm same") {
      assert(Integer.lcm(7, 7) == 7)
    }
  }
}
