pub struct GenericListTest {
  use Zest.Case

  describe("List(i64)") {
    test("new_filled fills every slot with the init value") {
      values = List.new_filled(4, 7 :: i64)
      assert(List.length(values) == 4)
      assert(List.get(values, 0) == 7)
      assert(List.get(values, 1) == 7)
      assert(List.get(values, 2) == 7)
      assert(List.get(values, 3) == 7)
    }

    test("new_empty allocates with reserved capacity") {
      values = List.new_empty(8) :: List(i64)
      assert(List.length(values) == 0)
      assert(List.capacity(values) >= 8)
    }

    test("set persists the written value") {
      values = List.new_filled(3, 0 :: i64)
      values = List.set(values, 1, 42 :: i64)
      assert(List.get(values, 1) == 42)
    }

    test("chained sets accumulate via get-sum") {
      values = List.new_filled(5, 0 :: i64)
      values = List.set(values, 0, 10 :: i64)
      values = List.set(values, 1, 20 :: i64)
      values = List.set(values, 2, 30 :: i64)
      total = List.get(values, 0) + List.get(values, 1) + List.get(values, 2)
      assert(total == 60)
    }

    test("push grows length and persists value") {
      values = List.new_empty(4) :: List(i64)
      values = List.push(values, 1 :: i64)
      values = List.push(values, 2 :: i64)
      values = List.push(values, 3 :: i64)
      assert(List.length(values) == 3)
      assert(List.get(values, 0) == 1)
      assert(List.get(values, 1) == 2)
      assert(List.get(values, 2) == 3)
    }

    test("pop returns the shortened list and removed value") {
      values = List.new_filled(3, 7 :: i64)
      popped = List.pop(values)
      shortened = popped.0
      removed = popped.1
      assert(List.length(shortened) == 2)
      assert(removed == 7)
    }

    test("append concatenates two lists in correct order") {
      left = List.new_empty(0) :: List(i64)
      left = List.push(left, 1 :: i64)
      left = List.push(left, 2 :: i64)
      right = List.new_empty(0) :: List(i64)
      right = List.push(right, 3 :: i64)
      right = List.push(right, 4 :: i64)
      result = List.append(left, right)
      assert(List.length(result) == 4)
      assert(List.get(result, 0) == 1)
      assert(List.get(result, 1) == 2)
      assert(List.get(result, 2) == 3)
      assert(List.get(result, 3) == 4)
    }

    test("map filter and reduce operate on generic lists") {
      values = List.new_empty(0) :: List(i64)
      values = List.push(values, 1 :: i64)
      values = List.push(values, 2 :: i64)
      values = List.push(values, 3 :: i64)

      doubled = List.map(values, fn(value :: i64) -> i64 { value * 2 })
      assert(List.get(doubled, 2) == 6)

      filtered = List.filter(doubled, fn(value :: i64) -> Bool { value > 2 })
      assert(List.length(filtered) == 2)
      assert(List.get(filtered, 0) == 4)

      total = List.reduce(filtered, 0 :: i64, fn(accumulator :: i64, value :: i64) -> i64 { accumulator + value })
      assert(total == 10)
    }

    test("dynamic-index get keeps i64 type through locals and overloads") {
      values = List.new_empty(0) :: List(i64)
      values = List.push(values, 11 :: i64)
      values = List.push(values, 22 :: i64)
      values = List.push(values, 33 :: i64)

      value = GenericListTest.read_dynamic_i64(values, 1)
      assert(value == 22)
      assert(Integer.to_string(value) == "22")
      assert(GenericListTest.max_dynamic_i64(values, 0, 30 :: i64) == 30)

      rewritten = GenericListTest.round_trip_dynamic_i64(values, 2)
      assert(List.get(rewritten, 2) == 33)
    }

    test("set value argument can read the same receiver before owned consume") {
      values = List.new_empty(0) :: List(i64)
      values = List.push(values, 0 :: i64)
      values = List.push(values, 1 :: i64)
      values = List.push(values, 2 :: i64)
      values = List.push(values, 3 :: i64)

      shifted = GenericListTest.shift_left(values, 0, 2)
      assert(List.length(shifted) == 4)
      assert(List.get(shifted, 0) == 1)
      assert(List.get(shifted, 1) == 2)
      assert(List.get(shifted, 2) == 3)
      assert(List.get(shifted, 3) == 3)
    }
  }

