pub module Test.ZestFeaturesTest {
  use Zest.Case

  describe("setup with context") {
    ctx = setup() {
      42
    }

    test("test uses setup return value") {
      assert(ctx == 42)
    }

    test("test without context still works") {
      assert(true)
    }
  }

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

  describe("setup and teardown") {
    setup() {
      _ready = true
    }

    test("setup runs before test") {
      assert(true)
    }

    teardown() {
      _cleaned = true
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
    test("can call module functions") {
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
