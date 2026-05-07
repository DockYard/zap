pub struct VectorTest {
  use Zest.Case

  describe("VectorI64") {
    test("new_filled fills every slot with the init value") {
      v = VectorI64.new_filled(4, 7 :: i64)
      assert(VectorI64.length(v) == 4)
      assert(VectorI64.get(v, 0) == 7)
      assert(VectorI64.get(v, 1) == 7)
      assert(VectorI64.get(v, 2) == 7)
      assert(VectorI64.get(v, 3) == 7)
    }

    test("new_empty allocates with reserved capacity") {
      v = VectorI64.new_empty(8)
      assert(VectorI64.length(v) == 0)
      assert(VectorI64.capacity(v) >= 8)
    }

    test("set persists the written value (rc==1 in-place)") {
      v = VectorI64.new_filled(3, 0 :: i64)
      v = VectorI64.set(v, 1, 42 :: i64)
      assert(VectorI64.get(v, 1) == 42)
    }

    test("chained sets accumulate via get-sum") {
      v = VectorI64.new_filled(5, 0 :: i64)
      v = VectorI64.set(v, 0, 10 :: i64)
      v = VectorI64.set(v, 1, 20 :: i64)
      v = VectorI64.set(v, 2, 30 :: i64)
      total = VectorI64.get(v, 0) + VectorI64.get(v, 1) + VectorI64.get(v, 2)
      assert(total == 60)
    }

    test("push grows length and persists value") {
      v = VectorI64.new_empty(4)
      v = VectorI64.push(v, 1 :: i64)
      v = VectorI64.push(v, 2 :: i64)
      v = VectorI64.push(v, 3 :: i64)
      assert(VectorI64.length(v) == 3)
      assert(VectorI64.get(v, 0) == 1)
      assert(VectorI64.get(v, 1) == 2)
      assert(VectorI64.get(v, 2) == 3)
    }

    test("pop decrements length") {
      v = VectorI64.new_filled(3, 7 :: i64)
      v = VectorI64.pop(v)
      assert(VectorI64.length(v) == 2)
    }

    test("append concatenates two vectors in correct order") {
      a = VectorI64.new_empty(0)
      a = VectorI64.push(a, 1 :: i64)
      a = VectorI64.push(a, 2 :: i64)
      b = VectorI64.new_empty(0)
      b = VectorI64.push(b, 3 :: i64)
      b = VectorI64.push(b, 4 :: i64)
      result = VectorI64.append(a, b)
      assert(VectorI64.length(result) == 4)
      assert(VectorI64.get(result, 0) == 1)
      assert(VectorI64.get(result, 1) == 2)
      assert(VectorI64.get(result, 2) == 3)
      assert(VectorI64.get(result, 3) == 4)
    }
  }

  describe("VectorF64") {
    test("new_filled fills every slot with the init value") {
      v = VectorF64.new_filled(3, 1.5 :: f64)
      assert(VectorF64.length(v) == 3)
      assert(VectorF64.get(v, 0) == 1.5)
      assert(VectorF64.get(v, 1) == 1.5)
      assert(VectorF64.get(v, 2) == 1.5)
    }

    test("set persists the written value") {
      v = VectorF64.new_filled(4, 0.0 :: f64)
      v = VectorF64.set(v, 2, 3.25 :: f64)
      assert(VectorF64.get(v, 2) == 3.25)
    }

    test("sum across set values matches expected total") {
      v = VectorF64.new_filled(3, 0.0 :: f64)
      v = VectorF64.set(v, 0, 1.5 :: f64)
      v = VectorF64.set(v, 1, 2.5 :: f64)
      v = VectorF64.set(v, 2, 3.0 :: f64)
      total = VectorF64.get(v, 0) + VectorF64.get(v, 1) + VectorF64.get(v, 2)
      assert(total == 7.0)
    }

    test("push and pop round-trip the length") {
      v = VectorF64.new_empty(2)
      v = VectorF64.push(v, 1.5 :: f64)
      v = VectorF64.push(v, 2.5 :: f64)
      assert(VectorF64.length(v) == 2)
      v = VectorF64.pop(v)
      assert(VectorF64.length(v) == 1)
    }
  }
}