  describe("List(String)") {
    test("new_empty push get and head preserve string elements") {
      values = List.new_empty(3) :: List(String)
      values = List.push(values, "alpha")
      values = List.push(values, "beta")
      values = List.push(values, "gamma")
      assert(List.length(values) == 3)
      assert(List.capacity(values) >= 3)
      assert(List.get(values, 0) == "alpha")
      assert(List.head(values) == "alpha")
      assert(List.get(values, 1) == "beta")
      assert(List.get(values, 2) == "gamma")
    }

    test("set replaces one string element without disturbing neighbors") {
      values = List.new_empty(2) :: List(String)
      values = List.push(values, "old")
      values = List.push(values, "keep")
      values = List.set(values, 0, "new")
      assert(List.length(values) == 2)
      assert(List.get(values, 0) == "new")
      assert(List.get(values, 1) == "keep")
    }

    test("append concatenates string lists in correct order") {
      left = List.new_empty(0) :: List(String)
      left = List.push(left, "red")
      left = List.push(left, "green")
      right = List.new_empty(0) :: List(String)
      right = List.push(right, "blue")
      right = List.push(right, "gold")
      result = List.append(left, right)
      assert(List.length(result) == 4)
      assert(List.get(result, 0) == "red")
      assert(List.get(result, 1) == "green")
      assert(List.get(result, 2) == "blue")
      assert(List.get(result, 3) == "gold")
    }

    test("tail and pop preserve string elements") {
      values = List.new_empty(3) :: List(String)
      values = List.push(values, "first")
      values = List.push(values, "second")
      values = List.push(values, "third")
      tail = List.tail(values)
      assert(List.length(tail) == 2)
      assert(List.head(tail) == "second")
      assert(List.get(tail, 1) == "third")
      popped = List.pop(tail)
      shortened = popped.0
      removed = popped.1
      assert(List.length(shortened) == 1)
      assert(List.head(shortened) == "second")
      assert(removed == "third")
    }

    test("copy-on-write preserves aliased original string list") {
      values = List.new_empty(2) :: List(String)
      values = List.push(values, "original")
      values = List.push(values, "stable")
      original_alias = values
      values = List.set(values, 1, "changed")
      values = List.push(values, "fresh")
      assert(List.length(original_alias) == 2)
      assert(List.get(original_alias, 0) == "original")
      assert(List.get(original_alias, 1) == "stable")
      assert(List.length(values) == 3)
      assert(List.get(values, 0) == "original")
      assert(List.get(values, 1) == "changed")
      assert(List.get(values, 2) == "fresh")
    }
  }

  describe("List(f64)") {
    test("new_filled fills every slot with the init value") {
      values = List.new_filled(3, 1.5 :: f64)
      assert(List.length(values) == 3)
      assert(List.get(values, 0) == 1.5)
      assert(List.get(values, 1) == 1.5)
      assert(List.get(values, 2) == 1.5)
    }

    test("set persists the written value") {
      values = List.new_filled(4, 0.0 :: f64)
      values = List.set(values, 2, 3.25 :: f64)
      assert(List.get(values, 2) == 3.25)
    }

    test("push and pop round-trip the length") {
      values = List.new_empty(2) :: List(f64)
      values = List.push(values, 1.5 :: f64)
      values = List.push(values, 2.5 :: f64)
      assert(List.length(values) == 2)
      popped = List.pop(values)
      assert(List.length(popped.0) == 1)
      assert(popped.1 == 2.5)
    }

    test("dynamic-index get keeps f64 type through arithmetic") {
      values = List.new_filled(3, 0.0 :: f64)
      values = List.set(values, 0, 1.25 :: f64)
      values = List.set(values, 1, 2.5 :: f64)
      values = List.set(values, 2, 4.0 :: f64)

      total = GenericListTest.sum_dynamic_f64(values, 0, 1)
      assert(total == 3.75 :: f64)

      rewritten = GenericListTest.round_trip_dynamic_f64(values, 2)
      assert(List.get(rewritten, 2) == 4.0 :: f64)
    }

    test("literal-index get keeps f64 type through arithmetic") {
      values = List.new_filled(3, 0.0 :: f64)
      values = List.set(values, 0 :: i64, 1.25 :: f64)
      values = List.set(values, 1 :: i64, 2.5 :: f64)

      total = GenericListTest.sum_literal_f64(values)
      assert(total == 3.75 :: f64)
    }

    test("list-backed f64 accumulator keeps type through multiply-add") {
      lhs = List.new_filled(2, 1.0 :: f64)
      rhs = List.new_filled(2, 2.0 :: f64)
      totals = List.new_filled(2, 0.0 :: f64)

      updated = GenericListTest.accumulate_pair_f64(lhs, rhs, totals)

      assert(List.get(updated, 0 :: i64) == 2.0 :: f64)
      assert(List.get(updated, 1 :: i64) == 4.0 :: f64)
    }
  }

  fn read_dynamic_i64(values :: List(i64), index :: i64) -> i64 {
    value = List.get(values, index)
    value
  }

  fn max_dynamic_i64(values :: List(i64), index :: i64, fallback :: i64) -> i64 {
    value = List.get(values, index)
    Integer.max(value, fallback)
  }

  fn round_trip_dynamic_i64(values :: List(i64), index :: i64) -> List(i64) {
    value = List.get(values, index)
    List.set(values, index, value)
  }

  fn sum_dynamic_f64(values :: List(f64), left_index :: i64, right_index :: i64) -> f64 {
    left = List.get(values, left_index)
    right = List.get(values, right_index)
    left + right
  }

  fn round_trip_dynamic_f64(values :: List(f64), index :: i64) -> List(f64) {
    value = List.get(values, index)
    List.set(values, index, value)
  }

  fn sum_literal_f64(values :: List(f64)) -> f64 {
    left = List.get(values, 0 :: i64)
    right = List.get(values, 1 :: i64)
    left + right
  }

  fn accumulate_pair_f64(lhs :: List(f64), rhs :: List(f64), totals :: List(f64)) -> List(f64) {
    old0 = List.get(totals, 0 :: i64)
    old1 = List.get(totals, 1 :: i64)
    lhs_value = List.get(lhs, 0 :: i64)
    rhs_value = List.get(rhs, 0 :: i64)
    new0 = old0 + lhs_value * rhs_value
    new1 = old1 + rhs_value * rhs_value
    totals = List.set(totals, 0 :: i64, new0)
    List.set(totals, 1 :: i64, new1)
  }

  fn shift_left(values :: List(i64), index :: i64, upto :: i64) -> List(i64) {
    if index > upto {
      values
    } else {
      next_index = index + (1 :: i64)
      shifted = List.set(values, index, List.get(values, next_index))
      GenericListTest.shift_left(shifted, next_index, upto)
    }
  }
}
