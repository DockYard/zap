pub struct Test.RangeTest {
  use Zest.Case

  describe("Range creation") {
    test("explicit struct") {
      r = make_range()
      assert(r.start == 1)
      assert(r.end == 10)
      assert(r.step == 1)
    }

    test("range syntax in function") {
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
  }

  fn make_range() -> Range {
    %Range{start: 1, end: 10, step: 1}
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

    test("value outside range") {
      assert(not check_in_range(11))
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

    test("range in guard") {
      assert(classify_score(85) == "good")
    }

    test("range guard fallthrough") {
      assert(classify_score(200) == "unknown")
    }
  }

  fn check_in_range(n :: i64) -> Bool {
    n in 1..10
  }

  fn check_in_step(n :: i64) -> Bool {
    n in 1..10:3
  }

  fn classify_score(n :: i64) -> String if n in 1..100 {
    "good"
  }

  fn classify_score(_ :: i64) -> String {
    "unknown"
  }
}
