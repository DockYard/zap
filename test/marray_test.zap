pub struct MArrayTest {
  use Zest.Case

  describe("MArrayI64") {
    test("new fills every slot with the init value") {
      arr = MArrayI64.new(4, 7 :: i64)
      assert(MArrayI64.length(arr) == 4)
      assert(MArrayI64.get(arr, 0) == 7)
      assert(MArrayI64.get(arr, 1) == 7)
      assert(MArrayI64.get(arr, 2) == 7)
      assert(MArrayI64.get(arr, 3) == 7)
    }

    test("set returns the written value and persists it") {
      arr = MArrayI64.new(3, 0 :: i64)
      written = MArrayI64.set(arr, 1, 42 :: i64)
      assert(written == 42)
      assert(MArrayI64.get(arr, 1) == 42)
    }

    test("multiple sets accumulate via get-sum") {
      arr = MArrayI64.new(5, 0 :: i64)
      _ = MArrayI64.set(arr, 0, 10 :: i64)
      _ = MArrayI64.set(arr, 1, 20 :: i64)
      _ = MArrayI64.set(arr, 2, 30 :: i64)
      total = MArrayI64.get(arr, 0) + MArrayI64.get(arr, 1) + MArrayI64.get(arr, 2)
      assert(total == 60)
    }

    test("length reflects allocated size, not number of writes") {
      arr = MArrayI64.new(8, 0 :: i64)
      _ = MArrayI64.set(arr, 0, 99 :: i64)
      assert(MArrayI64.length(arr) == 8)
    }
  }

  describe("MArrayF64") {
    test("new fills every slot with the init value") {
      arr = MArrayF64.new(3, 1.5 :: f64)
      assert(MArrayF64.length(arr) == 3)
      assert(MArrayF64.get(arr, 0) == 1.5)
      assert(MArrayF64.get(arr, 1) == 1.5)
      assert(MArrayF64.get(arr, 2) == 1.5)
    }

    test("set returns the written value and persists it") {
      arr = MArrayF64.new(4, 0.0 :: f64)
      written = MArrayF64.set(arr, 2, 3.25 :: f64)
      assert(written == 3.25)
      assert(MArrayF64.get(arr, 2) == 3.25)
    }

    test("sum across set values matches the expected total") {
      arr = MArrayF64.new(3, 0.0 :: f64)
      _ = MArrayF64.set(arr, 0, 1.5 :: f64)
      _ = MArrayF64.set(arr, 1, 2.5 :: f64)
      _ = MArrayF64.set(arr, 2, 3.0 :: f64)
      total = MArrayF64.get(arr, 0) + MArrayF64.get(arr, 1) + MArrayF64.get(arr, 2)
      assert(total == 7.0)
    }

    test("length reflects allocated size, not number of writes") {
      arr = MArrayF64.new(6, 0.0 :: f64)
      _ = MArrayF64.set(arr, 0, 99.0 :: f64)
      assert(MArrayF64.length(arr) == 6)
    }
  }
}
