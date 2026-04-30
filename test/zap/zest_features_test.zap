pub struct Zap.ZestFeaturesTest {
  use Zest.Case

  describe("multiple assertions per test") {
    test("all passing assertions run") {
      assert(1 + 1 == 2)
      assert(2 + 2 == 4)
      assert(3 + 3 == 6)
    }

    test("mixed assert and reject") {
      assert(true)
      reject(false)
      assert(1 + 1 == 2)
      reject(1 + 1 == 3)
    }
  }

  describe("setup runs fresh per test") {
    setup() {
      42
    }

    test("first test gets fresh context", ctx) {
      assert(ctx == 42)
    }

    test("second test gets fresh context", ctx) {
      assert(ctx == 42)
    }

    test("test without context works") {
      assert(true)
    }
  }

  describe("setup with string context") {
    setup() {
      "ready"
    }

    test("receives string", ctx) {
      assert(ctx == "ready")
    }
  }

  describe("setup and teardown") {
    setup() {
      42
    }

    test("setup and teardown both run", ctx) {
      assert(ctx == 42)
    }

    teardown() {
      _cleaned = true
    }
  }

  describe("describe without setup") {
    test("plain test works") {
      assert(true)
    }

    test("another plain test") {
      reject(false)
    }
  }

  describe("nested describe blocks") {
    describe("inner group A") {
      test("inner test A1") {
        assert(10 > 5)
      }

      test("inner test A2") {
        assert(10 < 20)
      }
    }

    describe("inner group B") {
      test("inner test B1") {
        reject(5 > 10)
      }
    }
  }

  describe("test with helper functions") {
    test("can call struct functions") {
      assert(double(21) == 42)
    }

    test("can use multiple helpers") {
      assert(add(20, 22) == 42)
      assert(double(21) == 42)
    }
  }

  fn double(x :: i64) -> i64 {
    x * 2
  }

  fn add(a :: i64, b :: i64) -> i64 {
    a + b
  }
}
