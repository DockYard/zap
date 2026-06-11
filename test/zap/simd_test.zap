pub struct Zap.SimdTest {
  use Zest.Case

  describe("Simd") {
    test("vector validates every supported lane count") {
      assert(matches_i32_2(Simd.vector(2, i32, {1, 2}), 1, 2))
      assert(matches_i32_3(Simd.vector(3, i32, {1, 2, 3}), 1, 2, 3))
      assert(matches_i32_4(Simd.vector(4, i32, {1, 2, 3, 4}), 1, 2, 3, 4))
      assert(matches_i32_8(Simd.vector(8, i32, {1, 2, 3, 4, 5, 6, 7, 8}), 1, 2, 3, 4, 5, 6, 7, 8))
      assert(matches_i32_16(Simd.vector(16, i32, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
    }

    test("splat builds every supported lane count") {
      assert(matches_i32_2(Simd.splat(2, i32, 7), 7, 7))
      assert(matches_i32_3(Simd.splat(3, i32, 7), 7, 7, 7))
      assert(matches_i32_4(Simd.splat(4, i32, 7), 7, 7, 7, 7))
      assert(matches_i32_8(Simd.splat(8, i32, 7), 7, 7, 7, 7, 7, 7, 7, 7))
      assert(matches_i32_16(Simd.splat(16, i32, 7), 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7))
    }

    test("splat supports every scalar lane type") {
      i8_lanes = Simd.splat(2, i8, 7)
      i16_lanes = Simd.splat(2, i16, 7)
      i32_lanes = Simd.splat(2, i32, 7)
      i64_lanes = Simd.splat(2, i64, 7)
      i128_lanes = Simd.splat(2, i128, 7)
      u8_lanes = Simd.splat(2, u8, 7)
      u16_lanes = Simd.splat(2, u16, 7)
      u32_lanes = Simd.splat(2, u32, 7)
      u64_lanes = Simd.splat(2, u64, 7)
      u128_lanes = Simd.splat(2, u128, 7)
      usize_lanes = Simd.splat(2, usize, 7)
      isize_lanes = Simd.splat(2, isize, 7)
      f16_lanes = Simd.splat(2, f16, 1.5)
      f32_lanes = Simd.splat(2, f32, 1.5)
      f64_lanes = Simd.splat(2, f64, 1.5)

      assert(i8_lanes.0 == (7 :: i8))
      assert(i8_lanes.1 == (7 :: i8))
      assert(i16_lanes.0 == (7 :: i16))
      assert(i16_lanes.1 == (7 :: i16))
      assert(i32_lanes.0 == (7 :: i32))
      assert(i32_lanes.1 == (7 :: i32))
      assert(i64_lanes.0 == (7 :: i64))
      assert(i64_lanes.1 == (7 :: i64))
      assert(i128_lanes.0 == (7 :: i128))
      assert(i128_lanes.1 == (7 :: i128))
      assert(u8_lanes.0 == (7 :: u8))
      assert(u8_lanes.1 == (7 :: u8))
      assert(u16_lanes.0 == (7 :: u16))
      assert(u16_lanes.1 == (7 :: u16))
      assert(u32_lanes.0 == (7 :: u32))
      assert(u32_lanes.1 == (7 :: u32))
      assert(u64_lanes.0 == (7 :: u64))
      assert(u64_lanes.1 == (7 :: u64))
      assert(u128_lanes.0 == (7 :: u128))
      assert(u128_lanes.1 == (7 :: u128))
      assert(usize_lanes.0 == (7 :: usize))
      assert(usize_lanes.1 == (7 :: usize))
      assert(isize_lanes.0 == (7 :: isize))
      assert(isize_lanes.1 == (7 :: isize))
      assert(f16_lanes.0 == (1.5 :: f16))
      assert(f16_lanes.1 == (1.5 :: f16))
      assert(f32_lanes.0 == (1.5 :: f32))
      assert(f32_lanes.1 == (1.5 :: f32))
      assert(f64_lanes.0 == (1.5 :: f64))
      assert(f64_lanes.1 == (1.5 :: f64))
    }

    test("add supports every lane-count overload") {
      assert(matches_i32_2(Simd.add({1, 2} :: {i32, i32}, {10, 20} :: {i32, i32}), 11, 22))
      assert(matches_i32_3(Simd.add({1, 2, 3} :: {i32, i32, i32}, {10, 20, 30} :: {i32, i32, i32}), 11, 22, 33))
      assert(matches_i32_4(Simd.add({1, 2, 3, 4} :: {i32, i32, i32, i32}, {10, 20, 30, 40} :: {i32, i32, i32, i32}), 11, 22, 33, 44))
      assert(matches_i32_8(Simd.add({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {10, 20, 30, 40, 50, 60, 70, 80} :: {i32, i32, i32, i32, i32, i32, i32, i32}), 11, 22, 33, 44, 55, 66, 77, 88))
      assert(matches_i32_16(Simd.add({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), 11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132, 143, 154, 165, 176))
    }

    test("sub supports every lane-count overload") {
      assert(matches_i32_2(Simd.sub({11, 22} :: {i32, i32}, {1, 2} :: {i32, i32}), 10, 20))
      assert(matches_i32_3(Simd.sub({11, 22, 33} :: {i32, i32, i32}, {1, 2, 3} :: {i32, i32, i32}), 10, 20, 30))
      assert(matches_i32_4(Simd.sub({11, 22, 33, 44} :: {i32, i32, i32, i32}, {1, 2, 3, 4} :: {i32, i32, i32, i32}), 10, 20, 30, 40))
      assert(matches_i32_8(Simd.sub({11, 22, 33, 44, 55, 66, 77, 88} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}), 10, 20, 30, 40, 50, 60, 70, 80))
      assert(matches_i32_16(Simd.sub({11, 22, 33, 44, 55, 66, 77, 88, 99, 110, 121, 132, 143, 154, 165, 176} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160))
    }

    test("mul supports every lane-count overload") {
      assert(matches_i32_2(Simd.mul({1, 2} :: {i32, i32}, {10, 20} :: {i32, i32}), 10, 40))
      assert(matches_i32_3(Simd.mul({1, 2, 3} :: {i32, i32, i32}, {10, 20, 30} :: {i32, i32, i32}), 10, 40, 90))
      assert(matches_i32_4(Simd.mul({1, 2, 3, 4} :: {i32, i32, i32, i32}, {10, 20, 30, 40} :: {i32, i32, i32, i32}), 10, 40, 90, 160))
      assert(matches_i32_8(Simd.mul({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {10, 20, 30, 40, 50, 60, 70, 80} :: {i32, i32, i32, i32, i32, i32, i32, i32}), 10, 40, 90, 160, 250, 360, 490, 640))
      assert(matches_i32_16(Simd.mul({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), 10, 40, 90, 160, 250, 360, 490, 640, 810, 1000, 1210, 1440, 1690, 1960, 2250, 2560))
    }

    test("eq supports every lane-count overload") {
      assert(matches_bool_2(Simd.eq({1, 2} :: {i32, i32}, {1, 9} :: {i32, i32}), true, false))
      assert(matches_bool_3(Simd.eq({1, 2, 3} :: {i32, i32, i32}, {1, 9, 3} :: {i32, i32, i32}), true, false, true))
      assert(matches_bool_4(Simd.eq({1, 2, 3, 4} :: {i32, i32, i32, i32}, {1, 9, 3, 9} :: {i32, i32, i32, i32}), true, false, true, false))
      assert(matches_bool_8(Simd.eq({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {1, 9, 3, 9, 5, 9, 7, 9} :: {i32, i32, i32, i32, i32, i32, i32, i32}), true, false, true, false, true, false, true, false))
      assert(matches_bool_16(Simd.eq({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {1, 99, 3, 99, 5, 99, 7, 99, 9, 99, 11, 99, 13, 99, 15, 99} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false))
    }

    test("ne supports every lane-count overload") {
      assert(matches_bool_2(Simd.ne({1, 2} :: {i32, i32}, {1, 9} :: {i32, i32}), false, true))
      assert(matches_bool_3(Simd.ne({1, 2, 3} :: {i32, i32, i32}, {1, 9, 3} :: {i32, i32, i32}), false, true, false))
      assert(matches_bool_4(Simd.ne({1, 2, 3, 4} :: {i32, i32, i32, i32}, {1, 9, 3, 9} :: {i32, i32, i32, i32}), false, true, false, true))
      assert(matches_bool_8(Simd.ne({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {1, 9, 3, 9, 5, 9, 7, 9} :: {i32, i32, i32, i32, i32, i32, i32, i32}), false, true, false, true, false, true, false, true))
      assert(matches_bool_16(Simd.ne({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {1, 99, 3, 99, 5, 99, 7, 99, 9, 99, 11, 99, 13, 99, 15, 99} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), false, true, false, true, false, true, false, true, false, true, false, true, false, true, false, true))
    }

    test("lt supports every lane-count overload") {
      assert(matches_bool_2(Simd.lt({1, 2} :: {i32, i32}, {2, 2} :: {i32, i32}), true, false))
      assert(matches_bool_3(Simd.lt({1, 2, 3} :: {i32, i32, i32}, {2, 2, 2} :: {i32, i32, i32}), true, false, false))
      assert(matches_bool_4(Simd.lt({1, 2, 3, 4} :: {i32, i32, i32, i32}, {2, 2, 2, 5} :: {i32, i32, i32, i32}), true, false, false, true))
      assert(matches_bool_8(Simd.lt({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {2, 2, 2, 5, 5, 5, 8, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}), true, false, false, true, false, false, true, false))
      assert(matches_bool_16(Simd.lt({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {2, 2, 2, 5, 5, 5, 8, 8, 8, 11, 11, 11, 14, 14, 14, 17} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true))
    }

    test("lte supports every lane-count overload") {
      assert(matches_bool_2(Simd.lte({1, 2} :: {i32, i32}, {2, 2} :: {i32, i32}), true, true))
      assert(matches_bool_3(Simd.lte({1, 2, 3} :: {i32, i32, i32}, {2, 2, 2} :: {i32, i32, i32}), true, true, false))
      assert(matches_bool_4(Simd.lte({1, 2, 3, 4} :: {i32, i32, i32, i32}, {2, 2, 2, 5} :: {i32, i32, i32, i32}), true, true, false, true))
      assert(matches_bool_8(Simd.lte({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {2, 2, 2, 5, 5, 5, 8, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}), true, true, false, true, true, false, true, true))
      assert(matches_bool_16(Simd.lte({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {2, 2, 2, 5, 5, 5, 8, 8, 8, 11, 11, 11, 14, 14, 14, 17} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), true, true, false, true, true, false, true, true, false, true, true, false, true, true, false, true))
    }

    test("gt supports every lane-count overload") {
      assert(matches_bool_2(Simd.gt({1, 2} :: {i32, i32}, {0, 2} :: {i32, i32}), true, false))
      assert(matches_bool_3(Simd.gt({1, 2, 3} :: {i32, i32, i32}, {0, 2, 4} :: {i32, i32, i32}), true, false, false))
      assert(matches_bool_4(Simd.gt({1, 2, 3, 4} :: {i32, i32, i32, i32}, {0, 2, 4, 3} :: {i32, i32, i32, i32}), true, false, false, true))
      assert(matches_bool_8(Simd.gt({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {0, 2, 4, 3, 5, 7, 6, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}), true, false, false, true, false, false, true, false))
      assert(matches_bool_16(Simd.gt({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {0, 2, 4, 3, 5, 7, 6, 8, 10, 9, 11, 13, 12, 14, 16, 15} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), true, false, false, true, false, false, true, false, false, true, false, false, true, false, false, true))
    }

    test("gte supports every lane-count overload") {
      assert(matches_bool_2(Simd.gte({1, 2} :: {i32, i32}, {0, 2} :: {i32, i32}), true, true))
      assert(matches_bool_3(Simd.gte({1, 2, 3} :: {i32, i32, i32}, {0, 2, 4} :: {i32, i32, i32}), true, true, false))
      assert(matches_bool_4(Simd.gte({1, 2, 3, 4} :: {i32, i32, i32, i32}, {0, 2, 4, 3} :: {i32, i32, i32, i32}), true, true, false, true))
      assert(matches_bool_8(Simd.gte({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {0, 2, 4, 3, 5, 7, 6, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}), true, true, false, true, true, false, true, true))
      assert(matches_bool_16(Simd.gte({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {0, 2, 4, 3, 5, 7, 6, 8, 10, 9, 11, 13, 12, 14, 16, 15} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), true, true, false, true, true, false, true, true, false, true, true, false, true, true, false, true))
    }

    test("select supports every lane-count overload") {
      assert(matches_i32_2(Simd.select({true, false}, {1, 2} :: {i32, i32}, {10, 20} :: {i32, i32}), 1, 20))
      assert(matches_i32_3(Simd.select({true, false, true}, {1, 2, 3} :: {i32, i32, i32}, {10, 20, 30} :: {i32, i32, i32}), 1, 20, 3))
      assert(matches_i32_4(Simd.select({true, false, true, false}, {1, 2, 3, 4} :: {i32, i32, i32, i32}, {10, 20, 30, 40} :: {i32, i32, i32, i32}), 1, 20, 3, 40))
      assert(matches_i32_8(Simd.select({true, false, true, false, true, false, true, false}, {1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}, {10, 20, 30, 40, 50, 60, 70, 80} :: {i32, i32, i32, i32, i32, i32, i32, i32}), 1, 20, 3, 40, 5, 60, 7, 80))
      assert(matches_i32_16(Simd.select({true, false, true, false, true, false, true, false, true, false, true, false, true, false, true, false}, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, {10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}), 1, 20, 3, 40, 5, 60, 7, 80, 9, 100, 11, 120, 13, 140, 15, 160))
    }

    test("reduce macro delegates add min and max operations") {
      values = Simd.vector(4, i32, {4, -2, 9, 1})

      assert(Simd.reduce(:add, values) == 12)
      assert(Simd.reduce(:min, values) == -2)
      assert(Simd.reduce(:max, values) == 9)
    }

    test("direct reduce_add supports every lane-count overload") {
      assert(Simd.reduce_add({1, 2} :: {i32, i32}) == 3)
      assert(Simd.reduce_add({1, 2, 3} :: {i32, i32, i32}) == 6)
      assert(Simd.reduce_add({1, 2, 3, 4} :: {i32, i32, i32, i32}) == 10)
      assert(Simd.reduce_add({1, 2, 3, 4, 5, 6, 7, 8} :: {i32, i32, i32, i32, i32, i32, i32, i32}) == 36)
      assert(Simd.reduce_add({1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}) == 136)
    }

    test("direct reduce_min supports every lane-count overload") {
      assert(Simd.reduce_min({1, -2} :: {i32, i32}) == -2)
      assert(Simd.reduce_min({1, -2, 3} :: {i32, i32, i32}) == -2)
      assert(Simd.reduce_min({1, -2, 3, -4} :: {i32, i32, i32, i32}) == -4)
      assert(Simd.reduce_min({1, -2, 3, -4, 5, -6, 7, -8} :: {i32, i32, i32, i32, i32, i32, i32, i32}) == -8)
      assert(Simd.reduce_min({1, -2, 3, -4, 5, -6, 7, -8, 9, -10, 11, -12, 13, -14, 15, -16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}) == -16)
    }

    test("direct reduce_max supports every lane-count overload") {
      assert(Simd.reduce_max({1, -2} :: {i32, i32}) == 1)
      assert(Simd.reduce_max({1, -2, 3} :: {i32, i32, i32}) == 3)
      assert(Simd.reduce_max({1, -2, 3, -4} :: {i32, i32, i32, i32}) == 3)
      assert(Simd.reduce_max({1, -2, 3, -4, 5, -6, 7, -8} :: {i32, i32, i32, i32, i32, i32, i32, i32}) == 7)
      assert(Simd.reduce_max({1, -2, 3, -4, 5, -6, 7, -8, 9, -10, 11, -12, 13, -14, 15, -16} :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}) == 15)
    }

    test("f32 lanes compose arithmetic comparisons selections and reductions") {
      values = Simd.vector(4, f32, {1.0, 2.0, 3.0, 4.0})
      halves = Simd.splat(4, f32, 0.5)
      scaled = Simd.mul(values, halves)
      mask = Simd.gte(scaled, Simd.splat(4, f32, 1.0))
      selected = Simd.select(mask, scaled, Simd.splat(4, f32, 0.0))

      assert(matches_f32_4(scaled, 0.5, 1.0, 1.5, 2.0))
      assert(matches_bool_4(mask, false, true, true, true))
      assert(Simd.reduce(:add, selected) == (4.5 :: f32))
      assert(Simd.reduce(:min, scaled) == (0.5 :: f32))
      assert(Simd.reduce(:max, scaled) == (2.0 :: f32))
    }
  }

  fn matches_i32_2(actual :: {i32, i32}, expected_0 :: i32, expected_1 :: i32) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1
  }

  fn matches_i32_3(actual :: {i32, i32, i32}, expected_0 :: i32, expected_1 :: i32, expected_2 :: i32) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2
  }

  fn matches_i32_4(actual :: {i32, i32, i32, i32}, expected_0 :: i32, expected_1 :: i32, expected_2 :: i32, expected_3 :: i32) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3
  }

  fn matches_i32_8(actual :: {i32, i32, i32, i32, i32, i32, i32, i32}, expected_0 :: i32, expected_1 :: i32, expected_2 :: i32, expected_3 :: i32, expected_4 :: i32, expected_5 :: i32, expected_6 :: i32, expected_7 :: i32) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3 and actual.4 == expected_4 and actual.5 == expected_5 and actual.6 == expected_6 and actual.7 == expected_7
  }

  fn matches_i32_16(actual :: {i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32}, expected_0 :: i32, expected_1 :: i32, expected_2 :: i32, expected_3 :: i32, expected_4 :: i32, expected_5 :: i32, expected_6 :: i32, expected_7 :: i32, expected_8 :: i32, expected_9 :: i32, expected_10 :: i32, expected_11 :: i32, expected_12 :: i32, expected_13 :: i32, expected_14 :: i32, expected_15 :: i32) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3 and actual.4 == expected_4 and actual.5 == expected_5 and actual.6 == expected_6 and actual.7 == expected_7 and actual.8 == expected_8 and actual.9 == expected_9 and actual.10 == expected_10 and actual.11 == expected_11 and actual.12 == expected_12 and actual.13 == expected_13 and actual.14 == expected_14 and actual.15 == expected_15
  }

  fn matches_bool_2(actual :: {Bool, Bool}, expected_0 :: Bool, expected_1 :: Bool) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1
  }

  fn matches_bool_3(actual :: {Bool, Bool, Bool}, expected_0 :: Bool, expected_1 :: Bool, expected_2 :: Bool) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2
  }

  fn matches_bool_4(actual :: {Bool, Bool, Bool, Bool}, expected_0 :: Bool, expected_1 :: Bool, expected_2 :: Bool, expected_3 :: Bool) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3
  }

  fn matches_bool_8(actual :: {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool}, expected_0 :: Bool, expected_1 :: Bool, expected_2 :: Bool, expected_3 :: Bool, expected_4 :: Bool, expected_5 :: Bool, expected_6 :: Bool, expected_7 :: Bool) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3 and actual.4 == expected_4 and actual.5 == expected_5 and actual.6 == expected_6 and actual.7 == expected_7
  }

  fn matches_bool_16(actual :: {Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool, Bool}, expected_0 :: Bool, expected_1 :: Bool, expected_2 :: Bool, expected_3 :: Bool, expected_4 :: Bool, expected_5 :: Bool, expected_6 :: Bool, expected_7 :: Bool, expected_8 :: Bool, expected_9 :: Bool, expected_10 :: Bool, expected_11 :: Bool, expected_12 :: Bool, expected_13 :: Bool, expected_14 :: Bool, expected_15 :: Bool) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3 and actual.4 == expected_4 and actual.5 == expected_5 and actual.6 == expected_6 and actual.7 == expected_7 and actual.8 == expected_8 and actual.9 == expected_9 and actual.10 == expected_10 and actual.11 == expected_11 and actual.12 == expected_12 and actual.13 == expected_13 and actual.14 == expected_14 and actual.15 == expected_15
  }

  fn matches_f32_4(actual :: {f32, f32, f32, f32}, expected_0 :: f32, expected_1 :: f32, expected_2 :: f32, expected_3 :: f32) -> Bool {
    actual.0 == expected_0 and actual.1 == expected_1 and actual.2 == expected_2 and actual.3 == expected_3
  }
}
