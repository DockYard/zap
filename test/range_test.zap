pub struct Test.RangeTest {
  use Zest.Case

  describe("Range creation") {
    test("basic range via function") {
      r = make_range_syntax()
      assert(r.start == 1)
      assert(r.end == 10)
      assert(r.step == 1)
    }

    test("range with step") {
      r = make_range_step()
      assert(r.start == 1)
      assert(r.end == 10)
      assert(r.step == 3)
    }

    test("negative start") {
      r = make_neg_range()
      assert(r.start == -100)
      assert(r.end == 100)
    }

    test("reverse range") {
      r = make_reverse()
      assert(r.start == 100)
      assert(r.end == 1)
    }

    test("inline range in test body") {
      r = 1..10
      assert(r.start == 1)
      assert(r.end == 10)
      assert(r.step == 1)
    }

    test("inline range with step in test body") {
      r = 1..10:3
      assert(r.step == 3)
    }
  }

  fn make_range_syntax() -> Range {
    1..10
  }

  fn make_range_step() -> Range {
    1..10:3
  }

  fn make_neg_range() -> Range {
    -100..100
  }

  fn make_reverse() -> Range {
    100..1
  }

  describe("in operator with ranges") {
    test("value in basic range") {
      assert(check_in_range(5))
    }

    test("value at range start") {
      assert(check_in_range(1))
    }

    test("value at range end") {
      assert(check_in_range(10))
    }

    test("value outside range") {
      assert(not check_in_range(11))
    }

    test("value below range") {
      assert(not check_in_range(0))
    }

    test("step-aware membership hit") {
      assert(check_in_step(1))
      assert(check_in_step(4))
      assert(check_in_step(7))
      assert(check_in_step(10))
    }

    test("step-aware membership miss") {
      assert(not check_in_step(2))
      assert(not check_in_step(5))
    }

    test("large step") {
      assert(check_large_step(1))
      assert(check_large_step(11))
      assert(not check_large_step(3))
    }

    test("negative range membership") {
      assert(check_neg_range(0))
      assert(check_neg_range(-10))
      assert(check_neg_range(10))
      assert(not check_neg_range(-11))
    }
  }

  fn check_in_range(n :: i64) -> Bool {
    n in 1..10
  }

  fn check_in_step(n :: i64) -> Bool {
    n in 1..10:3
  }

  fn check_large_step(n :: i64) -> Bool {
    n in 1..100:10
  }

  fn check_neg_range(n :: i64) -> Bool {
    n in -10..10
  }

  describe("range in guard") {
    test("range guard matches") {
      assert(classify_score(85) == "good")
    }

    test("range guard fallthrough") {
      assert(classify_score(200) == "unknown")
    }
  }

  fn classify_score(n :: i64) -> String if n in 1..100 {
    "good"
  }

  fn classify_score(_ :: i64) -> String {
    "unknown"
  }

  describe("for comprehension with range") {
    test("for over basic range") {
      result = for_range_basic()
      assert(List.length(result) == 5)
      assert(List.head(result) == 2)
    }

    test("for over range with step") {
      result = for_range_step()
      assert(List.length(result) == 4)
    }

    test("for over reverse range") {
      result = for_range_reverse()
      assert(List.length(result) == 3)
      assert(List.head(result) == 30)
    }

    test("for over range with filter") {
      result = for_range_filter()
      assert(List.length(result) == 5)
    }
  }

  fn for_range_basic() -> [i64] {
    for x <- 1..5 { x * 2 }
  }

  fn for_range_step() -> [i64] {
    for x <- 1..10:3 { x }
  }

  fn for_range_reverse() -> [i64] {
    for x <- 3..1 { x * 10 }
  }

  fn for_range_filter() -> [i64] {
    for x <- 1..10, x > 5 { x }
  }
}
